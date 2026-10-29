import SwiftUI

/// The Settings window's content: one grouped `Form`, so cards, row insets and hairlines are
/// system-drawn and the window reads as System Settings does. See `docs/ui.md`.
struct SettingsView: View {
    let store: SessionStore

    var body: some View {
        Form {
            sshSources
            terminal
            general

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
        .onChange(of: store.terminalApplication) { _, _ in
            Task { await store.refreshTerminalStatus() }
        }
        .task { await store.refreshSSHAliases() }
    }

    private var sshSources: some View {
        Section {
            let aliases = store.availableSSHAliases
            if aliases.isEmpty {
                Text("No aliases found in ~/.ssh/config")
                    .foregroundStyle(Theme.Colors.settingsSecondary)
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
                        tint: isEnabled ? Theme.Hue.purple : Theme.Colors.settingsTertiary
                    )
                }
            }
        } header: {
            Text("SSH Sources")
        } footer: {
            Text("Herdr must be installed on each enabled host. Disabled hosts are never contacted.")
        }
    }

    private var terminal: some View {
        Section("Terminal") {
            Picker(selection: Binding(
                get: { store.terminalApplication },
                set: { store.setTerminalApplication($0) }
            )) {
                ForEach(TerminalApplication.allCases, id: \.self) { application in
                    Text(application.name).tag(application)
                }
            } label: {
                SettingsLabel(
                    title: "Application",
                    subtitle: "Open Herdr clients in this terminal.",
                    symbol: "terminal",
                    tint: Theme.Hue.blue
                )
            }
            .pickerStyle(.segmented)

            if store.terminalApplication == .ghostty {
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

            LabeledContent {
                Text(store.terminalStatus)
                    .foregroundStyle(Theme.Colors.settingsSecondary)
                    .lineLimit(1)
            } label: {
                SettingsLabel(
                    title: store.terminalApplication == .ghostty ? "Ghostty Automation" : "Kero CLI",
                    subtitle: store.terminalApplication == .ghostty
                        ? "Let Herdling open and focus sessions."
                        : "Reuse a matching pane, or open a new Kero session.",
                    symbol: store.terminalApplication == .ghostty ? "lock.shield" : "terminal",
                    tint: store.terminalApplication == .ghostty ? Theme.Hue.orange : Theme.Hue.blue
                )
            }
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
}
