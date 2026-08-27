import AppKit
import GHBadgeCore
import SwiftUI

struct DropdownView: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings: SettingsStore
    let onOpenSettings: () -> Void

    private static let contentWidth: CGFloat = 460
    private static let listMaxHeight: CGFloat = 560

    @State private var listContentHeight: CGFloat = DropdownView.listMaxHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = store.ghError {
                ErrorBanner(message: error, isFatal: store.needsUserAction) {
                    Task { await store.retryFromScratch() }
                }
                Divider()
            }

            if settings.repoWhitelist.isEmpty && !settings.ignoreWhitelistForOwnPRs {
                EmptyWhitelistHint(onOpenSettings: onOpenSettings)
                Divider()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    PRSection(
                        title: "Needs My Review",
                        systemImage: "eye",
                        pullRequests: store.sections.needsReview,
                        emptyText: emptyText(forReviewSection: true)
                    )
                    PRSection(
                        title: "Already Reviewed, Still Open",
                        systemImage: "checkmark.circle",
                        pullRequests: store.sections.alreadyReviewed,
                        emptyText: emptyText(forReviewSection: true)
                    )
                    PRSection(
                        title: "My Open PRs",
                        systemImage: "arrow.triangle.pull",
                        pullRequests: store.sections.myOpenPRs,
                        emptyText: emptyText(forReviewSection: false)
                    )
                }
                .padding(.vertical, 10)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ListHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(
                minHeight: min(listContentHeight, Self.listMaxHeight),
                idealHeight: min(listContentHeight, Self.listMaxHeight),
                maxHeight: .infinity
            )

            Divider()
            FooterBar(store: store, onOpenSettings: onOpenSettings)
        }
        .frame(
            minWidth: Self.contentWidth,
            idealWidth: Self.contentWidth,
            maxWidth: .infinity
        )
        .background(WindowConfigurator())
        .onPreferenceChange(ListHeightKey.self) { listContentHeight = $0 }
    }

    private func emptyText(forReviewSection: Bool) -> String {
        if forReviewSection && settings.repoWhitelist.isEmpty {
            return "No repositories whitelisted"
        }
        return "Nothing here"
    }
}

/// Reports the natural height of the scrollable list content so the dropdown
/// can size itself to fit (up to `listMaxHeight`) instead of a fixed height.
private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Sections

private struct PRSection: View {
    let title: String
    let systemImage: String
    let pullRequests: [PullRequest]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !pullRequests.isEmpty {
                    Text("\(pullRequests.count)")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)

            if pullRequests.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            } else {
                ForEach(pullRequests) { pr in
                    PRRow(pullRequest: pr)
                }
            }
        }
    }
}

private struct PRRow: View {
    let pullRequest: PullRequest
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pullRequest.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)

                HStack(spacing: 4) {
                    Text(pullRequest.repo)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("#\(pullRequest.number)")
                        .monospacedDigit()
                    if let updatedAt = pullRequest.updatedAt {
                        Text("·")
                        Text(RelativeTime.string(for: updatedAt))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.16) : Color.clear)
            )
            .padding(.leading, 12)
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pullRequest.url)
    }

    private func open() {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Banners

private struct ErrorBanner: View {
    let message: String
    let isFatal: Bool
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    if isFatal {
                        Button("cli.github.com") {
                            if let url = URL(string: "https://cli.github.com") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
    }
}

private struct EmptyWhitelistHint: View {
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("No repositories are being watched.")
                    .font(.system(size: 12))
                Text("The review sections stay empty until you add repositories.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Add repositories…", action: onOpenSettings)
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var store: PRStore
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task { await store.refresh() }
            } label: {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Refresh")
                }
            }
            .disabled(store.isRefreshing)

            Button("Settings…", action: onOpenSettings)

            Spacer()

            if let lastUpdated = store.lastUpdated {
                Text(RelativeTime.string(for: lastUpdated))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Helpers

/// `@MainActor` so the shared `RelativeDateTimeFormatter` — a non-`Sendable`
/// class — is not unprotected global state. Only ever called from view bodies.
@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func string(for date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Makes the popover's backing `NSWindow` resizable and enforces a floor on its
/// size. `NSPopover` offers no public way to do either, so this reaches the
/// `NSWindow` once the content is attached to it.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfigView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.resizable)
            if window.minSize.width < 460 || window.minSize.height < 160 {
                window.minSize = NSSize(width: 460, height: 160)
            }
        }
    }
}
