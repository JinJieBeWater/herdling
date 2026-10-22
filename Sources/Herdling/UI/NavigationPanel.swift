import SwiftUI

/// Fixed controls plus a scrolling roster, sharing one inset content boundary.
struct NavigationPanel: View {
    let store: SessionStore
    let browser: NavigationBrowser
    @State private var measuredHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: Theme.Spacing.navigationHeaderGap) {
            NavigationHeader(browser: browser)
                .navigationHeight(.header)
                .padding(.horizontal, Theme.Spacing.panelInset)
            ScrollViewReader { proxy in
                ScrollView {
                    NavigationList(store: store, browser: browser)
                        .fixedSize(horizontal: false, vertical: true)
                        .navigationHeight(.list)
                        .padding(.horizontal, Theme.Spacing.panelInset)
                        .background(RosterScrollbarAttachment())
                }
                .overflowFade()
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: browser.keyboardSelection) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
                .onChange(of: browser.quickIDs) { _, _ in
                    if browser.mode == .quick, let selection = browser.keyboardSelection { proxy.scrollTo(selection) }
                }
            }
        }
        .rosterBoundary(topInset: Theme.Spacing.navigationTopInset)
        .onPreferenceChange(NavigationHeightKey.self) { parts in
            // Measure intrinsic content, never the constrained scroll viewport.
            measuredHeight = parts.values.reduce(0, +) + Theme.Spacing.navigationHeaderGap
                + Theme.Spacing.navigationTopInset + Theme.Spacing.panelBottomInset
        }
        .preference(key: PanelContentHeightKey.self, value: measuredHeight)
    }
}

private enum NavigationHeightPart: Hashable { case header, list }

private struct NavigationHeightKey: PreferenceKey {
    static let defaultValue: [NavigationHeightPart: CGFloat] = [:]
    static func reduce(value: inout [NavigationHeightPart: CGFloat], nextValue: () -> [NavigationHeightPart: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: max)
    }
}

private extension View {
    func navigationHeight(_ part: NavigationHeightPart) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: NavigationHeightKey.self, value: [part: geometry.size.height])
            }
        }
    }
}

struct NavigationHeader: View {
    let browser: NavigationBrowser

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            NavigationModeSwitch(browser: browser)
            Spacer(minLength: Theme.Spacing.md)
            if !browser.offlineSourceNames.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    RowSymbol(symbol: "network.slash", tint: Theme.Hue.orange,
                              slotSize: Theme.Size.navigationIcon)
                    Text("\(browser.offlineSourceNames.count) offline")
                        .font(Theme.Typography.rowTrailing)
                }
                .foregroundStyle(Theme.Hue.orange)
                .help(browser.offlineSourceNames.joined(separator: ", "))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(browser.offlineSourceNames.count) sources have unavailable status")
                .accessibilityHint(browser.offlineSourceNames.joined(separator: ", "))
            }
        }
        .padding(.trailing, Theme.Spacing.md)
        .frame(height: Theme.Size.navigationHeaderHeight)
    }

}

/// One view choice, with a single movable selection background and no shared track.
private struct NavigationModeSwitch: View {
    let browser: NavigationBrowser
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            option("Activity", symbol: "waveform", mode: .quick)
            option("Sources", symbol: "server.rack", mode: .all)
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent view")
        .animation(AccordionMotion.animation(reduceMotion: reduceMotion), value: browser.mode)
    }

    private func option(_ title: String, symbol: String, mode: NavigationBrowser.Mode) -> some View {
        NavigationModeOption(title: title, symbol: symbol, selected: browser.mode == mode,
                             meetsShellCorner: mode == .quick,
                             selection: selection, action: { browser.setMode(mode) })
    }
}

private struct NavigationModeOption: View {
    let title: String
    let symbol: String
    let selected: Bool
    let meetsShellCorner: Bool
    let selection: Namespace.ID
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.panelIsOpen) private var panelIsOpen

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.navigationContentGap) {
                RowSymbol(symbol: symbol, tint: selected || hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary,
                          slotSize: Theme.Size.navigationIcon, role: .navigation)
                Text(title)
            }
                .font(Theme.Typography.navigationModeLabel)
                .foregroundStyle(selected || hovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .padding(.horizontal, Theme.Spacing.navigationContentInset)
                .frame(height: Theme.Size.navigationControlHeight)
                .background {
                    if selected {
                        UnevenRoundedRectangle(
                            topLeadingRadius: meetsShellCorner ? Theme.Radius.panelContent.width : Theme.Radius.navigationControl,
                            bottomLeadingRadius: Theme.Radius.navigationControl,
                            bottomTrailingRadius: Theme.Radius.navigationControl,
                            topTrailingRadius: Theme.Radius.navigationControl,
                            style: .continuous)
                            .fill(Theme.Colors.selection)
                            .matchedGeometryEffect(id: "active-view", in: selection)
                    }
                }
                .frame(height: Theme.Size.navigationHeaderHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onChange(of: panelIsOpen) { _, isOpen in if isOpen { hovered = false } }
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "")
    }
}

