import Foundation
import Testing
import Weave

@MainActor
private final class TestGestureClock: GestureClock {
    var nowNanoseconds: UInt64 = 0
    func advance(_ nanoseconds: UInt64) { nowNanoseconds &+= nanoseconds }
}

@MainActor
private func event(
    _ type: EventType,
    _ point: LayoutPoint = LayoutPoint(x: 0, y: 0),
    id: UInt64 = 1,
    window: UUID
) -> Event {
    Event(
        type: type,
        targetID: 1,
        payload: .pointer(PointerData(point: point, pointerID: id, windowID: window))
    )
}

@Test
@MainActor
func tapAndDoubleTapUseFakeClockThresholds() {
    let clock = TestGestureClock()
    let window = UUID()
    let point = LayoutPoint(x: 10, y: 10)
    let tap = TapRecognizer(clock: clock)
    _ = tap.handleEvent(event(.pointerDown, point, window: window))
    clock.advance(100_000_000)
    #expect(tap.handleEvent(event(.pointerUp, point, window: window)) == .ended)

    let doubleTap = DoubleTapRecognizer(clock: clock)
    _ = doubleTap.handleEvent(event(.pointerDown, point, window: window))
    #expect(doubleTap.handleEvent(event(.pointerUp, point, window: window)) == .ignored)
    clock.advance(100_000_000)
    _ = doubleTap.handleEvent(event(.pointerDown, point, id: 2, window: window))
    #expect(doubleTap.handleEvent(event(.pointerUp, point, id: 2, window: window)) == .ended)
}

@Test
@MainActor
func longPressAndPanRespectCancellation() {
    let clock = TestGestureClock()
    let window = UUID()
    let longPress = LongPressRecognizer(clock: clock)
    _ = longPress.handleEvent(event(.pointerDown, window: window))
    clock.advance(600_000_000)
    #expect(longPress.handleEvent(event(.pointerMove, window: window)) == .began)
    #expect(longPress.handleEvent(event(.pointerCancel, window: window)) == .cancelled)
    #expect(longPress.handleEvent(event(.pointerCancel, window: window)) == .ignored)

    let pan = PanRecognizer()
    _ = pan.handleEvent(event(.pointerDown, window: window))
    let panMove = event(.pointerMove, LayoutPoint(x: 20, y: 0), window: window)
    let panCancel = event(.pointerCancel, LayoutPoint(x: 20, y: 0), window: window)
    #expect(pan.handleEvent(panMove) == .began)
    #expect(pan.handleEvent(panCancel) == .cancelled)
}

@Test
@MainActor
func gestureArenaCancelsLoserAndNormalizesSelect() {
    let window = UUID()
    let tap = TapRecognizer()
    let pan = PanRecognizer()
    let arena = GestureArena(recognizers: [tap, pan])
    _ = arena.handleEvent(event(.pointerDown, window: window))
    let move = event(.pointerMove, LayoutPoint(x: 20, y: 0), window: window)
    #expect(arena.handleEvent(move) == .began)
    #expect(tap.state == .possible)

    let activation = ActivationRecognizer()
    let activationArena = GestureArena(recognizers: [activation])
    #expect(activationArena.handleEvent(Event(type: .pressSelect, targetID: 1)) == .ended)
}

@Test
@MainActor
func pinchAndRotationRequireMultitouchAndCancelCleanly() {
    let window = UUID()
    let pinch = PinchRecognizer()
    _ = pinch.handleEvent(event(.pointerDown, id: 1, window: window))
    _ = pinch.handleEvent(event(.pointerDown, LayoutPoint(x: 10, y: 0), id: 2, window: window))
    #expect(
        pinch.handleEvent(event(.pointerMove, LayoutPoint(x: 30, y: 0), id: 2, window: window))
            == .began
    )
    #expect(
        pinch.handleEvent(event(.pointerCancel, LayoutPoint(x: 30, y: 0), id: 2, window: window))
            == .cancelled
    )

    let rotation = RotationRecognizer()
    _ = rotation.handleEvent(event(.pointerDown, id: 1, window: window))
    _ = rotation.handleEvent(event(.pointerDown, LayoutPoint(x: 10, y: 0), id: 2, window: window))
    #expect(
        rotation.handleEvent(event(.pointerMove, LayoutPoint(x: 0, y: 10), id: 2, window: window))
            == .began
    )
}
