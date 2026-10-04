import Combine
import Foundation
import QuotaCore
#if canImport(WidgetKit)
import WidgetKit
#endif

enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar, dock, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .dock: return "Dock"
        case .both: return "Both"
        }
    }
}

/// How the status item's own mark is drawn, independent of the per-provider
/// Logo Style that governs the popover and sidebar.
///
/// The menu bar sits on a system surface the owner does not control, and the
/// status item is selected and tinted by macOS, so an owner often wants the
/// silhouette there even while the popover shows the brand colour.  That used
/// to mean editing each provider one at a time.
public enum MenuBarMarkStyle: String, CaseIterable, Identifiable {
    case followProvider
    case lightDark
    case colour

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followProvider: return "Match Provider"
        case .lightDark: return "Light/Dark"
        case .colour: return "Colour"
        }
    }

    /// The style to actually draw with, given what the provider is set to.
    public func resolved(_ providerStyle: MarkStyle) -> MarkStyle {
        switch self {
        case .followProvider: return providerStyle
        case .lightDark: return .template
        case .colour: return .standard
        }
    }
}

public enum MenuBarStyle: String, CaseIterable, Identifiable {
    case symbolOnly = "symbolOnly"
    case symbolAndPercent = "symbolAndPercent"
    case percentOnly = "percentOnly"

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .symbolOnly: return "Symbol Only"
        case .symbolAndPercent: return "Symbol & Percentage"
        case .percentOnly: return "Percentage Only"
        }
    }
}

public enum QuotaViewLayout: String, CaseIterable, Identifiable {
    case summary = "allAtOnce"
    case detailed = "detailed"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .summary: return "Compact"
        case .detailed: return "Detailed"
        }
    }
}

/// Which appearance the app forces.  `system` follows the Mac's own setting.
enum AppAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
}

/// Which readings the Glance list shows.  One set at a time: the header's
/// two-box switch flips between them, and the choice survives a relaunch.
///
/// The raw values predate the "From Mac" / "From Fleet" names (owner ruling
/// 2026-09-30) and are what an existing install's defaults already hold, so
/// they stay as they are.
enum GlanceViewMode: String, CaseIterable, Identifiable {
    case fromMac = "thisMac"
    case fromFleet = "fleetReported"

    var id: String { rawValue }

    /// Title Case: the label on the switch itself, and what VoiceOver says.
    var title: String {
        switch self {
        case .fromMac: return "From Mac"
        case .fromFleet: return "From Fleet"
        }
    }

    /// What the list becomes when this side is picked: the switch's tooltip,
    /// and the hint VoiceOver adds after the label.
    var detail: String {
        switch self {
        case .fromMac: return "Quotas this Mac reads from the AI tools signed in on it."
        case .fromFleet: return "Quotas your other machines report to your fleet endpoint."
        }
    }
}

/// Whether a provider's windows were read on this Mac or pulled from the fleet.
enum QuotaOrigin: Equatable, Sendable {
    case local, fleet
}

/// Pulled windows that share one origin, before they are turned into rows.
struct FleetWindowGroup: Equatable {
    let id: String
    let title: String
    let windows: [QuotaWindow]
}

/// One reporting source's worth of fleet rows: everything the payload
/// attributes to one `source` or `sourceApp` (`FleetOrigin.identity`), which is
/// a machine only some of the time.
struct FleetGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let windowCount: Int
    let rows: [DisplaySection]
}

