import Testing
import Weave

@MainActor
private final class LifecycleProbe {
    var events: [String] = []
    var cancellations = 0
}

@Test @MainActor
func test_lifecycle_transitions_areIdempotent_andHooksRunOnce() {
    let probe = LifecycleProbe()
    var hooks = LifecycleHooks()
    hooks.composed = { probe.events.append("composed") }
    hooks.connected = { probe.events.append("connected") }
    hooks.mounted = { probe.events.append("mounted") }
    hooks.activated = { probe.events.append("active") }
    hooks.deactivated = { probe.events.append("inactive") }
    hooks.disposed = { probe.events.append("disposed") }
    let machine = LifecycleMachine(hooks: hooks)

    #expect(machine.transition(.compose))
    #expect(!machine.transition(.compose))
    #expect(machine.transition(.connect))
    #expect(machine.transition(.mount))
    #expect(machine.transition(.activate))
    #expect(machine.transition(.deactivate))
    #expect(machine.transition(.activate))
    #expect(machine.transition(.dispose))
    #expect(!machine.transition(.dispose))
    #expect(machine.state == .disposed)
    #expect(
        probe.events == [
            "composed", "connected", "mounted", "active", "inactive", "active", "disposed",
        ]
    )
}

@Test @MainActor
func test_connectionScope_replacingBindingAndEffect_cancelsPrevious() {
    let scope = ConnectionScope()
    let probe = LifecycleProbe()
    scope.bind(id: "binding", cancel: { probe.cancellations += 1 })
    scope.bind(id: "binding", cancel: { probe.cancellations += 1 })
    #expect(probe.cancellations == 1)

    let first = scope.effect(id: "effect") {}
    let second = scope.effect(id: "effect") {}
    #expect(first)
    #expect(second)
    scope.cancel(id: "binding")
    #expect(probe.cancellations == 2)
}

@Test @MainActor
func test_lifecycle_reconnect_replacesScope_withoutDuplicatingOwnership() {
    let machine = LifecycleMachine()
    #expect(machine.transition(.compose))
    #expect(machine.transition(.connect))
    let first = machine.connectionScope
    #expect(machine.transition(.reconnect))
    #expect(machine.connectionScope !== first)
    #expect(first?.isCancelled == true)
    #expect(machine.state == .connected)
}

@Test @MainActor
func test_lifecycle_deactivateCancelsOwnedEffects_andDisposeIsTerminal() {
    let machine = LifecycleMachine()
    #expect(machine.transition(.compose))
    #expect(machine.transition(.connect))
    #expect(machine.transition(.mount))
    #expect(machine.transition(.activate))
    let scope = machine.connectionScope
    #expect(
        (scope?.effect(
            id: "load",
            operation: { try await Task.sleep(nanoseconds: 1_000_000_000) }
        ) ?? false)
    )
    #expect(machine.transition(.deactivate))
    #expect(machine.state == .inactive)
    #expect(machine.transition(.unmount))
    #expect(machine.transition(.dispose))
    #expect(machine.state == .disposed)
    #expect(!machine.transition(.connect))
}
