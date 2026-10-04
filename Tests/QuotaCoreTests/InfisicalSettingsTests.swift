import XCTest
@testable import QuotaCore

/// A transport double that records every request and answers from a handler
/// the test controls.  Nothing here reaches the network.
final class MockInfisicalTransport: InfisicalSettings.Transport, @unchecked Sendable {
    struct Call {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data?
    }

    var calls: [Call] = []
    var handler: (String, URL, [String: String], Data?) throws -> (Data, Int) =
        { _, _, _, _ in throw MockError.unexpected }

    enum MockError: Error {
        case unexpected
        case boom
    }

    func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: Data?
    ) async throws -> (data: Data, statusCode: Int) {
        calls.append(Call(method: method, url: url, headers: headers, body: body))
        return try handler(method, url, headers, body)
    }

    var requestCount: Int { calls.count }
    var methods: [String] { calls.map(\.method) }
}

private func loginPayload(token: String = "tok-123") -> Data {
    try! JSONSerialization.data(withJSONObject: ["accessToken": token])
}

private func secretsPayload(_ values: [String: String]) -> Data {
    let secrets = values.map { ["secretKey": $0.key, "secretValue": $0.value] }
    return try! JSONSerialization.data(withJSONObject: ["secrets": secrets])
}

private func configuredSettings(
    transport: MockInfisicalTransport,
    values: [String: String] = [:]
) -> InfisicalSettings {
    let settings = InfisicalSettings(transport: transport)
    settings.configure(InfisicalSettings.Configuration(
        environment: "dev",
        clientId: "test-client",
        clientSecret: "test-secret"
    ))
    transport.handler = { method, url, _, _ in
        if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
            return (loginPayload(), 200)
        }
        if url.path.hasSuffix("/api/v3/secrets/raw"), method == "GET" {
            return (secretsPayload(values), 200)
        }
        throw MockInfisicalTransport.MockError.unexpected
    }
    return settings
}

/// The fleet-wide Infisical SOT contract, proved against a mock transport:
/// startup load populates the cache, runtime reads never touch the network,
/// admin writes land in Infisical before the cache, and failures keep
/// last-known-good.
final class InfisicalSettingsTests: XCTestCase {

