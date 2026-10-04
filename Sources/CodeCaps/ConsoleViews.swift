import AppKit
import QuotaCore
import SwiftUI

/// One selection type for the sidebar, the detail pane and every deep link from
/// Glance, the app menu and the status menu.
enum ConsolePage: Hashable {
    case allPlatforms
    case platform(String)
    case settingsMenuBar
    case settingsPlatforms
    case settingsLogoStyle
    case settingsSourcesFleet
    case settingsNotifications
    case settingsAppearance
    case settingsInfisical
    case settingsAbout

    var isSettings: Bool {
        switch self {
        case .allPlatforms, .platform: return false
        default: return true
        }
    }

    var storageKey: String {
        switch self {
        case .allPlatforms: return "allPlatforms"
        case .platform(let providerKey): return "platform:" + providerKey
        case .settingsMenuBar: return "settingsMenuBar"
        case .settingsPlatforms: return "settingsPlatforms"
        case .settingsLogoStyle: return "settingsLogoStyle"
        case .settingsSourcesFleet: return "settingsSourcesFleet"
        case .settingsNotifications: return "settingsNotifications"
        case .settingsAppearance: return "settingsAppearance"
        case .settingsInfisical: return "settingsInfisical"
        case .settingsAbout: return "settingsAbout"
        }
    }

    static func fromStorageKey(_ value: String) -> ConsolePage? {
        switch value {
        case "allPlatforms": return .allPlatforms
        case "settingsMenuBar": return .settingsMenuBar
        case "settingsPlatforms": return .settingsPlatforms
        case "settingsLogoStyle": return .settingsLogoStyle
        case "settingsSourcesFleet": return .settingsSourcesFleet
        case "settingsNotifications": return .settingsNotifications
        case "settingsAppearance": return .settingsAppearance
        case "settingsInfisical": return .settingsInfisical
        case "settingsAbout": return .settingsAbout
        default:
            guard value.hasPrefix("platform:") else { return nil }
            return .platform(String(value.dropFirst(9)))
        }
    }

    /// Sidebar and toolbar label.  A platform page is titled by the model.
    var settingsTitle: String {
        switch self {
        case .settingsMenuBar: return "Menu Bar"
        case .settingsPlatforms: return "Platforms"
        case .settingsLogoStyle: return "Logo Style"
        case .settingsSourcesFleet: return "Sources & Fleet"
        case .settingsNotifications: return "Alerts & Alarms"
        case .settingsAppearance: return "Appearance"
        case .settingsInfisical: return "Infisical Sync"
        case .settingsAbout: return "About"
        default: return "CodeCaps"
        }
    }

    var symbol: String {
        switch self {
        case .settingsMenuBar: return "menubar.rectangle"
        case .settingsPlatforms: return "square.grid.2x2"
        case .settingsLogoStyle: return "photo.on.rectangle.angled"
        case .settingsSourcesFleet: return "arrow.up.arrow.down.circle"
        case .settingsNotifications: return "bell.badge"
        case .settingsAppearance: return "circle.lefthalf.filled"
        case .settingsInfisical: return "key.fill"
        case .settingsAbout: return "info.circle"
        default: return "square.grid.2x2"
        }
    }

    static let settingsPages: [ConsolePage] = [
        .settingsMenuBar, .settingsPlatforms, .settingsLogoStyle, .settingsSourcesFleet, .settingsNotifications, .settingsAppearance, .settingsInfisical, .settingsAbout,
    ]
}

