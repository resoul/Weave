import Testing
import Weave

private actor TapCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

@Test
@MainActor
func buttonMapsTouchRemoteAndAccessibilityToOneTapEach() async {
    let button = ButtonNode(title: "Continue")
    let counter = TapCounter()
    let subscription = button.events.flux.sink { _ in Task { await counter.increment() } }

    #expect(!button.handle(.pointerDown))
    #expect(button.handle(.pointerUp(inside: true)))
    #expect(button.handle(.pressSelect))
    #expect(button.handle(.accessibilityActivate))
    for _ in 0..<10 { await Task.yield() }
    #expect(await counter.value() == 3)
    subscription.cancel()
}

@Test
@MainActor
func buttonCancelOutsideDisabledAndLoadingNeverEmitTap() async {
    let button = ButtonNode(title: "Save")
    let counter = TapCounter()
    let subscription = button.events.flux.sink { _ in Task { await counter.increment() } }

    _ = button.handle(.pointerDown)
    #expect(!button.handle(.cancelled))
    _ = button.handle(.pointerUp(inside: true))
    button.isEnabled = false
    #expect(!button.handle(.pressSelect))
    button.isEnabled = true
    button.isLoading = true
    #expect(!button.handle(.pressSelect))
    button.isLoading = false
    _ = button.handle(.pointerDown)
    #expect(!button.handle(.pointerUp(inside: false)))
    for _ in 0..<10 { await Task.yield() }
    #expect(await counter.value() == 0)
    subscription.cancel()
}

@Test
@MainActor
func buttonDisposeClearsPressedStateAndUsesDefaultSemantics() {
    let button = ButtonNode(title: "Delete", role: .destructive)
    _ = button.handle(.pointerDown)
    #expect(button.phase == .pressed)
    button.dispose()
    #expect(button.phase == .idle)
    #expect(button.buttonConfiguration.role == .destructive)
    #expect(button.accessibility.role == .button)
    #expect(button.accessibility.actions == [.activate])
    #expect(!button.activate())
}
