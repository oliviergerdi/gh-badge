import AppKit
import OSLog
import ServiceManagement

/// Wraps `SMAppService.mainApp`.
///
/// Caveat worth knowing: `SMAppService` wants a stable code signature. An
/// ad-hoc signed build (`codesign --sign -`) usually works but can be rejected,
/// and the registration is tied to the bundle's location — so registering a copy
/// in `build/` and then moving it will break the login item. `build.sh --install`
/// puts it in `/Applications` for exactly this reason.
///
/// If registration keeps failing, `lastErrorMessage` surfaces the reason in
/// Settings rather than silently leaving the toggle on.
@MainActor
final class LoginItemController: ObservableObject {
    private let log = Logger(subsystem: "com.gerdi.gh-badge", category: "LoginItem")

    @Published private(set) var lastErrorMessage: String?

    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the app is running from a location macOS will not honour for a
    /// login item.
    var isRunningFromTemporaryLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.contains("/build/")
            || path.contains("/.build/")
            || path.contains("/Downloads/")
            || path.hasPrefix("/private/var/folders/")
    }

    /// Returns true when the resulting state matches `enabled`.
    @discardableResult
    func apply(enabled: Bool) -> Bool {
        lastErrorMessage = nil
        let service = SMAppService.mainApp

        do {
            if enabled {
                guard service.status != .enabled else { return true }
                try service.register()
                log.info("registered as login item")
            } else {
                guard service.status == .enabled else { return true }
                try service.unregister()
                log.info("unregistered login item")
            }
            return true
        } catch {
            let hint = isRunningFromTemporaryLocation
                ? " Move gh-badge.app into /Applications and try again."
                : ""
            lastErrorMessage = error.localizedDescription + hint
            log.error("login item \(enabled ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Brings the stored preference and the actual system state back in sync at
    /// launch — the user can remove the login item from System Settings behind
    /// our back.
    func reconcile(storedPreference: Bool) -> Bool {
        let actual = isRegistered
        guard actual != storedPreference else { return storedPreference }

        // Trust the system state unless we can successfully change it.
        if apply(enabled: storedPreference) {
            return storedPreference
        }
        return actual
    }
}
