import AppKit
import Combine
import QuotaCore
import SwiftUI

@main
enum CodeCapsMain {
    @MainActor
    static func main() {
        // Single-instance guard keyed on this build's own bundle identifier, so a
        // development build with a different identifier can run beside the installed app.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows])
            return
        }
        let app = NSApplication.shared
        app.disableRelaunchOnLogin()
        NSWindow.allowsAutomaticWindowTabbing = false
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    let model = MonitorModel()
    let consoleState = ConsoleState()
    private var statusItem: NSStatusItem?

    /// CodeCaps' own mark, from the owner's cropped black-on-transparent
    /// artwork.  It is a template image so macOS tints it to the menu bar's
    /// own colour, which is what makes one asset correct in light and dark.
    private static let appMarkImage: NSImage? = {
        guard let url = ResourceBundle.resolved?.url(forResource: "CodeCapsMenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
    private let popover = NSPopover()
    private var consoleWindow: NSWindow?
    private var statusMenu: NSMenu?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read before anything can open a window: the launch Sparkle performs
        // after installing an update stays in the background.
        let relaunchedForUpdate = UpdateRelaunchMarker().consume()
        AppUpdater.shared.start()
        configureMenu()
        popover.behavior = .transient
        let glance = NSHostingController(rootView:
            GlancePopover(model: model,
                          openConsole: { [weak self] page in self?.showConsole(page: page) },
                          openSettings: { [weak self] in self?.showSettings() }))
        // SwiftUI must not publish a preferred content size: NSPopover prefers
        // it over `contentSize`, which would let Glance resize itself while it
        // is open and defeat the height ceiling the scroll view depends on.
        glance.sizingOptions = []
        popover.contentViewController = glance
        model.$displayMode.removeDuplicates().sink { [weak self] mode in
            self?.apply(mode)
        }.store(in: &subscriptions)
        model.$appearance.removeDuplicates().sink { [weak self] appearance in
            let resolved: NSAppearance? = switch appearance {
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            case .system: nil
            }
            NSApp.appearance = resolved
            // The popover keeps its own appearance and does not follow NSApp,
            // so Dark has to be handed to it directly.
            self?.popover.appearance = resolved
        }.store(in: &subscriptions)
        // The owner asked (2026-10-02) for the console to dock and come to
        // the front like HogHunter's does, rather than carry a "Keep In
        // Front" pin.  Floating level was the old answer: it kept the window
        // above others but left the app an accessory with no Dock icon, so
        // the owner could not switch to CodeCaps at all.  Dock + activate is
        // what they actually wanted..store(in: &subscriptions)
        consoleState.$page.removeDuplicates().sink { [weak self] page in
            self?.consoleWindow?.title = page.isSettings ? "CodeCaps Settings" : "CodeCaps"
        }.store(in: &subscriptions)
        model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        if model.displayMode != .menuBar && !relaunchedForUpdate { showConsole(page: nil) }
        model.start()
        startInfisicalSync()
        NotificationCenter.default.addObserver(
            forName: .infisicalIdentityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.infisicalIdentityDidChange() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: - Infisical source of truth

    private var infisicalRefreshTimer: Timer?

    /// Loads the app-level settings from Infisical (see INFISICAL.md) when the
    /// owner has provisioned an identity under Settings → Infisical Sync.
    /// The load runs off the main thread and never blocks launch: until it
    /// succeeds the app simply keeps its local values.
    private func startInfisicalSync() {
        Task.detached(priority: .utility) { [weak self] in
            guard let identity = InfisicalIdentityStore.load() else { return }
            let settings = InfisicalSettings.shared
            settings.configure(InfisicalSettings.Configuration(
                environment: InfisicalSettings.defaultEnvironment(),
                clientId: identity.clientId,
                clientSecret: identity.clientSecret))
            await settings.refresh()
            await MainActor.run { [weak self] in
                self?.model.adoptInfisicalEndpointsIfUnset()
                self?.scheduleInfisicalRefresh()
            }
        }
    }

    /// One-shot timer, rescheduled after every fire so a cadence change made
    /// in Infisical itself takes effect on the next cycle.  A failed refresh
    /// keeps serving the last-known-good cache — settings staleness is safer
    /// than an outage.
    private func scheduleInfisicalRefresh() {
        infisicalRefreshTimer?.invalidate()
        infisicalRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: InfisicalSettings.shared.refreshInterval,
            repeats: false
        ) { [weak self] _ in
            Task {
                await InfisicalSettings.shared.refresh()
                await MainActor.run { [weak self] in
                    self?.model.adoptInfisicalEndpointsIfUnset()
                    self?.scheduleInfisicalRefresh()
                }
            }
        }
    }

    /// (Re)starts the whole sync cycle — used at launch and whenever the
    /// identity changes under Settings → Infisical Sync, so no relaunch is
    /// needed.  A forgotten identity stops the timer and leaves settings local.
    private func infisicalIdentityDidChange() {
        infisicalRefreshTimer?.invalidate()
        infisicalRefreshTimer = nil
        startInfisicalSync()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard InfisicalSettings.shared.isProvisioned else { return }
        Task {
            await InfisicalSettings.shared.refresh()
            await MainActor.run { [weak self] in
                self?.model.adoptInfisicalEndpointsIfUnset()
                self?.scheduleInfisicalRefresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConsole(page: nil)
        return true
    }

    private func apply(_ mode: DisplayMode) {
        // AppKit owns only activation and status-item lifetime; content remains SwiftUI.
        if mode != .dock && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = self
            item.button?.action = #selector(statusItemClicked)
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
        }
        NSApp.setActivationPolicy(mode == .menuBar ? .accessory : .regular)
        if mode == .menuBar { consoleWindow?.orderOut(nil) }
        if mode == .dock {
            popover.performClose(nil)
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            showConsole(page: nil)
        }
        updateStatus()
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let style = model.menuBarStyle
        let title = model.menuBarTitle
        let detail = model.menuBarDetail
        let target = model.menuBarTargetSnapshot

        // Configure image presence
        if style == .percentOnly {
            button.image = nil
            button.imagePosition = .noImage
        } else {
            let providerKey = target?.window.canonicalProviderKey ?? "auto"
            // The status item's mark can be forced independent of the popover's
            // per-provider Logo Style; `matchProvider` is today's behaviour.
            let markStyle = target != nil
                ? model.menuBarMarkStyle.resolved(model.markStyle(for: providerKey))
                : .template
            var iconImage: NSImage?
            if let target {
                // The row's key, so an Antigravity pool shows its own mark.
                let markKey = model.displayRow(for: target.window)?.id ?? providerKey
                let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                iconImage = PlatformLogoImage.menuBarImage(providerKey: markKey, style: markStyle, isDarkMode: isDark)
            }
            if iconImage == nil {
                // With no single provider pinned to the menu bar, the item
                // wears CodeCaps' own mark rather than a generic gauge symbol.
                // `template` is what lets one asset read correctly on both a
                // light and a dark menu bar — the owner's cropped artwork is
                // black-on-transparent for exactly that reason, and macOS
                // recolours a template image to match the bar.
                iconImage = Self.appMarkImage ?? {
                    let symbolName = target != nil
                        ? PlatformLogoImage.fallbackSymbolName(for: providerKey)
                        : "gauge.with.dots.needle.50percent"
                    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "CodeCaps")
                    image?.isTemplate = (markStyle == .template)
                    return image
                }()
            }
            button.image = iconImage
            button.imagePosition = style == .symbolOnly ? .imageOnly : .imageLeading
        }

        // Configure title
        if style == .symbolOnly {
            button.title = ""
        } else {
            button.title = " \(title)"
        }

        button.toolTip = "CodeCaps · \(detail)"
        button.setAccessibilityLabel("CodeCaps, \(detail)")
    }

    // MARK: - Status item

    /// Left-click toggles Glance; right-click and control-click open the command
    /// menu.  The menu is attached only for the length of that click, because a
    /// permanently assigned `statusItem.menu` would swallow the left-click path.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick { showStatusMenu() } else { togglePopover() }
    }

    private func showStatusMenu() {
        guard let item = statusItem else { return }
        popover.performClose(nil)
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = self
            menu.addItem(entry)
        }
        add("Refresh Quotas", #selector(refresh), "r")
        add("Open CodeCaps", #selector(showMonitor), "1")
        add("Settings…", #selector(showSettings), ",")
        menu.addItem(.separator())
        add("About CodeCaps", #selector(showAbout))
        add("Check For Updates…", #selector(checkForUpdates))
        add("Quit CodeCaps", #selector(quit), "q")
        statusMenu = menu
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusItem?.menu = nil
        statusMenu = nil
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { showConsole(page: nil); return }
        if popover.isShown { popover.performClose(nil) }
        else {
            // Sized immediately before every show, from the expected provider
            // count, so the popover cannot resize while it is open.
            // The ceiling comes from the screen the status item is on, not
            // from the key window's screen, or a short second display clamps to
            // a tall main display and pushes the footer off-screen.
            let screen = button.window?.screen ?? NSScreen.main
            popover.contentSize = NSSize(width: Metrics.glanceWidth,
                                         height: QuotaGlanceMetrics.popoverHeight(for: model, on: screen))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Console

    /// The single window.  `page` nil means "leave the selection alone", which
    /// is what a reopen or a Dock-mode switch wants.
    func showConsole(page: ConsolePage?) {
        popover.performClose(nil)
        if let page { consoleState.page = page }
        if consoleWindow == nil {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.consoleDefault),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.contentMinSize = Metrics.consoleMin
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            // A hosting CONTROLLER, not a bare hosting view: the controller
            // respects the titlebar's safe area, so scrolled content does not
            // smear through the translucent title bar.
            let console = NSHostingController(rootView: ConsoleView(model: model, state: consoleState))
            // A non-zero preferred content size on a window's content view
            // controller resizes the window to it, which would override both the
            // default content rect and any frame restored below.
            console.sizingOptions = []
            window.contentViewController = console
            // Restore first, centre only when there is nothing to restore:
            // `center()` after the autosave name discarded the saved origin on
            // every launch.
            if !window.setFrameUsingName("CodeCapsConsoleWindow") { window.center() }
            window.setFrameAutosaveName("CodeCapsConsoleWindow")
            consoleWindow = window
        }
        consoleWindow?.title = consoleState.page.isSettings ? "CodeCaps Settings" : "CodeCaps"
        consoleWindow?.makeKeyAndOrderFront(nil)
        // Re-opening from the menu bar should raise the window that is already
        // open, not a second copy of it, and it has to come forward even if it
        // is behind whatever the owner was using.
        consoleWindow?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Kept so existing selectors and call sites keep working.
    @objc func showMonitor() { showConsole(page: .allPlatforms) }

    /// `⌘,` always lands on a Settings page, the last one used.
    @objc func showSettings() { showConsole(page: consoleState.lastSettingsPage) }

    @objc private func showAbout() { showConsole(page: .settingsAbout) }
    @objc private func checkForUpdates() { AppUpdater.shared.checkForUpdates() }

    /// "Check For Updates…" is greyed out while Sparkle is busy, and on a build
    /// that cannot update itself (Settings ▸ About says why).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdates) { return AppUpdater.shared.canCheckForUpdates }
        return true
    }
    @objc private func refresh() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }
    /// `.accessory` while nothing but the status item is up, `.regular` as
    /// soon as the console is on screen — which is what puts a Dock icon in
    /// and takes it out again.  HogHunter's `AppActivationManager` does the
    /// same thing; the difference here is that a menu bar app has one window
    /// rather than a window registry.
    ///
    /// The display mode wins over the window.  A menu-bar-only app must never
    /// grow a Dock icon, even with Settings open, or the setting the owner
    /// chose quietly stops meaning anything.
    private func applyActivationPolicy() {
        let docked = model.displayMode != .menuBar
        let hasWindow = consoleWindow?.isVisible ?? false
        NSApp.setActivationPolicy(docked && hasWindow ? .regular : .accessory)
    }

    /// Closing the console is what takes the Dock icon away.  Without this the
    /// app stayed `.regular` with no window showing, which is a Dock icon the
    /// owner cannot account for — clicking it brought up nothing.
    ///
    /// Always `.accessory`, in every display mode: the console is no longer
    /// showing, and an owner who chose Dock mode still has their icon back the
    /// moment `applyActivationPolicy` runs on the next open.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === consoleWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func configureMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        func add(_ title: String, _ action: Selector, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            appMenu.addItem(item)
        }
        add("Open CodeCaps", #selector(showMonitor), "1")
        add("Glance", #selector(togglePopover), "2")
        add("Settings…", #selector(showSettings), ",")
        add("Refresh Quotas", #selector(refresh), "r")
        appMenu.addItem(.separator())
        add("About CodeCaps", #selector(showAbout))
        add("Check For Updates…", #selector(checkForUpdates))
        add("Quit CodeCaps", #selector(quit), "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.title = "Edit"
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        // Window ▸ Close gives the Console `⌘W` through the responder chain.
        // `applicationShouldTerminateAfterLastWindowClosed` is false, so closing
        // the window leaves the app running in the menu bar.
        let windowItem = NSMenuItem()
        windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }
}
