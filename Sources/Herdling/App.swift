import AppKit

@main
@MainActor
enum HerdlingApp {
    static func main() {
        let app = NSApplication.shared
        app.disableRelaunchOnLogin()
        app.applicationIconImage = HerdrBrand.applicationIcon
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: SessionStore?
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = SessionStore()
        self.store = store
        statusController = StatusItemController(store: store)
        store.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }
}