/// Selection state shared between AppKit (which owns the window and its title)
/// and SwiftUI (which owns the sidebar and detail pane).
@MainActor
final class ConsoleState: ObservableObject {
    @Published var page: ConsolePage = .allPlatforms {
        didSet {
            guard page != oldValue else { return }
            if page.isSettings {
                defaults.set(page.storageKey, forKey: "consoleLastSettingsPage")
            }
            defaults.set(page.storageKey, forKey: "consoleLastPage")
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A Settings page is a destination, never a place to resume.
        let stored = defaults.string(forKey: "consoleLastPage").flatMap(ConsolePage.fromStorageKey)
        page = (stored?.isSettings == false ? stored : nil) ?? .allPlatforms
    }

    var lastSettingsPage: ConsolePage {
        defaults.string(forKey: "consoleLastSettingsPage")
            .flatMap(ConsolePage.fromStorageKey)
            .flatMap { $0.isSettings ? $0 : nil }
            ?? .settingsMenuBar
    }
}

/// The one window.  Deliberately a plain `HStack` with a custom splitter
/// rather than `NavigationSplitView`: the sidebar is still a two-section flat
/// list that needs no system collapse toggle, but the column is now
/// user-resizable from `Metrics.sidebarWidthMin` to
/// `Metrics.sidebarWidthMax`, defaulting to `Metrics.sidebarWidthDefault`.
/// The owner drag handle is in `ConsoleSidebarSplitter`; the chosen width
/// persists in `consoleSidebarWidth` so a wider window they prefer for a
/// 32" display stays wide across launches.
struct ConsoleView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    @State private var query = ""
    /// Owner-resizable column width, clamped to the design bounds, default
    /// loaded from `UserDefaults.standard` so a wider sidebar chosen on a
    /// big display stays wide; a fresh install lands on
    /// `Metrics.sidebarWidthDefault`.
    @State private var sidebarWidth: CGFloat
    @FocusState private var searchFocused: Bool

    init(model: MonitorModel, state: ConsoleState) {
        self.model = model
        self.state = state
        let raw = UserDefaults.standard.double(forKey: "consoleSidebarWidth")
        let initial = raw == 0 ? Metrics.sidebarWidthDefault : CGFloat(raw)
        _sidebarWidth = State(initialValue: max(Metrics.sidebarWidthMin,
                                                min(Metrics.sidebarWidthMax, initial)))
    }

