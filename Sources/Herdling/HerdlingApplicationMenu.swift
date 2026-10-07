import AppKit

@MainActor
enum HerdlingApplicationMenu {
    static func makeContext(target: AnyObject, isRefreshing: Bool = false) -> NSMenu {
        let menu = NSMenu()
        // Keep the explicit busy state; default automatic validation would override isEnabled.
        menu.autoenablesItems = false
        let refresh = NSMenuItem(title: "Refresh", action: #selector(StatusItemController.refreshSources), keyEquivalent: "")
        refresh.target = target
        refresh.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")
        refresh.isEnabled = !isRefreshing
        menu.addItem(refresh)

        let settings = NSMenuItem(title: "Settings", action: #selector(StatusItemController.openSettings), keyEquivalent: "")
        settings.target = target
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Settings")
        menu.addItem(settings)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Herdling", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Quit Herdling")
        menu.addItem(quit)
        return menu
    }

    static func make(settingsTarget: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Herdling")

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(StatusItemController.openSettings),
            keyEquivalent: ","
        )
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Herdling",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
