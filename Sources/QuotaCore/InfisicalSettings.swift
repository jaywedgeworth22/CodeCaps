import Foundation

/// Infisical as the sole source of truth for CodeCaps' app-level settings.
///
/// The fleet-wide contract (see INFISICAL.md at the repo root):
/// 1. **Load at startup** into an in-memory cache.  A load failure never
///    blocks launch — the app keeps its local values until the next refresh.
/// 2. **Never fetch per-request.**  `value(for:)` is a synchronous,
///    memory-only read; no network call leaves this type except from
///    `load()`, `refresh()` and `set(_:for:)` (the last two only from the
///    background refresh timer, `applicationDidBecomeActive`, and the
///    owner's explicit Save actions).
/// 3. **Background refresh** keeps serving the last-known-good cache when a
///    refresh fails; the failure is recorded on `lastError`, never thrown.
/// 4. **Write-through on admin save.**  `set(_:for:)` writes to Infisical
///    FIRST and only updates the cache after the write succeeds.  A failed
///    write throws and leaves the cache untouched — the cache and Infisical
///    never diverge silently.
///
/// The universal-auth client secret is provisioned by the owner into his own
/// Keychain (Settings → Infisical Sync) and held here only in memory.  It is
/// never logged, never persisted by this type, and never leaves an error
/// message.  The iOS companion never holds it at all — the Mac app owns the
/// Infisical read and the companion keeps reading through its existing API.
///
/// The class is `@unchecked Sendable`: every stored property is either a
/// value type or guarded by `lock`, so synchronous memory-only reads are safe
/// from any thread and the network calls stay in `async` functions.
public final class InfisicalSettings: @unchecked Sendable {

    // MARK: - Inventory

    /// The Infisical project that owns CodeCaps' app-level settings.
    public static let codeCapsProjectId = "cd278860-c3bc-466f-9256-22385e64551b"

    /// Keys this app manages in Infisical.  The full inventory, sensitivity,
    /// and defaults live in INFISICAL.md.
    public enum Keys {
        /// Service URL the Mac app pulls other machines' quota windows from.
        public static let pullEndpoint = "PULL_ENDPOINT"
        /// Service URL the Mac app pushes this Mac's quota windows to.
        public static let pushEndpoint = "PUSH_ENDPOINT"
        /// Seconds between background refreshes of this cache.  Tunable via
        /// Infisical itself, per the fleet-wide pattern.
        public static let refreshSeconds = "SETTINGS_REFRESH_SECONDS"
    }

    /// Fallback refresh cadence when the key is absent or unparseable.
    public static let defaultRefreshInterval: TimeInterval = 300
    /// Floor for an admin-set cadence, so a typo cannot turn the refresh
    /// timer into a hot loop.
    public static let minimumRefreshInterval: TimeInterval = 60

    /// Release builds read the `prod` environment; `.dev` builds read `dev`,
    /// mirroring how `TokenStore` scopes Keychain items per build.
    public static func defaultEnvironment(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        (bundleIdentifier ?? "").hasSuffix(".dev") ? "dev" : "prod"
    }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var siteURL: URL
        public var projectId: String
        public var environment: String
        public var clientId: String
        public var clientSecret: String

