import AppKit

enum PanelKeyAction: Equatable {
    case passThrough
    case handled
    case close
    case navigate(NavigationDestination)
}

@MainActor
enum PanelKeyboard {
    static func handle(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], browser: NavigationBrowser) -> PanelKeyAction {
        browser.holdPointer(at: NSEvent.mouseLocation)
        if keyCode == 48 { // Tab / Shift-Tab give focus back to native controls.
            browser.clearSelection()
            return .passThrough
        }
        guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else { return .passThrough }
        switch keyCode {
        case 53: return .close
        case 125: browser.moveSelection(by: 1)
        case 126: browser.moveSelection(by: -1)
        case 123: browser.horizontal(-1)
        case 124: browser.horizontal(1)
        case 36, 76:
            guard browser.selection != nil else { return .passThrough }
            if let destination = browser.activateSelection() { return .navigate(destination) }
        default: return .passThrough
        }
        return .handled
    }
}