struct NavigationList: View {
    let store: SessionStore
    let browser: NavigationBrowser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.groupGap) {
            if browser.mode == .quick {
                quickList
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.sectionSpacing) {
                    ForEach(browser.allSources) { source in
                        SourceOutline(
                            store: store, source: source,
                            isExpanded: browser.expandedSourceID == source.id,
                            onToggle: {
                                withAnimation(AccordionMotion.animation(reduceMotion: reduceMotion)) {
                                    browser.toggleSource(source.id)
                                }
                            }
                        )
                    }
                }
            }
            if let destination = browser.recoveryTarget {
                recoverySection(destination)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var quickList: some View {
        if !browser.quickIDs.isEmpty {
            quickRows(browser.quickIDs)
        }
        if browser.quickIDs.isEmpty, browser.recoveryTarget == nil {
            Text(emptyMessage)
                .font(Theme.Typography.groupLabel)
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.md)
                .frame(maxWidth: .infinity, minHeight: Theme.Size.quickRowHeight)
        }
    }

    private var emptyMessage: String {
        if browser.quickCandidateCount > 0 {
            return "New activity — reopen"
        }
        if !browser.hasOnlineCoverage { return "Connect a source to see current status" }
        return browser.offlineSourceNames.isEmpty ? "No agents available" : "No online agents available"
    }

    private func quickRows(_ destinations: [NavigationDestination]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            ForEach(destinations, id: \.self) { destination in
                QuickNavigationRow(store: store, browser: browser, destination: destination)
            }
        }
    }

    private func recoverySection(_ destination: NavigationDestination) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.rowGap) {
            HStack(spacing: Theme.Spacing.rowContentGap) {
                RowSlot { EmptyView() }
                Text("Last jump").font(Theme.Typography.groupLabel.weight(.medium))
                Spacer(minLength: Theme.Spacing.md)
            }
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: Theme.Size.rowMinHeight)
            QuickNavigationRow(store: store, browser: browser, destination: destination)
        }
    }
}

struct QuickNavigationRow: View {
    let store: SessionStore
    let browser: NavigationBrowser
    let destination: NavigationDestination

    private var presentation: NavigationRowPresentation { browser.presentation(for: destination) }
    private var pending: Bool { browser.attempt?.destination == destination && browser.attempt?.phase == .pending }
    private var observeOnly: Bool { store.isObserveOnly(destination) }
    private var readout: String? {
        if pending || !presentation.available { return statusText }
        if observeOnly { return nil }
        return presentation.status == .idle || presentation.status == .working ? nil : statusText
    }
    private var statusText: String {
        if pending { return "Opening" }
        guard presentation.available else { return "Unavailable" }
        switch presentation.status {
        case .blocked: return "Needs input"
        case .done: return "Completed"
        case let status?: return status.rosterLabel
        case nil: return "Open"
        }
    }

    var body: some View {
        HoverRow(
            minHeight: Theme.Size.quickRowHeight, verticalPadding: 0,
            enabled: presentation.available,
            accessibilityText: "\(presentation.title), \(presentation.subtitle), \(statusText)" + (observeOnly ? ", muted" : ""),
            action: { store.navigate(to: destination) }
        ) { isHovered in
            HStack(spacing: Theme.Spacing.rowContentGap) {
                RowSymbol(
                    symbol: presentation.status?.indicatorSymbolName ?? "arrow.up.right",
                    tint: presentation.status?.badgeTint(observeOnly: observeOnly)
                )
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Spacing.lg) {
                        Text(presentation.title)
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(observeOnly && presentation.available ? Theme.Colors.mutedTitle : Theme.Colors.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Theme.Spacing.xs)
                        if let readout {
                            Text(readout)
                                .font(Theme.Typography.rowTrailing)
                                .foregroundStyle(Theme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Text(presentation.subtitle)
                        .font(Theme.Typography.groupLabel)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            NavigationRowFeedback(store: store, destination: destination, isHovered: isHovered, showsIdleArrow: false)
        }
        .navigationRow(.destination(destination))
        .agentActions(destination)
        .help((observeOnly ? "Muted · " : "") + statusText.capitalized + "\n" + presentation.title + "\n"
              + [destination.sourceID, destination.sessionName, destination.agentFocusID?.paneID].compactMap { $0 }.joined(separator: " / "))
    }
}
