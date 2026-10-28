import AppKit

@MainActor
enum HerdlingApplicationMenu {
    static func makeContext(target: AnyObject) -> NSMenu {
        let menu = NSMenu()
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

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)
        return mainMenu
    }
}