    var body: some View {
        HStack(spacing: 0) {
            ConsoleSidebar(model: model, state: state)
                .frame(width: sidebarWidth)
            // The divider visible on screen *is* the splitter's 1pt rectangle;
            // the wider 8pt invisible band is the grab target for the cursor.
            // No standalone `Divider()` so the visible line lives in exactly
            // one place.
            ConsoleSidebarSplitter(width: $sidebarWidth)
            detail
        }
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        .background(Theme.background)
        .background {
            // The keyboard equivalents the spec asks for.  Hidden buttons
            // rather than menu items, because the search field belongs to this
            // view and nothing in AppKit can reach its focus state.
            VStack {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(state.page.isSettings)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if model.isRefreshing {
                Rectangle().fill(Theme.accent).frame(height: 2)
                    .accessibilityHidden(true)
            }
            ScrollView {
                switch state.page {
                case .allPlatforms:
                    AllPlatformsPage(model: model, state: state, query: query)
                        .padding(Metrics.pagePadding)
                case .platform(let key):
                    PlatformDetailPage(model: model, state: state, providerKey: key)
                        .padding(Metrics.pagePadding)
                case .settingsMenuBar:
                    SettingsMenuBarPage(model: model)
                case .settingsPlatforms:
                    SettingsPlatformsPage(model: model)
                case .settingsLogoStyle:
                    SettingsLogoStylePage(model: model)
                case .settingsSourcesFleet:
                    SettingsSourcesFleetPage(model: model)
                case .settingsNotifications:
                    SettingsNotificationsPage(model: model)
                case .settingsAppearance:
                    SettingsAppearancePage(model: model)
                case .settingsInfisical:
                    SettingsInfisicalPage(model: model)
                case .settingsAbout:
                    SettingsAboutPage(model: model, state: state)
                }
            }
            .background(Theme.background)
        }
    }

    private var pageTitle: String {
        switch state.page {
        case .allPlatforms: return "All Platforms"
        case .platform(let key):
            return model.displaySections.first { $0.id == key }?.title ?? key
        default: return state.page.settingsTitle
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(pageTitle)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .lineLimit(1)
                // F-06: 200pt minimum title width with priority keeps
                // platform headings like "Antigravity · Gemini · Third-Party" legible.
                .frame(minWidth: 200, alignment: .leading)
                .layoutPriority(1)
                .truncationMode(.tail)

            if !state.page.isSettings {
                // F-06: Position search field immediately adjacent to the page title.
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Find a Platform", text: $query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onExitCommand { query = "" }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                .frame(width: 180)
                .help("Find a Platform")
                .accessibilityLabel("Find a Platform")
            }

            Spacer(minLength: 8)

            // F-06: Compact / Detailed segmented control replaced with View Options menu.
            if state.page == .allPlatforms {
                Menu {
                    Picker("Layout", selection: $model.viewLayout) {
                        ForEach(QuotaViewLayout.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
                .help("View Options")
                .accessibilityLabel("View Options")
            }

            Button { model.refresh() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
            }
            .disabled(model.isRefreshing)
            .help("Refresh Quotas")
            .accessibilityLabel("Refresh Quotas")

            // The owner asked (2026-10-02) for the pin control gone in favour
            // of the app docking itself while this window is open, which is
            // what HogHunter does and what `AppActivationManager` implements
            // now.  A floating "keep in front" is a worse answer to the same
            // need, and it was the one control here that explained nothing.
            Text(CodeCapsVersion.display)
                .font(.system(size: 10))
                .foregroundStyle(Theme.ink.opacity(0.35))
                .help("CodeCaps Version")
                .accessibilityLabel(CodeCapsVersion.display)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .frame(height: Metrics.toolbarHeight)
        .background(Theme.surface)
    }
}

/// Thin grab strip between the sidebar and the detail pane.  Renders a
/// 1pt hairline divider inside an 8pt invisible hit zone; flipping the
/// cursor to `resizeLeftRight` on hover, and dragging the column to a new
/// width on press-and-drag.  The chosen width is persisted to
/// `consoleSidebarWidth` only when the drag releases, so a 200-frame-per-
/// second drag does not flood `UserDefaults`.
///
/// An AppKit `NSCursor.push()/pop()` is the right tool here even though
/// the rest of `ConsoleView` is pure SwiftUI; the cursor change is a
/// window-level concern that SwiftUI's `.onHover` cannot deliver on its
/// own.
private struct ConsoleSidebarSplitter: View {
    @Binding var width: CGFloat
    @State private var isHovering = false
    @State private var dragStart: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
            Color.clear
                .frame(width: 8)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            // Capture the column width on first movement, so
                            // each subsequent translation is relative to the
                            // gesture start rather than the last frame, and
                            // an already-resized column does not drift while
                            // the user drags.
                            if dragStart == nil { dragStart = width }
                            let newWidth = (dragStart ?? width) + value.translation.width
                            width = max(Metrics.sidebarWidthMin,
                                        min(Metrics.sidebarWidthMax, newWidth))
                        }
                        .onEnded { _ in
                            dragStart = nil
                            UserDefaults.standard.set(Double(width), forKey: "consoleSidebarWidth")
                        }
                )
        }
        .frame(width: 8)
        .background(isHovering ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

// MARK: - Sidebar

struct ConsoleSidebar: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    @FocusState private var focusedPage: ConsolePage?

    private var allPages: [ConsolePage] {
        var pages: [ConsolePage] = [.allPlatforms]
        pages.append(contentsOf: model.displaySections.map { .platform($0.id) })
        pages.append(contentsOf: ConsolePage.settingsPages)
        return pages
    }

    private func moveSelection(by delta: Int) {
        let pages = allPages
        guard !pages.isEmpty else { return }
        let currentIndex = pages.firstIndex(of: state.page) ?? 0
        let nextIndex = max(0, min(pages.count - 1, currentIndex + delta))
        let target = pages[nextIndex]
        state.page = target
        focusedPage = target
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Rows are buttons rather than `List(selection:)` tags, for two
            // reasons: a List tagged with an enum carrying an associated value
            // does not commit a click on macOS 14, and a List's own selection
            // draws in the system accent — system blue, next to this app's teal.
            // Drawing the highlight here settles both.
            List {
                Section {
                    sidebarRow(page: .allPlatforms) {
                        Label("All Platforms", systemImage: "square.grid.2x2")
                            .font(.system(size: 13, weight: .medium))
                    }
                    ForEach(model.displaySections) { row in
                        sidebarRow(page: .platform(row.id)) { quotaRow(row) }
                    }
                } header: {
                    Eyebrow("QUOTAS")
                }
                Section {
                    ForEach(ConsolePage.settingsPages, id: \.self) { page in
                        sidebarRow(page: page) {
                            Label(page.settingsTitle, systemImage: page.symbol)
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                } header: {
                    Eyebrow("SETTINGS")
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focusable()
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(by: -1)
                case .down: moveSelection(by: 1)
                default: break
                }
            }
            .onAppear {
                focusedPage = state.page
            }
            .onChange(of: state.page) { _, newPage in
                focusedPage = newPage
            }

            Divider()
            footer
        }
        .background(Theme.surface)
    }

    /// One selectable sidebar row, highlighted with the app's own accent.
    private func sidebarRow<Content: View>(page: ConsolePage, @ViewBuilder content: () -> Content) -> some View {
        let selected = state.page == page
        let isFocused = focusedPage == page
        return Button {
            state.page = page
            focusedPage = page
        } label: {
            content()
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? Theme.selection : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Theme.accent.opacity(isFocused ? 0.65 : 0.35) : .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .focused($focusedPage, equals: page)
        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Quotas rows carry a trailing value; Settings rows do not.  Two different
    /// row views is what stops `.listStyle(.sidebar)` aligning them identically.
    private func quotaRow(_ row: DisplaySection) -> some View {
        HStack(spacing: 6) {
            PlatformLogo(providerKey: row.id, size: 16,
                         style: model.markStyle(for: row.id))
            // A pool name is half again as long as a platform name, and
            // "Antigravity · Cl…" hides the very thing the row adds, so the
            // pool takes a second line in this 200pt column.
            VStack(alignment: .leading, spacing: 0) {
                Text(row.platformTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let poolTitle = row.poolTitle {
                    Text(poolTitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 2)
            if !model.alarmsAll && model.isProviderAlarmSelected(row.id) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Reset alarm on")
            }
            if model.issues[row.providerKey] != nil {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .accessibilityLabel("Quota unavailable")
            } else if let remaining = row.remainingPercent {
                // A fixed column keeps the percentage on screen when the label
                // is long enough to want every point of the row.  "100%" is
                // about 31pt at 11pt, so 30pt truncated it to "100…".
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 36, alignment: .trailing)
            } else if model.lastChecked == nil {
                Capsule().fill(Theme.track).frame(width: 28, height: 10)
                    .accessibilityHidden(true)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            // This used to be a second copy of the control, and it was the
            // confusing one: grey, status-like, and sitting in a footer where
            // nothing else in the app is a switch.  The real control is the
            // first thing on Settings -> Sources & Fleet, under THIS MAC.
            // One control, one place.
            Text("Reading from this Mac")
                .font(.system(size: 11))
                .foregroundStyle(model.localEnabled ? Theme.ink.opacity(0.7) : .secondary)
                .accessibilityLabel("Reading from this Mac")
                .accessibilityValue(model.localEnabled ? "On" : "Off")
                .help("Turn this off in Settings, under Sources & Fleet.")
            if let handoffError = model.handoffError {
                Text(handoffError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}

// MARK: - All Platforms

struct AllPlatformsPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    let query: String

    private var matching: [DisplaySection] {
        model.displaySections.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
    }
    private var localSections: [DisplaySection] {
        matching.filter { model.originByProvider[$0.providerKey] != .fleet }
    }
    /// Fleet rows, filtered by the same search box, grouped by machine.
    private var fleetGroups: [FleetGroup] {
        model.fleetGroups.map { group in
            FleetGroup(id: group.id,
                       title: group.title,
                       windowCount: group.windowCount,
                       rows: group.rows.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) })
        }
        .filter { !$0.rows.isEmpty }
    }
    private var compact: Bool { model.viewLayout == .summary }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: compact ? 240 : 290), alignment: .top)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            tiles
            if let error = model.serverError { errorBanner(error) }

            if !model.localEnabled && !model.serverEnabled {
                emptyState
            } else {
                HStack {
                    Text("This Mac").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(localSections) { row in
                        card(row, origin: .local)
                    }
                }
                if model.serverEnabled { fleetGroup }
            }

            Text("Quota windows are independent." + sentenceGap
                 + "Antigravity meters two model pools separately, so each pool has its own row.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .top)], spacing: 12) {
            SummaryTile(label: "Reporting",
                        value: model.lastChecked == nil ? "—" : "\(model.reportingCount) of \(model.sections.count)",
                        symbol: "antenna.radiowaves.left.and.right",
                        detail: "reporting")
            SummaryTile(label: "Near Cap",
                        value: model.lastChecked == nil ? "—" : "\(model.nearCapCount)",
                        symbol: "gauge.with.dots.needle.100percent",
                        detail: "at 20% or less")
            SummaryTile(label: "Next Reset",
                        // The whole countdown: the two-unit form is Glance's, and this tile
                        // has no tooltip to carry the minutes.
                        value: model.nextReset.map { glanceResetFullCountdown($0, now: model.now) } ?? "—",
                        symbol: "clock",
                        detail: nextResetDetail)
            SummaryTile(label: "Fleet",
                        value: model.serverEnabled ? "\(model.fleetWindowCount) windows" : "Off",
                        symbol: "arrow.up.arrow.down.circle",
                        detail: model.serverEnabled
                            ? (model.lastPullTime.map { "pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "never pulled")
                            : "set up fleet pull")
        }
    }

    /// Which platform and window the next reset belongs to, so the tile says
    /// what is about to reset rather than only when.
    private var nextResetDetail: String {
        guard let next = model.nextReset else { return "no reset reported" }
        for row in model.displaySections {
            for snapshot in row.section.windows where snapshot.resetAt == next && !row.isMasked(snapshot) {
                // An Antigravity row names its pool, so the tile says which
                // pool is about to reset rather than only "Antigravity".
                return "\(row.title), \(windowCadenceName(snapshot.window))"
            }
        }
        return next.formatted(date: .omitted, time: .shortened)
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Fleet refresh failed." + sentenceGap + "Showing the last report.")
                    .font(.system(size: 12, weight: .medium))
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { state.page = .settingsSourcesFleet }
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.warning.opacity(0.35)))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Connect a Quota Source", systemImage: "link")
        } description: {
            Text("CodeCaps reads quota from the agent CLIs already signed in on this Mac."
                 + sentenceGap + "You can also pull quota from your other machines.")
        } actions: {
            HStack(spacing: 10) {
                Button("Turn On Local Readers") {
                    model.setLocalEnabled(true)
                    state.page = .settingsSourcesFleet
                }
                .buttonStyle(.borderedProminent)
                Button("Set Up Fleet Pull") { state.page = .settingsSourcesFleet }
            }
        }
    }

    @ViewBuilder
    private var fleetGroup: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Theme.fleet).frame(width: 2)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(fleetTitle).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.lastPullTime.map { "Pulled \($0.formatted(date: .omitted, time: .shortened))" } ?? "Never pulled")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if fleetGroups.isEmpty {
                    Text("No other machines have reported yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(fleetGroups) { group in
                        // A group header per machine: the pull carries an
                        // origin per window and nothing finer.
                        HStack {
                            Text(group.title).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("\(group.windowCount) window\(group.windowCount == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(group.rows) { row in
                                card(row, origin: .fleet)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fleetTitle: String { "Fleet" }

    private func card(_ row: DisplaySection, origin: QuotaOrigin) -> some View {
        PlatformCard(row: row,
                     now: model.now,
                     issue: origin == .fleet ? nil : model.issues[row.providerKey],
                     compact: compact,
                     wide: false,
                     origin: origin,
                     customInfo: model.platformCustomInfo[row.providerKey],
                     markStyle: model.markStyle(for: row.id),
                     isAlarmArmed: model.isAlarmEnabled(for: row.id),
                     onToggleAlarm: model.alarmsAll ? nil : { model.toggleAlarm(for: row.id) },
                     onOpenSettings: model.consentNeeded.contains(row.providerKey)
                        ? { state.page = .settingsSourcesFleet } : nil)
    }
}

// MARK: - Single platform

struct PlatformDetailPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    let providerKey: String

    @State private var customSubtitle = ""
    @State private var planName = ""
    @State private var costUsd = ""
    @State private var renewalDate = ""
    @State private var showCostAndRenewal = false

    /// The page's own row.  A pool-qualified key such as
    /// `google-antigravity:gemini` selects one Antigravity pool.
    private var row: DisplaySection? {
        model.displaySections.first { $0.id == providerKey }
            ?? model.displaySections.first { $0.providerKey == providerKey }
    }
    /// Custom display fields are per platform, so both Antigravity pools share
    /// the platform's own key rather than the pool-qualified one.
    private var customInfoKey: String { customInfoKey(for: providerKey) }

    private func customInfoKey(for key: String) -> String {
        let match = model.displaySections.first { $0.id == key }
            ?? model.displaySections.first { $0.providerKey == key }
        return match?.providerKey ?? key
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let row {
                PlatformCard(row: row,
                             now: model.now,
                             issue: model.issues[row.providerKey],
                             compact: false,
                             wide: true,
                             origin: model.originByProvider[row.providerKey] ?? .local,
                             customInfo: model.platformCustomInfo[row.providerKey],
                             markStyle: model.markStyle(for: row.id),
                             isAlarmArmed: model.isAlarmEnabled(for: row.id),
                             onToggleAlarm: model.alarmsAll ? nil : { model.toggleAlarm(for: row.id) },
                             onOpenSettings: model.consentNeeded.contains(row.providerKey)
                                ? { state.page = .settingsSourcesFleet } : nil)
            } else {
                Text("Quota unavailable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            displaySection
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
        // Switching platforms in the sidebar reuses this view instance, so
        // `onDisappear` never fires.  The edits in flight belong to the key
        // that is going away, which is why the flush names it explicitly.
        .onChange(of: providerKey) { oldKey, _ in
            save(for: customInfoKey(for: oldKey))
            load()
        }
        // Typed text is never held only in `@State`: closing the window or
        // switching pages must not be able to lose it.
        .onChange(of: customSubtitle) { _, _ in save() }
        .onChange(of: planName) { _, _ in save() }
        .onChange(of: costUsd) { _, _ in save() }
        .onChange(of: renewalDate) { _, _ in save() }
    }

    /// Editing a platform's presentation happens on that platform's own page,
    /// which is why Settings ▸ Platforms needs no row selection and no flush.
    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow("DISPLAY")
            VStack(alignment: .leading, spacing: 12) {
                field("Custom Subtitle", "e.g. Pro tier, Custom text, etc.", $customSubtitle,
                      caption: "Replaces the default subtitle.")
                Divider()
                Toggle("Display Plan, Cost and Renewal", isOn: $showCostAndRenewal)
                    .onChange(of: showCostAndRenewal) { _, _ in save() }
                field("Plan Name", "e.g. Max 20x, Pro", $planName, disabled: !showCostAndRenewal)
                field("Cost", "e.g. $20/mo", $costUsd, disabled: !showCostAndRenewal)
                field("Renewal Date", "e.g. Oct 12 or Monthly", renewalField,
                      caption: renewalDate.isEmpty && !suggestedRenewal.isEmpty
                        ? "Filled from this platform's billing cycle. Type to override."
                        : nil,
                      disabled: !showCostAndRenewal)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    /// Empty stored text means "keep tracking the billing cycle".  The field
    /// still shows that date, and typing anything else pins an override.
    private var suggestedRenewal: String {
        guard let row else { return "" }
        return BillingRenewal.text(for: row.section.windows.map(\.window)) ?? ""
    }

    private var renewalField: Binding<String> {
        Binding(
            get: { renewalDate.isEmpty ? suggestedRenewal : renewalDate },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed == suggestedRenewal {
                    renewalDate = ""
                } else {
                    renewalDate = newValue
                }
            }
        )
    }

    private func field(_ label: String, _ placeholder: String, _ binding: Binding<String>,
                       caption: String? = nil, disabled: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                TextField(placeholder, text: binding)
                    .textFieldStyle(.roundedBorder)
                    .disabled(disabled)
                    .onSubmit(save)
                if let caption {
                    Text(caption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func load() {
        let existing = model.platformCustomInfo[customInfoKey] ?? PlatformCustomInfo()
        customSubtitle = existing.customSubtitle
        planName = existing.planName
        costUsd = existing.costUsd
        renewalDate = existing.renewalDateText
        showCostAndRenewal = existing.showCostAndRenewal
    }

    private func save() { save(for: customInfoKey) }

    private func save(for key: String) {
        model.setCustomInfo(for: key,
                            info: PlatformCustomInfo(customSubtitle: customSubtitle,
                                                     planName: planName,
                                                     costUsd: costUsd,
                                                     renewalDateText: renewalDate,
                                                     showCostAndRenewal: showCostAndRenewal))
    }
}

/// Version string, read once from the bundle the build script writes.  `var`
/// only so the screenshot test, which runs inside Xcode's test host and would
/// otherwise print Xcode's own version, can put a release's string in the footer.
enum CodeCapsVersion {
    static var display: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }()
}
