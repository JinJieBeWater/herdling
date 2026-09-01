import AppKit

@main
@MainActor
enum HerdlingApp {
    static func main() {
        guard let instanceLock = SingleInstanceLock.acquire(identifier: "dev.herdr.Herdling") else {
            DistributedNotificationCenter.default().postNotificationName(
                SingleInstanceLock.activationNotification,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return
        }
        let app = NSApplication.shared
        app.disableRelaunchOnLogin()
        app.applicationIconImage = HerdrBrand.applicationIcon
        let delegate = AppDelegate(instanceLock: instanceLock)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceLock: SingleInstanceLock
    private var store: SessionStore?
    private var statusController: StatusItemController?

    init(instanceLock: SingleInstanceLock) {
        self.instanceLock = instanceLock
        super.init()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(activateExistingInstance),
            name: SingleInstanceLock.activationNotification,
            object: nil
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore()
        self.store = store
        let statusController = StatusItemController(store: store)
        self.statusController = statusController
        NSApp.mainMenu = HerdlingApplicationMenu.make(settingsTarget: statusController)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    @objc private func activateExistingInstance() {
        statusController?.showPanel()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
