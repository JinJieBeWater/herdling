import SwiftUI

struct SettingsView: View {
    let store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button { store.setShowingSettings(false) } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to agents")
                    .accessibilityLabel("Back to agents")
                    Spacer()
                    Text("Settings")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Color.clear.frame(width: 28, height: 28)
                }
                .padding(.horizontal, 8)
                .frame(height: 42)

                Divider()
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PanelContentHeightKey.self,
                        value: PanelHeightMeasurement(header: geometry.size.height)
                    )
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsGroup("SSH Sources") {
                        if store.availableSSHAliases.isEmpty {
                            Text("No aliases found in ~/.ssh/config").foregroundStyle(.secondary)
                        }
                        ForEach(store.availableSSHAliases, id: \.self) { alias in
                            Toggle(alias, isOn: Binding(
                                get: { store.selectedSSHAliases.contains(alias) },
                                set: { store.setRemoteAlias(alias, enabled: $0) }
                            ))
                        }
                    }

                    settingsGroup("Ghostty") {
                        Picker("Open new clients in", selection: Binding(
                            get: { store.ghosttyOpenBehavior },
                            set: { store.setGhosttyOpenBehavior($0) }
                        )) {
                            Text("Window").tag(GhosttyOpenBehavior.window)
                            Text("Tab").tag(GhosttyOpenBehavior.tab)
                        }
                        .pickerStyle(.segmented)
                    }

                    settingsGroup("General") {
                        Toggle("Launch at Login", isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLogin($0) }
                        ))
                    }

                    settingsGroup("Permissions") {
                        permissionRow("Ghostty Automation", value: store.automationStatus)
                    }

                    if let error = store.settingsError { ErrorRow(message: error) }
                }
                .padding(16)
                .frame(maxWidth: 540, alignment: .leading)
                .frame(maxWidth: .infinity)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: PanelContentHeightKey.self,
                            value: PanelHeightMeasurement(body: geometry.size.height)
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.automatic)
            .contentMargins(.vertical, 8, for: .scrollIndicators)
        }
        .task { await store.refreshPermissionStatus() }
        .task { await store.refreshSSHAliases() }
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(_ name: String, value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