@MainActor
final class MonitorModel: ObservableObject {
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: "menuBarStyle") }
    }
    @Published var menuBarMarkStyle: MenuBarMarkStyle {
        didSet { defaults.set(menuBarMarkStyle.rawValue, forKey: "menuBarMarkStyle") }
    }
    /// The accent colour.  Stored through `AccentChoice` so the swatch, the
    /// default and the `Theme` lookup all read the same value.
    @Published var accent: AccentChoice {
        didSet { AccentChoice.current = accent }
    }
    @Published var highContrast: Bool {
        didSet { defaults.set(highContrast, forKey: "highContrast") }
    }
    /// Runaway-agent detection.  `AnomalyDetector` shipped in QuotaCore pure
    /// and tested but nothing called it; these are its two thresholds, exposed
    /// because "5x my average" is the wrong number for someone who writes long
    /// agents on purpose and the right one for someone who does not.
    @Published var anomalyBaselineMultiplier: Double {
        didSet {
            defaults.set(anomalyBaselineMultiplier, forKey: "anomalyBaselineMultiplier")
            refreshRunawayUsageState(recordSamples: false)
        }
    }
    @Published var anomalyPeakMultiplier: Double {
        didSet {
            defaults.set(anomalyPeakMultiplier, forKey: "anomalyPeakMultiplier")
            refreshRunawayUsageState(recordSamples: false)
        }
    }
    @Published var burnRateAlertsEnabled: Bool {
        didSet {
            defaults.set(burnRateAlertsEnabled, forKey: "burnRateAlertsEnabled")
            if burnRateAlertsEnabled {
                Task { await alarmManager.requestNotificationPermission() }
                refreshRunawayUsageState(recordSamples: false)
            } else {
                activeRunawayAnomalies = []
            }
        }
    }
    @Published private(set) var activeRunawayAnomalies: [AnomalyDetector.Anomaly] = []
    @Published var menuBarQuotaSelection: String {
        didSet { defaults.set(menuBarQuotaSelection, forKey: "menuBarQuotaSelection") }
    }
    @Published var viewLayout: QuotaViewLayout {
        didSet { defaults.set(viewLayout.rawValue, forKey: "quotaViewLayout") }
    }
    @Published var platformOrder: [String] {
        didSet { defaults.set(platformOrder, forKey: "platformOrder") }
    }
    @Published var platformCustomInfo: [String: PlatformCustomInfo] {
        didSet {
            if let data = try? JSONEncoder().encode(platformCustomInfo) {
                defaults.set(data, forKey: "platformCustomInfo")
            }
        }
    }
    /// Per-provider mark style.  Defaults to `template` so the menu bar still
    /// reads on Light and Dark surfaces; `standard` keeps the brand colors,
    /// `custom` resolves to a user-supplied file.  Persisted as a JSON map so
    /// new providers land on the default without an explicit row.
    @Published var markStyles: [String: MarkStyle] {
        didSet {
            if let data = try? JSONEncoder().encode(markStyles) {
                defaults.set(data, forKey: "markStyles")
            }
        }
    }
    /// Resolved absolute paths for any `custom` mark — written by Settings
    /// after a file picker returns.  Stored separately so a missing file (the
    /// owner deleted it from disk) can be reported as such, and so we can
    /// render the path in the Settings UI without re-scanning the directory.
    @Published var customMarkPaths: [String: String] {
        didSet { defaults.set(customMarkPaths, forKey: "customMarkPaths") }
    }
    /// Presentation mode for a custom mark: `.color` keeps original colors,
    /// `.template` renders as adaptive light/dark silhouette.
    @Published var customMarkModes: [String: CustomMarkMode] {
        didSet {
            if let data = try? JSONEncoder().encode(customMarkModes) {
                defaults.set(data, forKey: "customMarkModes")
            }
        }
    }
    /// Optional Dark mode variant paths for custom marks.
    @Published var customMarkDarkPaths: [String: String] {
        didSet { defaults.set(customMarkDarkPaths, forKey: "customMarkDarkPaths") }
    }
    @Published private(set) var response = QuotaResponse(generatedAt: "")
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastChecked: Date?
    @Published private(set) var issues: [String: String] = [:]
    /// Provider keys whose saved login is on this Mac but unreadable until the
    /// owner allows this build once.  Drives the Allow Access To Claude Code
    /// button and the Open Settings affordance beside the issue text.
    @Published private(set) var consentNeeded: Set<String> = []
    @Published private(set) var serverError: String?
    @Published private(set) var handoffError: String?
    @Published private(set) var now = Date()

    // Local & Remote Reading
    @Published private(set) var localEnabled: Bool
    @Published private(set) var serverEnabled: Bool
    @Published private(set) var endpoint: String
    @Published private(set) var hasSavedToken: Bool
    /// Whether this build can actually read the saved Read Token.  A rebuild
    /// under a different code identity leaves the item on disk and unreadable,
    /// and the owner needs to be told that in words rather than left with a
    /// pull that quietly fails.
    @Published private(set) var readTokenState: SavedTokenState = .none

    // Remote Sync / Push Sharing
    @Published private(set) var syncEnabled: Bool
    @Published private(set) var syncEndpoint: String
    @Published private(set) var syncFormat: QuotaSyncFormat
    @Published private(set) var hasSavedSyncToken: Bool
    /// The same, for the Ingest Token.
    @Published private(set) var syncTokenState: SavedTokenState = .none
    @Published private(set) var lastSyncTime: Date?
    @Published private(set) var lastSyncStatus: String?
    /// The last push failure, kept separately from `lastSyncStatus` so Settings
    /// can show it under the group that owns it.
    @Published private(set) var lastSyncError: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastPullTime: Date?

    // Presentation
    @Published var appearance: AppAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance") }
    }
    /// From Mac or From Fleet, remembered across launches.
    @Published var glanceView: GlanceViewMode {
        didSet { defaults.set(glanceView.rawValue, forKey: "glanceView") }
    }

    /// Where each provider's windows came from on the last refresh.
    @Published private(set) var originByProvider: [String: QuotaOrigin] = [:]

    /// Per-provider source ranking.  Each value is the ordered list of source
    /// IDs the owner wants to consider for that providerKey, highest priority
    /// first.  A source that has never been seen stays out of the list until
    /// it has produced at least one window.  Persisted as a JSON map so new
    /// providers land on the default (insertion order = observed order).
    @Published var sourceRank: [String: [String]] {
        didSet {
            if let data = try? JSONEncoder().encode(sourceRank) {
                defaults.set(data, forKey: "sourceRank")
            }
        }
    }
    /// Source IDs the owner has turned off, across every provider.  Disabled
    /// windows are dropped from `freshWindows`, the menu bar, the Console
    /// cards, and the Glance popover — they are still observed, so an owner
    /// who re-enables a source gets its windows back on the next refresh
    /// without re-pairing.
    @Published var disabledSources: Set<String> {
        didSet { defaults.set(Array(disabledSources), forKey: "disabledSources") }
    }

    public let alarmManager: ResetAlarmManager

    private let defaults: UserDefaults
    private let burnRateHistoryURL: URL
    private var lastRunawayAlertAt: [String: Double] = [:]
    private var hasCurrentLocalRead = false
    var localResultForTesting: LocalQuotaResult?
    var runawayNotificationForTesting: ((BurnRateNotification) -> Void)?
    var skipsSnapshotIOForTesting = false
    private var localWindows: [QuotaWindow] = []
    private var serverWindows: [QuotaWindow] = []
    @Published private(set) var fleetWindowGroups: [FleetWindowGroup] = []
    private var refreshTimer: Timer?
    private var clockTimer: Timer?
    private var request: Task<Void, Never>?
    private var revision = 0
    private let publisher = QuotaPublisher()
    /// Re-publishes the alarm manager's changes, so a view that observes this
    /// model redraws when All or a provider's bell flips.
    private var alarmChanges: AnyCancellable?
    /// Re-checks the saved-token states when `TokenStore` gains a token nobody
    /// was waiting for, so the Re-Authorize button clears without a refresh.
    private var tokenChanges: AnyCancellable?

    init(defaults: UserDefaults = .standard, burnRateHistoryURL: URL? = nil) {
        self.defaults = defaults
        self.burnRateHistoryURL = burnRateHistoryURL ?? BurnRateMonitor.historyURL
        self.lastRunawayAlertAt = defaults.dictionary(forKey: "runawayAlertLastSent") as? [String: Double] ?? [:]
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .both
        menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: "menuBarStyle") ?? "") ?? .symbolAndPercent
        menuBarMarkStyle = MenuBarMarkStyle(rawValue: defaults.string(forKey: "menuBarMarkStyle") ?? "")
            ?? .followProvider
        accent = AccentChoice.current
        highContrast = defaults.bool(forKey: "highContrast")
        burnRateAlertsEnabled = defaults.object(forKey: "burnRateAlertsEnabled") as? Bool ?? false
        anomalyBaselineMultiplier = defaults.object(forKey: "anomalyBaselineMultiplier") as? Double
            ?? BurnRateMonitor.recommendedBaselineMultiplier
        anomalyPeakMultiplier = defaults.object(forKey: "anomalyPeakMultiplier") as? Double
            ?? BurnRateMonitor.recommendedPeakMultiplier
        menuBarQuotaSelection = defaults.string(forKey: "menuBarQuotaSelection") ?? "auto_lowest_active"
        viewLayout = QuotaViewLayout(rawValue: defaults.string(forKey: "quotaViewLayout") ?? "") ?? .summary
        platformOrder = defaults.stringArray(forKey: "platformOrder") ?? []
        if let customData = defaults.data(forKey: "platformCustomInfo"),
           let decoded = try? JSONDecoder().decode([String: PlatformCustomInfo].self, from: customData) {
            platformCustomInfo = decoded
        } else {
            platformCustomInfo = [:]
        }
        if let styleData = defaults.data(forKey: "markStyles"),
           let decoded = try? JSONDecoder().decode([String: MarkStyle].self, from: styleData) {
            markStyles = decoded
        } else {
            markStyles = [:]
        }
        customMarkPaths = (defaults.dictionary(forKey: "customMarkPaths") as? [String: String]) ?? [:]
        if let modeData = defaults.data(forKey: "customMarkModes"),
           let decoded = try? JSONDecoder().decode([String: CustomMarkMode].self, from: modeData) {
            customMarkModes = decoded
        } else {
            customMarkModes = [:]
        }
        customMarkDarkPaths = (defaults.dictionary(forKey: "customMarkDarkPaths") as? [String: String]) ?? [:]
        if let rankData = defaults.data(forKey: "sourceRank"),
           let decoded = try? JSONDecoder().decode([String: [String]].self, from: rankData) {
            sourceRank = decoded
        } else {
            sourceRank = [:]
        }
        disabledSources = Set((defaults.stringArray(forKey: "disabledSources") ?? []))
        localEnabled = defaults.object(forKey: "localEnabled") as? Bool ?? true
        serverEnabled = defaults.bool(forKey: "serverEnabled")
        hasSavedToken = defaults.bool(forKey: "hasSavedToken")
        syncEnabled = defaults.bool(forKey: "syncEnabled")
        hasSavedSyncToken = defaults.bool(forKey: "hasSavedSyncToken")

        endpoint = defaults.string(forKey: "endpoint") ?? ""
        syncEndpoint = defaults.string(forKey: "syncEndpoint") ?? ""
        syncFormat = QuotaSyncFormat(rawValue: defaults.string(forKey: "syncFormat") ?? "") ?? .usageMonitorV2

        alarmManager = ResetAlarmManager(defaults: defaults)

        appearance = AppAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        glanceView = GlanceViewMode(rawValue: defaults.string(forKey: "glanceView") ?? "") ?? .fromMac
        alarmChanges = alarmManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tokenChanges = NotificationCenter.default.publisher(for: TokenStore.tokenBecameAvailable)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Answered from the cache: a token already held, or already
                // failed, is not asked for again.
                Task { @MainActor in await self?.refreshSavedTokenStates() }
            }
    }

    var sections: [QuotaPlatformSection] {
        let base = response.platformSections(now: now)
        if platformOrder.isEmpty { return base }
        var orderMap: [String: Int] = [:]
        for (idx, key) in platformOrder.enumerated() {
            orderMap[key] = idx
        }
        return base.sorted { (a, b) -> Bool in
            let idxA = orderMap[a.providerKey] ?? 999
            let idxB = orderMap[b.providerKey] ?? 999
            if idxA != idxB { return idxA < idxB }
            return a.providerLabel < b.providerLabel
        }
    }
    /// One row per platform, except Antigravity, which is one row per pool.
    /// Every surface that lists platforms reads this rather than `sections`.
    var displaySections: [DisplaySection] {
        sections.flatMap { DisplaySection.rows(for: $0, now: now) }
    }

    /// Windows whose percentage is real but meaningless: a five-hour Antigravity
    /// window under a pool whose weekly cap is already spent.  They are shown as
    /// "n/a" and never counted as near cap or picked as the lowest.
    var maskedWindowIds: Set<String> {
        AntigravityQuotaGroups.maskedWindowIds(
            in: sections.filter { $0.providerKey == AntigravityDisplay.providerKey }
                .flatMap { $0.windows.map(\.window) },
            now: now)
    }

    var freshWindows: [QuotaWindowSnapshot] {
        let masked = maskedWindowIds
        let visible = sections.flatMap(\.windows).filter {
            $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota
                && !masked.contains($0.window.id)
                && issues[$0.window.canonicalProviderKey] == nil
                && !disabledSources.contains($0.window.source ?? "")
        }
        // Order by provider rank, then by source rank within the provider, so
        // the menu bar, Glance, and Console cards all see the same preferred
        // window for a given provider and never disagree on the picked value.
        let rankByProvider = sourceRank
        return visible.sorted { lhs, rhs in
            let lProvider = lhs.window.canonicalProviderKey
            let rProvider = rhs.window.canonicalProviderKey
            let lSourceRank = rankByProvider[lProvider]?.firstIndex(of: lhs.window.source ?? "") ?? Int.max
            let rSourceRank = rankByProvider[rProvider]?.firstIndex(of: rhs.window.source ?? "") ?? Int.max
            if lProvider != rProvider { return lProvider < rProvider }
            if lSourceRank != rSourceRank { return lSourceRank < rSourceRank }
            return lhs.observedAt ?? .distantPast > rhs.observedAt ?? .distantPast
        }
    }
    var reportingCount: Int { Set(freshWindows.map { $0.window.canonicalProviderKey }).count }
    var nearCapCount: Int { freshWindows.filter { ($0.remainingPercent ?? 100) <= 20 }.count }
    var nextReset: Date? { freshWindows.compactMap(\.resetAt).filter { $0 > now }.min() }

    /// All individual quotas available for pinning to the menu bar.
    var availableMenuBarQuotas: [(id: String, label: String)] {
        var result: [(id: String, label: String)] = [
            (id: "auto_lowest_active", label: "Lowest active quota"),
            (id: "auto_lowest", label: "Lowest quota"),
        ]
        for row in displaySections {
            let windows = row.section.windows.filter {
                $0.isFresh && $0.remainingPercent != nil && !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
            }
            for snapshot in windows {
                let label = "\(row.title) · \(AntigravityDisplay.windowLabel(snapshot.window.label))"
                result.append((id: snapshot.window.id, label: label))
            }
        }
        // A pinned window can be absent — a retired platform, a reader that is
        // signed out, a refresh that failed.  Without a matching tag the Picker
        // draws empty and says nothing, so the selection carries its own row
        // rather than being silently dropped, which would lose the pin.
        if !result.contains(where: { $0.id == menuBarQuotaSelection }) {
            result.append((id: menuBarQuotaSelection, label: "Pinned quota unavailable"))
        }
        return result
    }

    /// The row a window belongs to, so the menu bar and the Next Reset tile can
    /// name the Antigravity pool rather than the platform.
    func displayRow(for window: QuotaWindow) -> DisplaySection? {
        displaySections.first { $0.section.windows.contains { $0.window.id == window.id } }
    }

    /// The window that should drive the menu bar display.
    var menuBarTargetSnapshot: QuotaWindowSnapshot? {
        switch menuBarQuotaSelection {
        case "auto_lowest_active":
            // Prefer the highest-ranked fresh window from a provider that has
            // any non-zero quota; this is what "auto" means once the owner has
            // ranked sources.  The pre-rank behaviour (lowest % across all
            // windows) is preserved by the fallback when no rank is set.
            let nonZero = freshWindows.filter { ($0.remainingPercent ?? 0) > 0 }
            let pool = nonZero.isEmpty ? freshWindows : nonZero
            return pickMenuBarTarget(from: pool)
        case "auto_lowest":
            return pickMenuBarTarget(from: freshWindows)
        default:
            // An explicit pin is honoured regardless of rank — the owner asked
            // for this specific window and we do not second-guess.
            if let pinned = freshWindows.first(where: { $0.window.id == menuBarQuotaSelection }) {
                return pinned
            }
            return pickMenuBarTarget(from: freshWindows)
        }
    }

    /// Pick the menu-bar target from `pool` by lowest remaining percent.
    /// When the owner has ranked sources, the comparison uses the rank to
    /// break a tie so two windows with the same percentage prefer the
    /// higher-ranked source.
    private func pickMenuBarTarget(from pool: [QuotaWindowSnapshot]) -> QuotaWindowSnapshot? {
        guard !pool.isEmpty else { return nil }
        return pool.min { lhs, rhs in
            let lPct = lhs.remainingPercent ?? 100
            let rPct = rhs.remainingPercent ?? 100
            if lPct != rPct { return lPct < rPct }
            // Tie-break by rank within the same provider.
            if lhs.window.canonicalProviderKey == rhs.window.canonicalProviderKey {
                let rank = sourceRank[lhs.window.canonicalProviderKey] ?? []
                let lRank = rank.firstIndex(of: lhs.window.source ?? "") ?? Int.max
                let rRank = rank.firstIndex(of: rhs.window.source ?? "") ?? Int.max
                if lRank != rRank { return lRank < rRank }
            }
            return lhs.observedAt ?? .distantPast > rhs.observedAt ?? .distantPast
        }
    }

    var menuBarTitle: String {
        guard menuBarStyle != .symbolOnly else { return "" }
        guard let target = menuBarTargetSnapshot, let pct = target.remainingPercent else { return "—" }
        return "\(Int(pct.rounded()))%"
    }

    // MARK: - Source ranking

    /// The distinct source IDs observed on the most recent refresh for
    /// `providerKey`, in the order the owner has them ranked.  Sources that
    /// have never been ranked land at the tail in their natural order so a
    /// fresh reader is visible the first time it reports.  Windows without a
    /// source string (the field is optional on the wire) are filtered out —
    /// there is nothing to toggle or rank against an empty identifier.
    func availableSources(for providerKey: String) -> [String] {
        let observed = sections.flatMap { $0.windows }
            .filter { $0.window.canonicalProviderKey == providerKey }
            .compactMap { $0.window.source?.isEmpty == false ? $0.window.source : nil }
            .reduce(into: [String]()) { acc, source in
                if !acc.contains(source) { acc.append(source) }
            }
        let ranked = sourceRank[providerKey] ?? []
        let rankIndex = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        return observed.sorted { lhs, rhs in
            switch (rankIndex[lhs], rankIndex[rhs]) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return lhs < rhs
            }
        }
    }

    /// Windows for `providerKey` with disabled sources dropped and the rest
    /// sorted by rank.  Unranked sources keep their observed order.  Used by
    /// both the Console cards and the menu-bar target picker so the two
    /// surfaces never disagree on which source a number came from.
    func orderedWindows(for providerKey: String) -> [QuotaWindowSnapshot] {
        let all = sections.flatMap { $0.windows }.filter { $0.window.canonicalProviderKey == providerKey }
        let visible = all.filter { snapshot in
            guard let source = snapshot.window.source, !source.isEmpty else { return false }
            return !disabledSources.contains(source)
        }
        let ranked = sourceRank[providerKey] ?? []
        let rankIndex = Dictionary(uniqueKeysWithValues: ranked.enumerated().map { ($1, $0) })
        return visible.sorted { lhs, rhs in
            let lSource = lhs.window.source ?? ""
            let rSource = rhs.window.source ?? ""
            switch (rankIndex[lSource], rankIndex[rSource]) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):
                return lhs.observedAt ?? .distantPast > rhs.observedAt ?? .distantPast
            }
        }
    }

    /// Persist a fresh ranking for `providerKey`.  Sources not in the new
    /// order are appended at the tail so reordering never drops a source the
    /// owner is still using.
    func setSourceRank(_ rank: [String], for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let known = Set(availableSources(for: key))
        let head = rank.filter { known.contains($0) }
        let tail = known.subtracting(head)
        let merged = head + Array(tail).sorted()
        guard sourceRank[key] != merged else { return }
        sourceRank[key] = merged
    }

    func moveSource(_ source: String, by delta: Int, for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var current = sourceRank[key] ?? availableSources(for: key)
        guard let idx = current.firstIndex(of: source) else { return }
        let target = idx + delta
        guard target >= 0 && target < current.count else { return }
        current.swapAt(idx, target)
        sourceRank[key] = current
    }

    func setSourceEnabled(_ enabled: Bool, _ source: String, for providerKey: String) {
        var disabled = disabledSources
        if enabled { disabled.remove(source) } else { disabled.insert(source) }
        guard disabled != disabledSources else { return }
        disabledSources = disabled
        _ = providerKey // source keys are global; providerKey is for future per-provider disable
    }

    // MARK: - Test injection
    //
    // The reader pipeline is async and platform-bound.  Tests that need a
    // known set of windows inject through this seam so the rank/filter logic
    // can be exercised in isolation.

    func injectForTests(sections: [QuotaPlatformSection], now: Date = Date(),
                        issues: [String: String] = [:]) {
        self.response = QuotaResponse(
            generatedAt: ISO8601DateFormatter().string(from: now),
            windows: sections.flatMap { $0.windows.map(\.window) }
        )
        self.now = now
        self.issues = issues
    }

    /// The fleet half of the seam: pulled windows grouped by origin, plus the
    /// time the header shows, for the Glance tests and renders.
    func injectFleetForTests(groups: [FleetWindowGroup], checkedAt: Date? = nil) {
        self.fleetWindowGroups = groups
        if let checkedAt {
            self.lastChecked = checkedAt
            self.lastPullTime = checkedAt
        }
    }

    func injectRunawayAnomaliesForTests(_ anomalies: [AnomalyDetector.Anomaly]) {
        activeRunawayAnomalies = anomalies
    }

    var menuBarDetail: String {
        guard let target = menuBarTargetSnapshot else { return "No current quota report" }
        let title = displayRow(for: target.window)?.title
            ?? sections.first { $0.providerKey == target.window.canonicalProviderKey }?.providerLabel
            ?? target.window.provider
        let pct = target.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
        return "\(title), \(windowCadenceName(target.window)): \(pct) remaining"
    }

    // MARK: - Reset Alarms

    /// All: every provider's reset alarm is on.  Bound to the Glance header's
    /// bell and to Settings → Alerts & Alarms.
    var alarmsAll: Bool {
        get { alarmManager.allProvidersEnabled }
        set { alarmManager.allProvidersEnabled = newValue }
    }

    var soundOnReset: Bool {
        get { alarmManager.alarmSound.isAudible }
        set { alarmManager.alarmSound = newValue ? .systemDefault : .silent }
    }

    /// The picked sound for the reset alarm.  Backed by the same
    /// underlying `ResetAlarmSound` value the iOS companion reads from
    /// the App Group defaults, so a sound set on Mac carries over to
    /// the iOS device for the same owner.  See
    /// `Sources/QuotaCore/ResetAlarmSound.swift` for the catalogue.
    var alarmSound: ResetAlarmSound {
        get { alarmManager.alarmSound }
        set { alarmManager.alarmSound = newValue }
    }

    /// Previews the picked sound.  Wraps the underlying manager method
    /// so a `Settings → Notifications → Sound → Preview` button can call
    /// without exposing the manager.
    func previewResetSound() { alarmManager.previewChosenSound() }

    /// Whether `rowId`'s reset alarm will ring: under All, always.
    func isAlarmEnabled(for rowId: String) -> Bool {
        alarmManager.isAlarmEnabled(for: rowId)
    }

    /// The owner's own pick for `rowId`, which the per-row bell shows.
    func isProviderAlarmSelected(_ rowId: String) -> Bool {
        alarmManager.isProviderSelected(rowId)
    }

    func toggleAlarm(for rowId: String) {
        alarmManager.toggleProviderAlarm(for: rowId)
    }

    /// Every reading the reset alarm watches: this Mac's rows, and each fleet
    /// machine's rows in a scope of their own.  Keyed by row, so a provider's
    /// bell covers it in both views.
    func resetAlarmObservationsForCurrentReadings() -> [ResetAlarmObservation] {
        var observations = displaySections.flatMap { resetAlarmObservations(for: $0, scope: "local") }
        for group in fleetGroups {
            observations += group.rows.flatMap { resetAlarmObservations(for: $0, scope: "fleet:\(group.id)") }
        }
        return observations
    }

    func start() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = Date()
                // A window with an alarm on whose reset time has come since the
                // last refresh: read again now, so the alarm rings on time
                // rather than up to five minutes late.
                let lastChecked = self.lastChecked ?? .distantPast
                let pendingReset = self.displaySections.contains { row in
                    self.isAlarmEnabled(for: row.id) && row.section.windows.contains { snapshot in
                        guard let reset = snapshot.resetAt else { return false }
                        return reset <= self.now && reset > lastChecked
                    }
                }
                if pendingReset {
                    self.refresh()
                }
            }
        }
    }

    func stop() {
        revision += 1
        request?.cancel()
        request = nil
        isRefreshing = false
        refreshTimer?.invalidate()
        clockTimer?.invalidate()
    }

    func movePlatformUp(providerKey: String) {
        var current = platformOrder.isEmpty ? sections.map(\.providerKey) : platformOrder
        guard let idx = current.firstIndex(of: providerKey), idx > 0 else { return }
        current.swapAt(idx, idx - 1)
        platformOrder = current
    }

    func movePlatformDown(providerKey: String) {
        var current = platformOrder.isEmpty ? sections.map(\.providerKey) : platformOrder
        guard let idx = current.firstIndex(of: providerKey), idx < current.count - 1 else { return }
        current.swapAt(idx, idx + 1)
        platformOrder = current
    }

    func resetPlatformOrder() {
        platformOrder = []
    }

    func setCustomInfo(for providerKey: String, info: PlatformCustomInfo) {
        platformCustomInfo[providerKey] = info
    }

    // MARK: - Mark Style

    /// The mark style for a provider.  Unknown keys return `.template`, which
    /// matches the pre-picker default of every shipped mark.
    /// The mark style for the menu bar status item.  Template (monochrome)
    /// by default so the icon inverts cleanly against light and dark menu bar
    /// surfaces.  Owners who want brand colour can override per-provider in
    /// Settings → Logo Style.
    func markStyle(for providerKey: String) -> MarkStyle {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Pool-qualified keys ("google-antigravity:gemini") fall back to the
        // platform key, so a style the owner set for "Antigravity" before the
        // pools were listed separately still applies to both pools instead of
        // silently reverting them to the default.
        let platform = key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
        if let style = markStyles[key] ?? markStyles[platform] { return style }
        if PlatformLogoImage.hasCustomMark(providerKey: key) || PlatformLogoImage.hasCustomMark(providerKey: platform) {
            return .custom
        }
        return .template
    }

    /// The mark style for the glance popover.  `standard` (colour) by
    /// default — the popover sits on the system surface, not the menu bar,
    /// so the brand colours read better than a monochrome silhouette.
    func glanceMarkStyle(for providerKey: String) -> MarkStyle {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let platform = key.split(separator: ":", maxSplits: 1).first.map(String.init) ?? key
        if let style = markStyles[key] ?? markStyles[platform] { return style }
        if PlatformLogoImage.hasCustomMark(providerKey: key) || PlatformLogoImage.hasCustomMark(providerKey: platform) {
            return .custom
        }
        return .standard
    }

    func setMarkStyle(_ style: MarkStyle, for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard markStyles[key] != style else { return }
        markStyles[key] = style
    }

    func customMarkMode(for providerKey: String) -> CustomMarkMode {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return customMarkModes[key] ?? .color
    }

    func setCustomMarkMode(_ mode: CustomMarkMode, for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        customMarkModes[key] = mode
        PlatformLogoImage.setCustomMarkMode(mode, for: key)
        objectWillChange.send()
    }

    func customMarkURL(for providerKey: String, isDarkMode: Bool = false) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isDarkMode {
            if let path = customMarkDarkPaths[key], FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return PlatformLogoImage.customDarkMarkURL(providerKey: key)
        }
        if let path = customMarkPaths[key], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return PlatformLogoImage.customPrimaryMarkURL(providerKey: key)
    }

    /// Persist a custom mark for `providerKey`.  Reads the file out of the
    /// picker URL into `~/Library/Application Support/CodeCaps/CustomMarks/`
    /// via `PlatformLogoImage.importCustomMark`, then records the path so the
    /// Settings UI can show "Open in Finder" and "Remove".
    @discardableResult
    func setCustomMark(at source: URL, for providerKey: String, isDarkMode: Bool = false) -> URL? {
        guard let stored = PlatformLogoImage.importCustomMark(from: source, providerKey: providerKey, isDarkMode: isDarkMode) else {
            return nil
        }
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isDarkMode {
            customMarkDarkPaths[key] = stored.path
        } else {
            customMarkPaths[key] = stored.path
            markStyles[key] = .custom
        }
        objectWillChange.send()
        return stored
    }

    func clearCustomMark(for providerKey: String, isDarkMode: Bool? = nil) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        PlatformLogoImage.removeCustomMark(providerKey: key, isDarkMode: isDarkMode)
        if let isDarkMode {
            if isDarkMode {
                customMarkDarkPaths.removeValue(forKey: key)
            } else {
                customMarkPaths.removeValue(forKey: key)
                if markStyles[key] == .custom { markStyles[key] = .template }
            }
        } else {
            customMarkPaths.removeValue(forKey: key)
            customMarkDarkPaths.removeValue(forKey: key)
            customMarkModes.removeValue(forKey: key)
            // Falling back to the bundled asset is the safer choice: an owner who
            // removes a custom mark presumably still wants *some* icon.
            if markStyles[key] == .custom { markStyles[key] = .template }
        }
        objectWillChange.send()
    }

    /// Serializes all currently installed custom marks so they can be exported to
    /// local/shared snapshots and automatically synced to the iOS Companion app.
    func exportedCustomMarks() -> [String: CustomMarkPayload] {
        var result: [String: CustomMarkPayload] = [:]
        let dir = PlatformLogoImage.customMarksDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return result
        }
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            let ext = file.pathExtension.lowercased()
            guard !name.hasSuffix("-dark"), ["png", "svg", "jpg", "jpeg"].contains(ext) else { continue }
            guard let data = try? Data(contentsOf: file) else { continue }
            let base64 = data.base64EncodedString()
            let mode = customMarkMode(for: name).rawValue
            var darkBase64: String? = nil
            if let darkUrl = PlatformLogoImage.customDarkMarkURL(providerKey: name),
               let darkData = try? Data(contentsOf: darkUrl) {
                darkBase64 = darkData.base64EncodedString()
            }
            result[name] = CustomMarkPayload(data: base64, darkData: darkBase64, mode: mode, ext: ext)
        }
        return result
    }

    /// Live binding for the local-readers toggle.  Writing the default and
    /// refreshing in one call is what lets the Settings toggle apply on the spot
    /// instead of waiting for a save.
    func setLocalEnabled(_ value: Bool) {
        guard value != localEnabled else { return }
        localEnabled = value
        defaults.set(value, forKey: "localEnabled")
        if !value {
            hasCurrentLocalRead = false
            localWindows = []
            activeRunawayAnomalies = []
        }
        refresh()
    }

    /// Turns push sharing off without needing a valid endpoint.  Turning it on
    /// always goes through `saveSyncSettings`, which validates the endpoint.
    func disableSync() {
        guard syncEnabled else { return }
        syncEnabled = false
        defaults.set(false, forKey: "syncEnabled")
    }

    /// Turns fleet pull off without needing a valid endpoint.  Turning it on
    /// always goes through `saveConnection`, which validates the endpoint.
    func disableServerPull() {
        guard serverEnabled else { return }
        serverEnabled = false
        defaults.set(false, forKey: "serverEnabled")
        refresh()
    }

    /// The distinct origin labels carried by fleet windows, sorted.
    var fleetSourceLabels: [String] { fleetWindowGroups.map(\.title) }

    var fleetWindowCount: Int { fleetWindowGroups.reduce(0) { $0 + $1.windows.count } }

    /// Every pulled window, rendered.  The rows are grouped by the origin the
    /// payload carries, and a group's rows are built exactly like local ones —
    /// including the Antigravity pool split.
    var fleetGroups: [FleetGroup] {
        fleetWindowGroups.map { group in
            let sections = QuotaResponse(generatedAt: "", windows: group.windows)
                .platformSections(now: now)
                .filter { !$0.windows.isEmpty }
            return FleetGroup(id: group.id,
                              title: group.title,
                              windowCount: group.windows.count,
                              rows: sections.flatMap { DisplaySection.rows(for: $0, now: now) })
        }
    }

    // MARK: - Saved Token Availability

    /// Records what this build can see of both saved tokens.  The answers come
    /// from `TokenStore`'s cache, which asks the Keychain at most once per
    /// token per launch, so opening Settings makes no Keychain request for a
    /// token this launch already holds or already failed to read.  Nothing
    /// here prompts: the interactive read lives behind the Re-Authorize Saved
    /// Token button and is never reached from here.
    func refreshSavedTokenStates() async {
        let readOK = hasSavedToken && !endpoint.isEmpty
            ? await TokenStore.read(server: endpoint, service: TokenStore.readService) != nil
            : false
        let syncOK = hasSavedSyncToken && !syncEndpoint.isEmpty
            ? await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService) != nil
            : false
        readTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedToken, silentReadSucceeded: readOK)
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedSyncToken, silentReadSucceeded: syncOK)
    }

    /// One interactive read, so macOS can show its own panel and the owner can
    /// press Always Allow.  On success the pull is refreshed immediately.
    func reauthorizeReadToken() async -> (success: Bool, message: String) {
        let token = await TokenStore.readAllowingInteraction(server: endpoint, service: TokenStore.readService)
        let ok = !(token.map(sanitizedToken(_:)) ?? "").isEmpty
        readTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedToken, silentReadSucceeded: ok)
        if ok {
            serverError = nil
            refresh()
            return (true, "The saved token is readable again.")
        }
        return (false, "The saved token is still unavailable." + sentenceGap + "Paste the token again.")
    }

    func reauthorizeSyncToken() async -> (success: Bool, message: String) {
        let token = await TokenStore.readAllowingInteraction(server: syncEndpoint, service: TokenStore.syncService)
        let ok = !(token.map(sanitizedToken(_:)) ?? "").isEmpty
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedSyncToken, silentReadSucceeded: ok)
        if ok {
            lastSyncError = nil
            return (true, "The saved token is readable again.")
        }
        return (false, "The saved token is still unavailable." + sentenceGap + "Paste the token again.")
    }

    // MARK: - Claude Code Consent

    /// One interactive read of Claude Code's own saved login, through the same
    /// `security` tool the refresh loop reads with, so macOS can show its panel
    /// and an Always Allow applies to the identity the loop actually uses.
    /// Reached only from Allow Access To Claude Code; the refresh loop never
    /// gets here, and nothing on this path writes to or deletes Claude Code's
    /// item.
    func allowClaudeCodeAccess() async -> (success: Bool, message: String) {
        let granted = await ClaudeCredentialSource.readAllowingInteraction()
        if granted {
            consentNeeded.remove("anthropic")
            refresh()
            return (true, "Claude Code's saved login is readable now.")
        }
        return (false, "Access was not granted." + sentenceGap
                + "Try again and choose Always Allow when macOS asks.")
    }

    // MARK: - Server Pull Settings

    func testPullConnection(endpoint input: String, token inputToken: String) async -> (success: Bool, message: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL." + sentenceGap + "Use HTTPS, or HTTP for localhost only.")
        }
        let cleanToken = sanitizedToken(inputToken)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: value, service: TokenStore.readService).map(sanitizedToken(_:))
        guard let token = resolvedToken, !token.isEmpty else {
            return (false, "Please provide a valid Read Token.")
        }
        do {
            let client = try QuotaClient(endpoint: url, token: token)
            let res = try await client.fetch()
            let count = res.windows.count
            return (true, "Connected! Received \(count) quota window\(count == 1 ? "" : "s").")
        } catch {
            let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return (false, desc)
        }
    }

    func saveConnection(local: Bool, server: Bool, endpoint input: String, token: String) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else { throw QuotaClientError.invalidEndpoint }
        let cleanToken = sanitizedToken(token)
        if !cleanToken.isEmpty {
            guard !cleanToken.contains("\n"), !cleanToken.contains("\r") else { throw QuotaClientError.invalidToken }
            try await TokenStore.save(cleanToken, server: value, service: TokenStore.readService)
        }
        // Infisical is the source of truth for the pull endpoint: the write
        // lands there before any local state moves, and a failed write fails
        // the save — the cache and Infisical never diverge silently.  See
        // INFISICAL.md.  A no-op until the owner provisions an identity under
        // Settings → Infisical Sync.  Placed after the token save so a
        // Keychain failure cannot leave Infisical ahead of the local cache.
        try await InfisicalSettings.shared.writeThrough(value, for: InfisicalSettings.Keys.pullEndpoint)
        let savedToken = !cleanToken.isEmpty ? cleanToken : server ? await TokenStore.read(server: value, service: TokenStore.readService) : nil
        if server && savedToken == nil { throw QuotaClientError.invalidToken }
        let saved = savedToken != nil || (value == endpoint && hasSavedToken)
        revision += 1
        request?.cancel()
        request = nil
        isRefreshing = false
        localEnabled = local
        serverEnabled = server
        endpoint = value
        hasSavedToken = saved
        readTokenState = SavedTokenState.resolve(hasSavedFlag: saved, silentReadSucceeded: savedToken != nil)
        defaults.set(saved, forKey: "hasSavedToken")
        defaults.set(local, forKey: "localEnabled")
        defaults.set(server, forKey: "serverEnabled")
        defaults.set(value, forKey: "endpoint")
        localWindows = []
        hasCurrentLocalRead = false
        activeRunawayAnomalies = []
        serverWindows = []
        response = QuotaResponse(generatedAt: "")
        issues = [:]
        serverError = nil
        lastChecked = nil
        refresh()
    }

    func forgetServer() async throws {
        try await TokenStore.delete(server: endpoint, service: TokenStore.readService)
        hasSavedToken = false
        readTokenState = .none
        defaults.set(false, forKey: "hasSavedToken")
        try await saveConnection(local: localEnabled, server: false, endpoint: endpoint, token: "")
    }

    // MARK: - Server Push Sync Settings

    func saveSyncSettings(enabled: Bool, endpoint input: String, token: String, format: QuotaSyncFormat) async throws {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), QuotaClient.isAllowedEndpoint(url) else {
            throw QuotaPublisherError.invalidEndpoint
        }
        let cleanToken = sanitizedToken(token)
        if !cleanToken.isEmpty {
            try await TokenStore.save(cleanToken, server: value, service: TokenStore.syncService)
        }
        // Infisical is the source of truth for the push endpoint: the write
        // lands there before any local state moves, and a failed write fails
        // the save — the cache and Infisical never diverge silently.  See
        // INFISICAL.md.  A no-op until the owner provisions an identity under
        // Settings → Infisical Sync.  Placed after the token save so a
        // Keychain failure cannot leave Infisical ahead of the local cache.
        try await InfisicalSettings.shared.writeThrough(value, for: InfisicalSettings.Keys.pushEndpoint)
        let savedToken = !cleanToken.isEmpty ? cleanToken : enabled ? await TokenStore.read(server: value, service: TokenStore.syncService) : nil
        let saved = savedToken != nil || (value == syncEndpoint && hasSavedSyncToken)

        syncEnabled = enabled
        syncEndpoint = value
        syncFormat = format
        hasSavedSyncToken = saved
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: saved, silentReadSucceeded: savedToken != nil)

        defaults.set(enabled, forKey: "syncEnabled")
        defaults.set(value, forKey: "syncEndpoint")
        defaults.set(format.rawValue, forKey: "syncFormat")
        defaults.set(saved, forKey: "hasSavedSyncToken")

        if enabled && !localWindows.isEmpty {
            await pushQuotasIfEnabled(windows: localWindows)
        }
    }

    func forgetSyncServer() async throws {
        try await TokenStore.delete(server: syncEndpoint, service: TokenStore.syncService)
        hasSavedSyncToken = false
        syncTokenState = .none
        defaults.set(false, forKey: "hasSavedSyncToken")
        try await saveSyncSettings(enabled: false, endpoint: syncEndpoint, token: "", format: syncFormat)
    }

    // MARK: - Infisical Source of Truth

    /// Adopts the Infisical-provided endpoints for keys the owner never set
    /// locally, so a fresh install picks up the fleet defaults without the
    /// owner typing them.  Called after every successful Infisical load and
    /// refresh.  A deliberately cleared field (stored as "") is never
    /// overridden — clearing is the owner's explicit "nowhere", and
    /// `SettingsMigrationTests` pins that behaviour.
    func adoptInfisicalEndpointsIfUnset() {
        let settings = InfisicalSettings.shared
        guard settings.isProvisioned else { return }
        if defaults.string(forKey: "endpoint") == nil,
           let remote = settings.value(for: InfisicalSettings.Keys.pullEndpoint) {
            endpoint = remote
            defaults.set(remote, forKey: "endpoint")
        }
        if defaults.string(forKey: "syncEndpoint") == nil,
           let remote = settings.value(for: InfisicalSettings.Keys.pushEndpoint) {
            syncEndpoint = remote
            defaults.set(remote, forKey: "syncEndpoint")
        }
    }

    func testAndPushSync(endpoint input: String = "", token inputToken: String = "", format inputFormat: QuotaSyncFormat? = nil) async -> (success: Bool, message: String) {
        let endpointValue = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetEndpoint = !endpointValue.isEmpty ? endpointValue : syncEndpoint
        guard let url = URL(string: targetEndpoint), QuotaClient.isAllowedEndpoint(url) else {
            return (false, "Invalid endpoint URL." + sentenceGap + "Use HTTPS, or HTTP for localhost only.")
        }
        let windowsToPush = localWindows.isEmpty ? AntigravityQuotaGroups.normalize(await Self.readLocalSources().windows) : localWindows
        guard !windowsToPush.isEmpty else {
            return (false, "No local agent quotas available to push.")
        }
        let cleanToken = sanitizedToken(inputToken)
        let resolvedToken = !cleanToken.isEmpty ? cleanToken : await TokenStore.read(server: targetEndpoint, service: TokenStore.syncService).map(sanitizedToken(_:))
        guard let token = resolvedToken, !token.isEmpty else {
            return (false, "Please provide a valid Ingest Token.")
        }
        let targetFormat = inputFormat ?? syncFormat
        do {
            let result = try await publisher.publish(
                windows: windowsToPush,
                to: url,
                token: token,
                format: targetFormat
            )
            self.lastSyncTime = Date()
            self.lastSyncStatus = result.message
            self.lastSyncError = nil
            return (true, result.message)
        } catch {
            let errorDesc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastSyncStatus = "Error: \(errorDesc)"
            self.lastSyncError = errorDesc
            return (false, errorDesc)
        }
    }

    private func pushQuotasIfEnabled(windows: [QuotaWindow]) async {
        guard syncEnabled, let url = URL(string: syncEndpoint), QuotaClient.isAllowedEndpoint(url), !windows.isEmpty else { return }
        isSyncing = true
        defer { isSyncing = false }
        let token = await TokenStore.read(server: syncEndpoint, service: TokenStore.syncService).map(sanitizedToken(_:))
        // Served from the token cache after the first read of the launch.  A
        // read that failed or timed out stays failed until the owner saves or
        // re-authorizes the token, so say so where the button is.
        syncTokenState = SavedTokenState.resolve(hasSavedFlag: hasSavedSyncToken,
                                                 silentReadSucceeded: !(token ?? "").isEmpty)
        do {
            let result = try await publisher.publish(windows: windows, to: url, token: token, format: syncFormat)
            self.lastSyncTime = Date()
            self.lastSyncStatus = result.message
            self.lastSyncError = nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self.lastSyncStatus = "Error: \(message)"
            self.lastSyncError = message
        }
    }

    // MARK: - Refresh Loop

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let generation = revision
        let useLocal = localEnabled
        let useServer = serverEnabled
        let currentEndpoint = endpoint
        request = Task { [weak self] in
            let resultForTesting = self?.localResultForTesting
            async let localRead = Self.readLocalResult(useLocal: useLocal, testingResult: resultForTesting)
            var newServer: QuotaResponse?
            var failure: String?
            // The pull's own read doubles as the availability check, so the
            // caption below the group header costs no extra Keychain traffic.
            // After the first read of the launch it is served from memory, and
            // a failed read is not retried here (see `TokenCache`).
            var savedTokenReadable = false
            if useServer {
                let token = await TokenStore.read(server: currentEndpoint, service: TokenStore.readService)
                    .map(sanitizedToken(_:))
                savedTokenReadable = !(token ?? "").isEmpty
                do {
                    guard let url = URL(string: currentEndpoint) else { throw QuotaClientError.invalidEndpoint }
                    guard let token else { throw TokenStore.Failure.read }
                    let client = try QuotaClient(endpoint: url, token: token)
                    newServer = try await client.fetch()
                } catch is CancellationError { return }
                catch {
                    failure = (error as? LocalizedError)?.errorDescription
                        ?? ("Unable to reach the server." + sentenceGap + "Check the Quota Endpoint and the Read Token.")
                }
            }
            let local = await localRead
            guard !Task.isCancelled, let self, self.revision == generation else { return }
            if useServer {
                self.readTokenState = SavedTokenState.resolve(hasSavedFlag: self.hasSavedToken,
                                                              silentReadSucceeded: savedTokenReadable)
            }
            self.now = Date()
            self.lastChecked = self.now
            if let local {
                self.issues = local.issues
                self.consentNeeded = local.consentNeeded
                self.localWindows = AntigravityQuotaGroups.normalize(local.windows)
                self.hasCurrentLocalRead = true
                // One sample per window per refresh.  This is what the runaway
                // detector compares against, so it has to be recorded whether
                // or not the alert is on — turning the alert on after a week of
                // running should not mean a week of nothing to compare to.
            } else {
                self.issues = [:]
                self.consentNeeded = []
                self.localWindows = []
                self.hasCurrentLocalRead = false
                self.activeRunawayAnomalies = []
            }

            // Publish local snapshot to BotFleet on disk
            do {
                // `issues` is still the local read's own map here — the server
                // failure below is merged in afterwards and must never reach a
                // file that promises local-only readings.
                if self.skipsSnapshotIOForTesting {
                    self.handoffError = nil
                } else if useLocal {
                    try LocalQuotaSnapshot.write(windows: self.localWindows, issues: self.issues, customMarks: exportedCustomMarks(), now: self.now)
                    #if canImport(WidgetKit)
                    WidgetCenter.shared.reloadAllTimelines()
                    #endif
                }
                else { try LocalQuotaSnapshot.remove() }
                self.handoffError = nil
            } catch {
                self.handoffError = "BotFleet quota sharing is unavailable."
            }

            // Push to remote server if enabled
            if self.syncEnabled && !self.localWindows.isEmpty {
                await self.pushQuotasIfEnabled(windows: self.localWindows)
            }

            if let newServer {
                // The raw windows, deliberately: running them through
                // `platformSections` first pools every Antigravity model report
                // into four windows and keeps only one observation's origin, so
                // a second producer's readings vanished before they could be
                // grouped.  Each origin group is sectioned on its own below.
                self.serverWindows = newServer.windows.isEmpty
                    ? newServer.providerGroups.flatMap(\.windows)
                    : newServer.windows
            }
            if !useServer { self.serverWindows = [] }
            self.serverError = failure
            let localProviders = Set(self.localWindows.map(\.canonicalProviderKey))

            // A pulled window is either this Mac's own push coming back, or
            // somebody else's reading.  Every window of the second kind is
            // rendered under FLEET, grouped by its origin — the previous
            // "supplemental" filter dropped all of them on a Mac that reads
            // every provider locally, so a working pull showed nothing at all.
            let split = FleetOrigin.split(self.serverWindows)
            let ownPush = split.ownPush
            self.fleetWindowGroups = split.groups.map {
                FleetWindowGroup(id: $0.id, title: $0.title, windows: $0.windows)
            }

            // This Mac's own push fills in only a provider no local reader
            // produced — with local readers off, that is every provider.
            let adopted = ownPush.filter { !localProviders.contains($0.canonicalProviderKey) }
            let merged = self.localWindows + adopted
            var origins: [String: QuotaOrigin] = [:]
            for key in Set(merged.map(\.canonicalProviderKey)) { origins[key] = .local }
            self.originByProvider = origins
            if newServer != nil { self.lastPullTime = self.now }
            self.response = QuotaResponse(generatedAt: ISO8601DateFormatter().string(from: self.now), windows: merged)
            self.refreshRunawayUsageState(recordSamples: local != nil)
            self.alarmManager.evaluate(observations: self.resetAlarmObservationsForCurrentReadings(), now: self.now)
            self.isRefreshing = false
            self.request = nil
        }
    }

    private func refreshRunawayUsageState(recordSamples: Bool) {
        guard localEnabled, hasCurrentLocalRead else {
            activeRunawayAnomalies = []
            return
        }
        if recordSamples {
            BurnRateMonitor.record(localWindows, now: now, historyURL: burnRateHistoryURL)
        }
        guard burnRateAlertsEnabled else {
            activeRunawayAnomalies = []
            return
        }

        let masked = maskedWindowIds
        let currentKeys = Set(localWindows.compactMap { window -> String? in
            let snapshot = QuotaWindowSnapshot(window: window, now: now)
            guard snapshot.isFresh, snapshot.remainingPercent != nil,
                  !window.isSupplementaryVideoQuota, !masked.contains(window.id),
                  issues[window.canonicalProviderKey] == nil,
                  !disabledSources.contains(window.source ?? "") else { return nil }
            return Self.runawayKey(window.canonicalProviderKey, window.id)
        })
        guard !currentKeys.isEmpty else {
            activeRunawayAnomalies = []
            return
        }
        let anomalies = BurnRateMonitor.evaluate(baseline: anomalyBaselineMultiplier,
                                                  peak: anomalyPeakMultiplier,
                                                  now: now,
                                                  historyURL: burnRateHistoryURL)
            .filter { currentKeys.contains(Self.runawayKey($0.providerKey, $0.windowId)) }
        activeRunawayAnomalies = anomalies
        guard !anomalies.isEmpty else { return }

        var groups: [String: [AnomalyDetector.Anomaly]] = [:]
        var order: [String] = []
        for anomaly in anomalies {
            let key = Self.runawayKey(anomaly.providerKey, anomaly.windowId)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(anomaly)
        }
        for key in order {
            guard let group = groups[key] else { continue }
            let lastSent = lastRunawayAlertAt[key] ?? -.infinity
            guard now.timeIntervalSince1970 - lastSent >= BurnRateMonitor.alertCooldown else { continue }
            let notification = BurnRateNotification(anomalies: group, sound: alarmManager.alarmSound)
            if let runawayNotificationForTesting {
                runawayNotificationForTesting(notification)
            } else {
                alarmManager.deliverRunawayUsageAlert(notification)
            }
            lastRunawayAlertAt[key] = now.timeIntervalSince1970
        }
        lastRunawayAlertAt = lastRunawayAlertAt.filter { now.timeIntervalSince1970 - $0.value <= 30 * 86_400 }
        defaults.set(lastRunawayAlertAt, forKey: "runawayAlertLastSent")
    }

    private static func runawayKey(_ providerKey: String, _ windowId: String) -> String {
        "\(providerKey)\u{1f}\(windowId)"
    }

    private nonisolated static func readLocalSources() async -> LocalQuotaResult {
        async let primary = LocalQuotaReader().read()
        async let cursor = CursorQuotaReader().read()
        async let grokBot = GrokBotQuotaReader().read()
        // EXTRA Grok Bot source beside Cursor DashboardService; `source: "gbu"`
        // so Settings can rank/disable it without replacing the Cursor reader.
        async let gbu = GbuQuotaReader().read()
        async let antigravity = AntigravitySummaryReader().read()
        let results = await [primary, cursor, grokBot, gbu]
        let summary = await antigravity
        var windows = results.flatMap(\.windows)
        var issues = results.reduce(into: [String: String]()) { $0.merge($1.issues) { _, next in next } }
        if summary.windows.contains(where: { $0.boundedRemainingPercent != nil }) {
            windows.removeAll { $0.canonicalProviderKey == "google-antigravity" }
            windows += summary.windows
            issues["google-antigravity"] = nil
        }
        let consentNeeded = results.reduce(into: Set<String>()) { $0.formUnion($1.consentNeeded) }
        // One reader's "could not read" placeholder says nothing when another
        // reader of the same provider has a reading (Grok Bot's gbu and
        // DashboardService), and used to be drawn as an empty second bar.
        return LocalQuotaResult(windows: windows, issues: issues, consentNeeded: consentNeeded)
            .droppingSupersededPlaceholders()
    }

    private nonisolated static func readLocalResult(useLocal: Bool,
                                                    testingResult: LocalQuotaResult?) async -> LocalQuotaResult? {
        guard useLocal else { return nil }
        if let testingResult { return testingResult }
        return await readLocalSources()
    }
}

func resetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "Reset time unavailable" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "Reset passed · awaiting refresh" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
    return "Resets in \(minutes)m"
}