        public init(
            siteURL: URL = URL(string: "https://app.infisical.com")!,
            projectId: String = InfisicalSettings.codeCapsProjectId,
            environment: String,
            clientId: String,
            clientSecret: String
        ) {
            self.siteURL = siteURL
            self.projectId = projectId
            self.environment = environment
            self.clientId = clientId
            self.clientSecret = clientSecret
        }
    }

    // MARK: - Errors

    public enum SettingsError: Error, LocalizedError {
        case notConfigured
        case loginFailed(status: Int)
        case fetchFailed(status: Int)
        case writeFailed(status: Int)
        case decoding(String)
        case transport(Error)

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Infisical sync is not set up.  Add your client identity under Settings → Infisical Sync (see INFISICAL.md)."
            case .loginFailed(let status):
                return "Infisical login failed (HTTP \(status)).  Check the client identity under Settings → Infisical Sync."
            case .fetchFailed(let status):
                return "Infisical settings fetch failed (HTTP \(status)).  The last-known-good values are still in effect."
            case .writeFailed(let status):
                return "Infisical write failed (HTTP \(status)) — the setting was NOT saved, so the cache and Infisical cannot diverge."
            case .decoding(let what):
                return "Infisical returned an unexpected response (\(what))."
            case .transport(let error):
                return "Infisical request failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transport seam

    /// One HTTP round trip.  `URLSessionTransport` is the live implementation;
    /// tests inject a mock.  Bodies and headers here are request plumbing —
    /// secret *values* are never logged by this type.
    public protocol Transport: Sendable {
        func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: Data?
        ) async throws -> (data: Data, statusCode: Int)
    }

    public struct URLSessionTransport: Transport {
        private let timeout: TimeInterval

        public init(timeout: TimeInterval = 30) {
            self.timeout = timeout
        }

        public func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: Data?
        ) async throws -> (data: Data, statusCode: Int) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.httpBody = body
            // Ephemeral: nothing about these requests is cached, cookied, or
            // written to disk — same posture as the quota fetchers.
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - State

    /// The app's one settings store.  Tests build their own instances with a
    /// mock transport and never touch this one, so no test hits the network.
    public static let shared = InfisicalSettings()

    private let transport: Transport
    private let lock = NSLock()
    private var _configuration: Configuration?
    private var _cache: [String: String] = [:]
    private var _loadedAt: Date?
    private var _lastError: String?

    public init(transport: Transport = URLSessionTransport()) {
        self.transport = transport
    }

    // MARK: - Configuration

    public func configure(_ configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        _configuration = configuration
    }

    public func clearConfiguration() {
        lock.lock()
        defer { lock.unlock() }
        _configuration = nil
        _cache = [:]
        _loadedAt = nil
        _lastError = nil
    }

    /// Whether the owner has provisioned an Infisical identity.  With no
    /// identity every read falls back to local values and every save stays
    /// local — today's behaviour, unchanged.
    public var isProvisioned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _configuration != nil
    }

    private func configurationOrThrow() throws -> Configuration {
        lock.lock()
        defer { lock.unlock() }
        guard let configuration = _configuration else {
            throw SettingsError.notConfigured
        }
        return configuration
    }

    // MARK: - Memory-only reads

    /// Synchronous, memory-only read.  This is the only read path the refresh
    /// loop, the quota fetchers, and the UI may use — it never touches the
    /// network.  Returns nil for missing keys and for empty values (an empty
    /// value in Infisical means "not configured").
    public func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = _cache[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    public func allValues() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return _cache
    }

    public var lastLoadedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _loadedAt
    }

    /// The most recent refresh failure, if any.  Loud but non-fatal: the
    /// cache keeps serving last-known-good underneath it.
    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    /// The background refresh cadence, tunable via Infisical itself.
    public var refreshInterval: TimeInterval {
        guard let raw = value(for: Keys.refreshSeconds),
              let seconds = TimeInterval(raw) else {
            return Self.defaultRefreshInterval
        }
        return max(seconds, Self.minimumRefreshInterval)
    }

    // MARK: - Load / refresh

    /// Full fetch from Infisical, replacing the cache.  Throws on any failure
    /// and leaves the previous cache untouched.  Off the main thread by
    /// construction — every caller awaits it from a background task.
    public func load() async throws {
        let configuration = try configurationOrThrow()
        let values = try await fetchAll(configuration: configuration)
        lock.lock()
        defer { lock.unlock() }
        _cache = values
        _loadedAt = Date()
        _lastError = nil
    }

    /// Best-effort refresh for the timer and `applicationDidBecomeActive`.
    /// Never throws: a failure is recorded on `lastError` and the
    /// last-known-good cache keeps serving.  A no-op until provisioned.
    public func refresh() async {
        guard isProvisioned else { return }
        do {
            try await load()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lock.lock()
            defer { lock.unlock() }
            _lastError = message
        }
    }

    // MARK: - Write-through

    /// Writes `value` to Infisical FIRST, then updates the cache.  A failed
    /// Infisical write throws and the cache is left exactly as it was.
    public func set(_ value: String, for key: String) async throws {
        let configuration = try configurationOrThrow()
        try await writeSecret(configuration: configuration, key: key, value: value)
        lock.lock()
        defer { lock.unlock() }
        _cache[key] = value
        _loadedAt = Date()
        _lastError = nil
    }

    /// Write-through that is a no-op until the owner provisions an identity,
    /// so settings call sites stay one line and unprovisioned behaviour is
    /// byte-for-byte today's.
    public func writeThrough(_ value: String, for key: String) async throws {
        guard isProvisioned else { return }
        try await set(value, for: key)
    }

    // MARK: - Infisical REST

    private func accessToken(for configuration: Configuration) async throws -> String {
        let url = configuration.siteURL.appendingPathComponent("api/v1/auth/universal-auth/login")
        let body = try JSONSerialization.data(withJSONObject: [
            "clientId": configuration.clientId,
            "clientSecret": configuration.clientSecret,
        ])
        let (data, status) = try await sending {
            try await self.transport.send(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        }
        guard status == 200 else { throw SettingsError.loginFailed(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty else {
            throw SettingsError.decoding("login response carried no accessToken")
        }
        return token
    }

    private func fetchAll(configuration: Configuration) async throws -> [String: String] {
        let token = try await accessToken(for: configuration)
        guard var components = URLComponents(
            url: configuration.siteURL.appendingPathComponent("api/v3/secrets/raw"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SettingsError.decoding("could not build the secrets list URL")
        }
        components.queryItems = [
            URLQueryItem(name: "workspaceId", value: configuration.projectId),
            URLQueryItem(name: "environment", value: configuration.environment),
            URLQueryItem(name: "secretPath", value: "/"),
            URLQueryItem(name: "viewSecretValue", value: "true"),
            URLQueryItem(name: "expandSecretReferences", value: "false"),
            URLQueryItem(name: "include_imports", value: "false"),
        ]
        guard let url = components.url else {
            throw SettingsError.decoding("could not build the secrets list URL")
        }
        let (data, status) = try await sending {
            try await self.transport.send(
                method: "GET",
                url: url,
                headers: ["Authorization": "Bearer \(token)"],
                body: nil
            )
        }
        guard status == 200 else { throw SettingsError.fetchFailed(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let secrets = json["secrets"] as? [[String: Any]] else {
            throw SettingsError.decoding("secrets list had no secrets array")
        }
        var values: [String: String] = [:]
        for secret in secrets {
            guard let key = secret["secretKey"] as? String, !key.isEmpty,
                  let value = secret["secretValue"] as? String, !value.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    private func writeSecret(configuration: Configuration, key: String, value: String) async throws {
        let token = try await accessToken(for: configuration)
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        // The /raw/ write path accepts a plaintext secretValue (the pilot
        // validated this: the non-raw path demands client-side E2EE fields).
        let url = configuration.siteURL.appendingPathComponent("api/v3/secrets/raw/\(encoded)")
        let body = try JSONSerialization.data(withJSONObject: [
            "workspaceId": configuration.projectId,
            "environment": configuration.environment,
            "secretPath": "/",
            "secretValue": value,
            "type": "shared",
        ])
        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
        let (_, patchStatus) = try await sending {
            try await self.transport.send(method: "PATCH", url: url, headers: headers, body: body)
        }
        if patchStatus == 404 {
            // Secret does not exist yet — create it.
            let (_, postStatus) = try await sending {
                try await self.transport.send(method: "POST", url: url, headers: headers, body: body)
            }
            guard (200...299).contains(postStatus) else {
                throw SettingsError.writeFailed(status: postStatus)
            }
            return
        }
        guard (200...299).contains(patchStatus) else {
            throw SettingsError.writeFailed(status: patchStatus)
        }
    }

    /// Maps transport-level failures into `SettingsError.transport` while
    /// letting `SettingsError` pass through untouched.
    private func sending(
        _ work: () async throws -> (data: Data, statusCode: Int)
    ) async throws -> (data: Data, statusCode: Int) {
        do {
            return try await work()
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.transport(error)
        }
    }
}
