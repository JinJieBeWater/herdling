import AppKit
import Combine
import Sparkle
import Testing
@testable import Herdling

@MainActor
func makeInactiveUpdaterController() -> SPUStandardUpdaterController {
    SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
}

@Suite(.serialized)
@MainActor
struct UpdaterTests {
    @Test
    func bothMenusUseSparkleActionTargetAndDisableUnavailableChecks() throws {
        _ = NSApplication.shared
        let controller = UpdateActionProbe(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let contextMenu = HerdlingApplicationMenu.makeContext(target: NSObject(), updaterController: controller)
        let mainMenu = HerdlingApplicationMenu.make(settingsTarget: NSObject(), updaterController: controller)
        let appMenu = try #require(mainMenu.items.first?.submenu)

        for menu in [contextMenu, appMenu] {
            let index = try #require(menu.items.firstIndex { $0.title == "Check for Updates…" })
            let item = menu.items[index]
            #expect(item.action == #selector(SPUStandardUpdaterController.checkForUpdates(_:)))
            #expect(item.target === controller)
            menu.update()
            #expect(!controller.updater.canCheckForUpdates)
            #expect(!item.isEnabled)
            // Dispatch without starting Sparkle or touching the user's desktop/network.
            menu.autoenablesItems = false
            item.isEnabled = true
            menu.performActionForItem(at: index)
        }
        #expect(controller.checkCount == 2)
    }

    @Test
    func automaticChecksReadWriteSparkleAndReflectExternalKVOChanges() {
        let controller = makeInactiveUpdaterController()
        let updater = controller.updater
        let original = updater.automaticallyChecksForUpdates
        defer { updater.automaticallyChecksForUpdates = original }
        updater.automaticallyChecksForUpdates = true
        let settings = UpdaterSettings(updater: updater)
        var published: [Bool] = []
        let observation = settings.$automaticallyChecksForUpdates.sink { published.append($0) }
        defer { observation.cancel() }

        #expect(settings.automaticallyChecksForUpdates)
        settings.setAutomaticallyChecksForUpdates(false)
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(!settings.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = true
        #expect(settings.automaticallyChecksForUpdates)
        #expect(published.contains(false))
        #expect(published.last == true)
        #expect(!updater.canCheckForUpdates)
    }

    @Test
    func debugAndTestStartupDoNotStartSparkle() {
        let controller = UpdateActionProbe(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        UpdaterStartup.start(controller)
        #expect(controller.startCount == 0)
        #expect(!controller.updater.canCheckForUpdates)
    }
}

@MainActor
private final class UpdateActionProbe: SPUStandardUpdaterController {
    var checkCount = 0
    var startCount = 0

    override func checkForUpdates(_ sender: Any?) { checkCount += 1 }
    override func startUpdater() { startCount += 1 }
}
