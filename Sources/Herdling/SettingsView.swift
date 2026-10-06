import SwiftUI

/// The Settings window's content: one grouped `Form`, so cards, row insets and hairlines are
/// system-drawn and the window reads as System Settings does. See `docs/ui.md`.
struct SettingsView: View {
    let store: SessionStore

    var body: some View {
        Form {
            sshSources
            ghostty
            general
            permissions

            if let error = store.settingsError {
                Section {
                    ErrorRow(message: error)
                }
            }
        }
        .formStyle(.grouped)
        .frame(
            minWidth: Theme.Size.settingsWidth,
            minHeight: Theme.Size.settingsMinHeight
        )
        .task { await store.refreshPermissionStatus() }
        .task { await store.refreshSSHAliases() }
    }

    private var sshSources: some View {
        Section {
            let aliases = store.availableSSHAliases
            if aliases.isEmpty {
                Text("No aliases found in ~/.ssh/config")
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            ForEach(aliases, id: \.self) { alias in
                let isEnabled = store.selectedSSHAliases.contains(alias)
                Toggle(isOn: Binding(
                    get: { isEnabled },
                    set: { store.setRemoteAlias(alias, enabled: $0) }
                )) {
                    // A host that is off reads as off, the way a Settings sidebar's glyph does.
                    SettingsLabel(
                        title: alias,
                        symbol: "network",
                        tint: isEnabled ? Theme.Hue.purple : Theme.Colors.textTertiary
                    )
                }
            }
        } header: {
            Text("SSH Sources")
        } footer: {
            Text("Herdr must be installed on each enabled host. Disabled hosts are never contacted.")
        }
    }

    private var ghostty: some View {
        Section("Ghostty") {
            Picker(selection: Binding(
                get: { store.ghosttyOpenBehavior },
                set: { store.setGhosttyOpenBehavior($0) }
            )) {
                Text("Window").tag(GhosttyOpenBehavior.window)
                Text("Tab").tag(GhosttyOpenBehavior.tab)
            } label: {
                SettingsLabel(
                    title: "Open new clients in",
                    subtitle: "Where a client opens when no existing one can be reused.",
                    symbol: "macwindow",
                    tint: Theme.Hue.blue
                )
            }
            .pickerStyle(.segmented)
        }
    }

    private var general: some View {
        Section("General") {
            Toggle(isOn: Binding(
                get: { store.launchAtLoginEnabled },
                set: { store.setLaunchAtLogin($0) }
            )) {
                SettingsLabel(
                    title: "Launch at Login",
                    subtitle: "Herdling starts with your Mac and keeps the roster current.",
                    symbol: "power",
                    tint: Theme.Hue.green
                )
            }
        }
    }

    private var permissions: some View {
        Section {
            LabeledContent {
                Text(store.automationStatus)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            } label: {
                SettingsLabel(
                    title: "Ghostty Automation",
                    subtitle: "Let Herdling open and focus sessions.",
                    symbol: "lock.shield",
                    tint: Theme.Hue.orange
                )
            }
        } header: {
            Text("Permissions")
        }
    }
}
