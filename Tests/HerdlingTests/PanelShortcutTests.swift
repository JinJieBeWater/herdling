import Foundation
import KeyboardShortcuts
import Testing
@testable import Herdling

@Suite
@MainActor
struct PanelShortcutTests {
    @Test
    func keyUpInvokesRegisteredAction() {
        let events = IsolatedShortcutEvents()
        let registration = events.makeRegistration()
        var invocations = 0
        registration.register { invocations += 1 }

        events.keyUp()

        #expect(invocations == 1)
    }

    @Test
    func registeringAgainReplacesPreviousAction() {
        let events = IsolatedShortcutEvents()
        let registration = events.makeRegistration()
        var oldInvocations = 0
        var newInvocations = 0
        registration.register { oldInvocations += 1 }
        registration.register { newInvocations += 1 }

        events.keyUp()

        #expect(oldInvocations == 0)
        #expect(newInvocations == 1)
    }

    @Test
    func unregisterStopsActionAndAllowsFreshRegistration() {
        let events = IsolatedShortcutEvents()
        let registration = events.makeRegistration()
        var invocations = 0
        registration.register { invocations += 1 }

        registration.unregister()
        registration.unregister()
        events.keyUp()
        #expect(invocations == 0)

        registration.register { invocations += 1 }
        events.keyUp()
        #expect(invocations == 1)
    }

    @Test
    func openingUnsetRecorderDoesNotStoreAShortcut() async {
        let name = KeyboardShortcuts.Name("panelShortcutRecorderTest-\(UUID().uuidString)")
        #expect(PanelShortcut.name.initialShortcut == nil)
        #expect(!KeyboardShortcuts.storedNames.contains(name))

        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
        await Task.yield()

        #expect(recorder.shortcut == nil)
        #expect(KeyboardShortcuts.getShortcut(for: name) == nil)
        #expect(!KeyboardShortcuts.storedNames.contains(name))
    }
}

@MainActor
private final class IsolatedShortcutEvents {
    let name = KeyboardShortcuts.Name("panelShortcutTest-\(UUID().uuidString)")
    private var handlers: [KeyboardShortcuts.Name: [@MainActor () -> Void]] = [:]

    func makeRegistration() -> PanelShortcutRegistration {
        PanelShortcutRegistration(
            name: name,
            onKeyUp: { [self] name, action in
                handlers[name, default: []].append(action)
            },
            removeHandler: { [self] name in
                handlers[name] = nil
            }
        )
    }

    func keyUp() {
        for action in handlers[name, default: []] {
            action()
        }
    }
}
