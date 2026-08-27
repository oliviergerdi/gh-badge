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
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
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
