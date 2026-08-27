import AppKit
import Combine
import GHBadgeCore
import SwiftUI

/// Owns the menu bar item and its two interactions: a left click toggles the
/// dropdown popover, a right click shows a context menu (Refresh / Settings /
/// Quit).
///
/// `MenuBarExtra` can't expose a right-click menu, so this replaces it with the
/// plain `NSStatusItem` API. The badge image is still `MenuBarIcon`'s composite
/// template image, tinted by the system exactly as before.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let contextMenu: NSMenu
    private let store: PRStore
    private let onOpenSettings: () -> Void

    /// Global+local mouseDown monitors that force-close the popover on an
    /// outside click. `.transient` alone is unreliable for status-item
    /// popovers in `LSUIElement` apps (accessory apps never become key/active,
    /// which is what AppKit's built-in transient dismissal leans on), so this
    /// closes explicitly instead of trusting it. Left installed between an
    /// AppKit-internal dismissal (e.g. Escape) and the next open/close, which
    /// is harmless: `closePopoverIfShown` no-ops once the popover isn't shown.
    private var outsideClickMonitors: [Any] = []

    private var cancellables = Set<AnyCancellable>()

    init(store: PRStore, settings: SettingsStore, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.onOpenSettings = onOpenSettings

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false

        let hosting = NSHostingController(
            rootView: DropdownView(
                store: store,
                settings: settings,
                onOpenSettings: onOpenSettings
            )
        )
        // Size the popover from the SwiftUI ideal size (460 wide, height fitted
        // to the list content); `WindowConfigurator` then makes it resizable and
        // enforces the floor.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        contextMenu = NSMenu()
        addMenuItem("Refresh", symbol: "arrow.clockwise", action: #selector(refresh))
        addMenuItem("Settings…", symbol: "gearshape", action: #selector(openSettings))
        contextMenu.addItem(.separator())
        addMenuItem("Quit", symbol: "power", action: #selector(quit))

        if let button = statusItem.button {
            button.image = MenuBarIcon.image(count: store.badgeCount, isError: store.ghError != nil)
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Re-render the badge when the count or error state changes.
        store.$sections
            .combineLatest(store.$ghError)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateIcon()
            }
            .store(in: &cancellables)
    }

    // MARK: - Menu bar icon

    private func updateIcon() {
        statusItem.button?.image = MenuBarIcon.image(
            count: store.badgeCount,
            isError: store.ghError != nil
        )
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        contextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height),
            in: button
        )
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            removeOutsideClickMonitors()
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOutsideClickMonitors()
        }
    }

    /// Closes the popover on the next mouseDown anywhere outside its window.
    /// A global monitor covers clicks in other apps and on the desktop; a
    /// local monitor covers clicks in this app's own windows (e.g. the
    /// Settings window), which the global monitor never sees. Both exclude
    /// clicks on the status item button itself: without that, a mouseDown on
    /// the button would force-close the popover before the button's own
    /// mouseUp action runs `togglePopover()`, which would then see it already
    /// closed and reopen it — turning a single click-to-close into a flicker.
    private func installOutsideClickMonitors() {
        removeOutsideClickMonitors()

        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !self.isClickOnStatusButton(NSEvent.mouseLocation) else { return }
            self.closePopoverIfShown()
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let popoverWindow = self.popover.contentViewController?.view.window else {
                return event
            }
            if event.window !== popoverWindow && !self.isClickOnStatusButton(NSEvent.mouseLocation) {
                self.closePopoverIfShown()
            }
            return event
        }

        if let global { outsideClickMonitors.append(global) }
        if let local { outsideClickMonitors.append(local) }
    }

    /// `screenPoint` is in screen coordinates, matching `NSEvent.mouseLocation`.
    private func isClickOnStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let frameInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frameInScreen.contains(screenPoint)
    }

    private func removeOutsideClickMonitors() {
        outsideClickMonitors.forEach(NSEvent.removeMonitor)
        outsideClickMonitors.removeAll()
    }

    private func closePopoverIfShown() {
        guard popover.isShown else { return }
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    // MARK: - Menu actions

    @objc private func refresh() {
        Task { await store.refresh() }
    }

    @objc private func openSettings() {
        onOpenSettings()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func addMenuItem(_ title: String, symbol: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        contextMenu.addItem(item)
    }
}