    func testLoadPopulatesCacheFromInfisical() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
            InfisicalSettings.Keys.refreshSeconds: "120",
        ])

        try await settings.load()

        XCTAssertEqual(
            settings.value(for: InfisicalSettings.Keys.pullEndpoint),
            "https://quota.example.com/api/quota-windows"
        )
        XCTAssertEqual(settings.refreshInterval, 120)
        XCTAssertNotNil(settings.lastLoadedAt)
        XCTAssertNil(settings.lastError)
        // One login plus one bulk list — and nothing else.
        XCTAssertEqual(transport.methods, ["POST", "GET"])
    }

    func testRuntimeReadsMakeZeroNetworkCallsAfterInit() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()
        let callsAfterLoad = transport.requestCount

        for _ in 0..<25 {
            _ = settings.value(for: InfisicalSettings.Keys.pullEndpoint)
            _ = settings.value(for: "SOME_OTHER_KEY")
            _ = settings.allValues()
            _ = settings.refreshInterval
        }

        XCTAssertEqual(transport.requestCount, callsAfterLoad,
                       "memory-only reads must not hit the network")
    }

    func testWriteThroughPatchesInfisicalBeforeUpdatingCache() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://old.example.com/api/quota-windows",
        ])
        try await settings.load()

        // Capture what the cache holds at the exact moment the PATCH leaves:
        // it must still be the OLD value, proving Infisical is written first.
        var patchSeen = false
        var cacheValueAtPatchTime: String?
        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" {
                patchSeen = true
                cacheValueAtPatchTime = settings.value(for: InfisicalSettings.Keys.pullEndpoint)
                return (Data(), 200)
            }
            throw MockInfisicalTransport.MockError.unexpected
        }

        try await settings.set("https://new.example.com/api/quota-windows",
                               for: InfisicalSettings.Keys.pullEndpoint)

        XCTAssertTrue(patchSeen)
        XCTAssertEqual(cacheValueAtPatchTime, "https://old.example.com/api/quota-windows",
                       "the cache must not move before the Infisical write succeeds")
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://new.example.com/api/quota-windows")
    }

    func testWriteThroughCreatesMissingSecretWithPost() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport)
        try await settings.load()

        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" { return (Data(), 404) }
            if method == "POST", url.path.contains("/api/v3/secrets/") { return (Data(), 201) }
            throw MockInfisicalTransport.MockError.unexpected
        }

        try await settings.set("300", for: InfisicalSettings.Keys.refreshSeconds)

        XCTAssertEqual(transport.methods.filter { $0 == "PATCH" }.count, 1)
        // login (load) + login (set) + create = 3 POSTs.
        XCTAssertEqual(transport.methods.filter { $0 == "POST" }.count, 3)
        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.refreshSeconds), "300")
    }

    func testFailedRefreshKeepsLastKnownGood() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()

        transport.handler = { _, _, _, _ in throw MockInfisicalTransport.MockError.boom }
        await settings.refresh() // never throws

        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://quota.example.com/api/quota-windows",
                       "a failed refresh must keep serving the last-known-good cache")
        XCTAssertNotNil(settings.lastError)
    }

    func testFailedWriteThroughRejectsAndLeavesCacheUntouched() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://old.example.com/api/quota-windows",
        ])
        try await settings.load()

        transport.handler = { method, url, _, _ in
            if url.path.hasSuffix("/api/v1/auth/universal-auth/login"), method == "POST" {
                return (loginPayload(), 200)
            }
            if method == "PATCH" { return (Data(), 500) }
            throw MockInfisicalTransport.MockError.unexpected
        }

        do {
            try await settings.set("https://new.example.com/api/quota-windows",
                                   for: InfisicalSettings.Keys.pullEndpoint)
            XCTFail("a failed Infisical write must fail the save")
        } catch {
            // Expected: the save is rejected.
        }

        XCTAssertEqual(settings.value(for: InfisicalSettings.Keys.pullEndpoint),
                       "https://old.example.com/api/quota-windows",
                       "a failed write must not move the cache")
    }

    func testLoadWithoutProvisionedIdentityThrows() async {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)

        do {
            try await settings.load()
            XCTFail("load without an identity must throw")
        } catch {
            XCTAssertTrue(error is InfisicalSettings.SettingsError)
        }
        XCTAssertEqual(transport.requestCount, 0)
    }

    func testRefreshWithoutProvisionedIdentityIsANoOp() async {
        let transport = MockInfisicalTransport()
        let settings = InfisicalSettings(transport: transport)

        await settings.refresh()

        XCTAssertEqual(transport.requestCount, 0)
        XCTAssertNil(settings.lastError)
    }

    func testEmptyValuesAreTreatedAsAbsent() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pushEndpoint: "",
        ])
        try await settings.load()

        XCTAssertNil(settings.value(for: InfisicalSettings.Keys.pushEndpoint))
    }

    func testRefreshIntervalDefaultsAndClamps() async throws {
        let transport = MockInfisicalTransport()

        // Absent → default.
        var settings = configuredSettings(transport: transport)
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.defaultRefreshInterval)

        // Parseable → honoured.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "120"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, 120)

        // Unparseable → default.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "soon"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.defaultRefreshInterval)

        // Absurdly small → clamped, so a typo cannot hot-loop the timer.
        settings = configuredSettings(transport: transport,
                                      values: [InfisicalSettings.Keys.refreshSeconds: "5"])
        try await settings.load()
        XCTAssertEqual(settings.refreshInterval, InfisicalSettings.minimumRefreshInterval)
    }

    func testDefaultEnvironmentFollowsBuildVariant() {
        XCTAssertEqual(InfisicalSettings.defaultEnvironment(bundleIdentifier: "com.jays.agent-bar.mac"),
                       "prod")
        XCTAssertEqual(InfisicalSettings.defaultEnvironment(bundleIdentifier: "com.jays.agent-bar.mac.dev"),
                       "dev")
        XCTAssertEqual(InfisicalSettings.defaultEnvironment(bundleIdentifier: nil), "prod")
    }

    func testClearConfigurationEmptiesCache() async throws {
        let transport = MockInfisicalTransport()
        let settings = configuredSettings(transport: transport, values: [
            InfisicalSettings.Keys.pullEndpoint: "https://quota.example.com/api/quota-windows",
        ])
        try await settings.load()
        XCTAssertTrue(settings.isProvisioned)

        settings.clearConfiguration()

        XCTAssertFalse(settings.isProvisioned)
        XCTAssertNil(settings.value(for: InfisicalSettings.Keys.pullEndpoint))
    }
}
