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
    private var terminationPending = false

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
        // Overlay scrollers, app-wide and once: under the system's "Automatic" setting AppKit
        // otherwise switches every scroll view to a legacy scroller the moment it sees a mouse,
        // and that scroller reserves a trailing gutter — inside a transparent panel it shows up as
        // the footer's right edge sitting inboard of its left one.
        UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")

        let store = SessionStore()
        self.store = store
        let statusController = StatusItemController(store: store)
        self.statusController = statusController
        NSApp.mainMenu = HerdlingApplicationMenu.make(settingsTarget: statusController)
        store.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await store.stopAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func activateExistingInstance() {
        statusController?.showPanel()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }
}
