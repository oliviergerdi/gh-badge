import AppKit
import Combine
import GHBadgeCore
import SwiftUI

struct DropdownView: View {
    @ObservedObject var store: PRStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var seen: SeenPRStore
    let onOpenSettings: () -> Void

    private static let contentWidth: CGFloat = 460
    private static let listMaxHeight: CGFloat = 560

    @State private var listContentHeight: CGFloat = DropdownView.listMaxHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A rate limit gets its own banner: the generic one offers a Retry
            // button, and retrying is the one thing that must not happen here.
            if let until = store.rateLimitedUntil {
                RateLimitBanner(retryAt: until, isSecondary: store.rateLimitIsSecondary)
                Divider()
            } else if let error = store.ghError {
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
                        emptyText: emptyText(forReviewSection: true),
                        seen: seen,
                        showAuthorName: settings.showAuthorName,
                        showBranchName: settings.showBranchName,
                        branchNames: store.branchNames
                    )
                    PRSection(
                        title: "Already Reviewed, Still Open",
                        systemImage: "checkmark.circle",
                        pullRequests: store.sections.alreadyReviewed,
                        emptyText: emptyText(forReviewSection: true),
                        seen: seen,
                        showAuthorName: settings.showAuthorName,
                        showBranchName: settings.showBranchName,
                        branchNames: store.branchNames
                    )
                    PRSection(
                        title: "My Open PRs",
                        systemImage: "arrow.triangle.pull",
                        pullRequests: store.sections.myOpenPRs,
                        emptyText: emptyText(forReviewSection: false),
                        seen: seen,
                        showAuthorName: settings.showAuthorName,
                        showBranchName: settings.showBranchName,
                        branchNames: store.branchNames
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
    @ObservedObject var seen: SeenPRStore
    let showAuthorName: Bool
    let showBranchName: Bool
    let branchNames: [String: String]

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
                    PRRow(
                        pullRequest: pr,
                        seen: seen,
                        showAuthorName: showAuthorName,
                        branchName: showBranchName ? branchNames[pr.url] : nil
                    )
                }
            }
        }
    }
}

private struct PRRow: View {
    let pullRequest: PullRequest
    @ObservedObject var seen: SeenPRStore
    let showAuthorName: Bool
    /// Already resolved (and gated on `showBranchName`) by the caller — nil
    /// means either the setting is off or no branch name is known yet.
    let branchName: String?
    @State private var isHovering = false

    /// Dimmed once you've opened it and nothing's changed since; the moment a
    /// refresh shows a newer `updatedAt`, this flips back on its own.
    private var isDimmed: Bool {
        SeenPRs.isDimmed(pr: pullRequest, lastSeenUpdatedAt: seen.seen[pullRequest.url])
    }

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
                    if showAuthorName, let author = pullRequest.authorLogin {
                        Text("·")
                        Image(systemName: "person.fill")
                            .imageScale(.small)
                        Text(author)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let branchName {
                        Text("·")
                        Image(systemName: "arrow.triangle.branch")
                            .imageScale(.small)
                        Text(branchName)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
            .opacity(isDimmed ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(pullRequest.url)
    }

    private func open() {
        guard let url = URL(string: pullRequest.url) else { return }
        NSWorkspace.shared.open(url)
        seen.markOpened(pullRequest)
    }
}

// MARK: - Banners

/// Shown while GitHub has throttled us. Deliberately different from
/// `ErrorBanner` in two ways:
///
///   - **No Retry button.** Every request made during a cooldown counts against
///     it, so offering the user a button whose only effect is to prolong the
///     wait would be actively misleading. `PRStore.refresh()` refuses during a
///     cooldown regardless, but the UI shouldn't invite the attempt.
///   - **A live countdown**, because "waiting" with no end in sight reads as a
///     hang. The lists behind this banner still show the last good data.
private struct RateLimitBanner: View {
    let retryAt: Date
    let isSecondary: Bool

    @State private var now = Date()

    /// One tick per second. `.common` mode so it keeps running while the
    /// popover's scroll view is being dragged. `@State`, not `let`: a stored
    /// property would build a fresh publisher on every parent re-render and
    /// `onReceive` would resubscribe to it each time.
    @State private var ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hourglass")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Text(explanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.10))
        .onReceive(ticker) { now = $0 }
    }

    /// Once the clock runs out the countdown stops being the story: the app
    /// resumes on its own at the next poll, which may be a moment away.
    private var headline: String {
        retryAt > now
            ? "GitHub rate limit reached — resuming in \(countdown)"
            : "GitHub rate limit reached — resuming shortly"
    }

    private var explanation: String {
        isSecondary
            ? "Too many requests at once. Showing the last successful update."
            : "Hourly quota used up. Showing the last successful update."
    }

    private var countdown: String {
        let remaining = Int(max(retryAt.timeIntervalSince(now), 0).rounded(.up))
        if remaining >= 60 {
            let minutes = remaining / 60
            let seconds = remaining % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        return "\(remaining)s"
    }
}

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
            // Also disabled during a rate-limit cooldown: `PRStore.refresh()`
            // refuses anyway, and a button that silently does nothing is worse
            // than one that visibly can't be pressed.
            .disabled(store.isRefreshing || store.isRateLimited)
            .help(store.isRateLimited ? "Waiting out a GitHub rate limit" : "")

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
