import AppKit

@MainActor
enum HerdlingApplicationMenu {
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
