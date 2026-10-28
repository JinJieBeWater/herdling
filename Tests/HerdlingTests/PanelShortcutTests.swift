import Foundation
import KeyboardShortcuts
import Testing
@testable import Herdling

@Suite
@MainActor
struct PanelShortcutTests {
    @Test
    func registrationReplacesAndUnregistersItsAction() {
        let events = IsolatedShortcutEvents()
        let registration = events.makeRegistration()
        var oldInvocations = 0
        var newInvocations = 0
        registration.register { oldInvocations += 1 }
        registration.register { newInvocations += 1 }

        events.keyUp()

        #expect(oldInvocations == 0)
        #expect(newInvocations == 1)

        registration.unregister()
        registration.unregister()
        events.keyUp()
        #expect(newInvocations == 1)

        registration.register { newInvocations += 1 }
        events.keyUp()
        #expect(newInvocations == 2)
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
