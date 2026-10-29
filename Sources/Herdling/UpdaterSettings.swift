import Combine
import Foundation
import Sparkle

@MainActor
enum UpdaterStartup {
    static func start(_ controller: SPUStandardUpdaterController) {
        #if !DEBUG
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0.contains(".xctest") }) else { return }
        controller.startUpdater()
        #endif
    }
}

@MainActor
final class UpdaterSettings: ObservableObject {
    @Published private(set) var automaticallyChecksForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }
}
