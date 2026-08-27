import GHBadgeCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var loginItems: LoginItemController

    var body: some View {
        Form {
            Section {
                TokenListEditor(
                    entries: settings.repoWhitelist,
                    placeholder: "owner/repo",
                    invalidMessage: "Enter a repository as owner/repo.",
                    onAdd: { settings.addRepo($0) },
                    onRemove: { settings.removeRepos($0) }
                )
            } header: {
                Text("Watched repositories")
            } footer: {
                Text("Opt-in. While this list is empty, the review sections stay empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Include PRs where review is requested from my teams", isOn: $settings.teamReviewEnabled)

                if settings.teamReviewEnabled {
                    TokenListEditor(
                        entries: settings.teams,
                        placeholder: "org/team-slug",
                        invalidMessage: "Enter a team as org/team-slug.",
                        onAdd: { settings.addTeam($0) },
                        onRemove: { settings.removeTeams($0) }
                    )
                }
            } header: {
                Text("Team review requests")
            } footer: {
                Text("Use the team slug, not its display name — the one that appears in the team's URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show all of my own open PRs, ignoring the whitelist", isOn: $settings.ignoreWhitelistForOwnPRs)
            } header: {
                Text("My pull requests")
            }

            Section {
                TokenListEditor(
                    entries: settings.ignoredAuthors,
                    placeholder: "login (e.g. dependabot[bot])",
                    invalidMessage: "Enter a GitHub username or bot login.",
                    onAdd: { settings.addAuthor($0) },
                    onRemove: { settings.removeAuthors($0) }
                )
            } header: {
                Text("Ignored authors")
            } footer: {
                Text("PRs authored by these logins are hidden from the review sections. Doesn't affect My Open PRs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Ignore PRs older than", isOn: $settings.ignoreOlderThanEnabled)

                if settings.ignoreOlderThanEnabled {
                    HStack(spacing: 6) {
                        TextField("Amount", value: $settings.ignoreOlderThanValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Picker("Unit", selection: $settings.ignoreOlderThanUnitRaw) {
                            ForEach(StalenessUnit.allCases, id: \.self) { unit in
                                Text(unit.rawValue).tag(unit.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 96)
                        Spacer()
                    }
                }
            } header: {
                Text("Staleness")
            } footer: {
                Text("Hides PRs that haven't been updated within the given window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh every", selection: $settings.refreshIntervalSeconds) {
                    ForEach(SettingsStore.refreshIntervalOptions, id: \.self) { seconds in
                        Text(SettingsStore.intervalLabel(seconds)).tag(seconds)
                    }
                }

                Toggle("Launch at login", isOn: $settings.launchAtLogin)

                if let error = loginItems.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if loginItems.isRunningFromTemporaryLocation {
                    Label(
                        "Running from a temporary location. Launch at login needs the app in /Applications.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("General")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
    }
}

/// Add/remove list used for both repositories and teams. Same shape, same
/// validation, so one control serves both.
private struct TokenListEditor: View {
    let entries: [String]
    let placeholder: String
    let invalidMessage: String
    let onAdd: (String) -> Bool
    let onRemove: (Set<String>) -> Void

    @State private var draft = ""
    @State private var selection = Set<String>()
    @State private var showInvalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if showInvalid {
                Text(invalidMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            List(selection: $selection) {
                ForEach(entries, id: \.self) { entry in
                    Text(entry)
                        .font(.system(size: 12, design: .monospaced))
                        .tag(entry)
                }
            }
            .frame(height: 128)
            .overlay {
                if entries.isEmpty {
                    Text("Empty")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("Remove Selected") {
                    onRemove(selection)
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
                Spacer()
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commit() {
        let value = draft
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if onAdd(value) {
            draft = ""
            showInvalid = false
        } else {
            // Either malformed or already present; the message covers both well
            // enough for a two-field settings pane.
            showInvalid = true
        }
    }
}
