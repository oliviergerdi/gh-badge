import AppKit
import Combine
import GHBadgeCore
import SwiftUI

/// Owns the long-lived objects.
///
/// A main-actor singleton rather than `@StateObject` in the `App` struct: both
/// stores are `@MainActor`-isolated, and `App.init` / property initialisers are
/// not, so constructing them there is an isolation violation. `App.body` *is*
/// main-actor isolated, so touching `shared` from there is safe and the lazy
/// `static let` initialises exactly once.
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let settings: SettingsStore
    let store: PRStore
    let loginItems = LoginItemController()

    /// Created lazily: its initializer captures `self` (the settings opener lives
    /// on `self`), which is only legal after `init` has finished.
    lazy var statusItem = StatusItemController(
        store: store,
        settings: settings,
        onOpenSettings: { [weak self] in self?.openSettingsWindow() }
    )

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let settings = SettingsStore()
        self.settings = settings
        self.store = PRStore(client: GHClient(), settings: settings)

        // Reflect reality: the user may have removed the login item in System
        // Settings since last launch.
        settings.launchAtLogin = loginItems.reconcile(storedPreference: settings.launchAtLogin)

        settings.$launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in
                guard let self else { return }
                if !self.loginItems.apply(enabled: enabled) {
                    // Registration was refused; do not leave the toggle lying.
                    // Deferred to the next turn on purpose: @Published fires in
                    // willSet, so assigning here would be overwritten by the
                    // store that triggered this sink.
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.settings.launchAtLogin = self.loginItems.isRegistered
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Owns the Settings window across open/close cycles so the SwiftUI view
    /// and its `@ObservedObject`s are not rebuilt, and so closing does not
    /// deallocate the window (which would break re-opening).
    private var settingsWindowController: NSWindowController?

    func openSettingsWindow() {
        if settingsWindowController == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(settings: settings, loginItems: loginItems)
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "gh-badge Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            // Match SettingsView's fixed frame; NSHostingController does not
            // reliably size the window to the SwiftUI content on its own.
            window.setContentSize(NSSize(width: 480, height: 560))
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }

        // LSUIElement apps are not active, so the window would otherwise open
        // behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindowController?.showWindow(nil)
    }
}

/// Explicitly `@MainActor` rather than relying on `MainActor.assumeIsolated`,
/// which carries a macOS 14 availability annotation and would break the
/// macOS 13 deployment target.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch the status item so the menu bar icon, popover, and context menu
        // are created (it is `lazy`).
        _ = AppEnvironment.shared.statusItem
        AppEnvironment.shared.store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppEnvironment.shared.store.stop()
    }
}

@main
struct GHBadgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The status item, its popover, and its context menu are driven by
    // `AppEnvironment` through `StatusItemController`; SwiftUI only provides
    // the process lifecycle here. A `Settings` scene keeps the `Scene`-returning
    // `body` satisfied without opening a window on launch (an LSUIElement app
    // never surfaces it).
    var body: some Scene {
        Settings { EmptyView() }
    }
}
