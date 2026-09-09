import Foundation

/// State of a platform-neutral gesture state machine.
/// Ownership: the recognizer owns its state. Isolation: MainActor. Errors: none.
/// Cancellation: cancelled and failed states do not emit activation.
@MainActor
public enum GestureState: Sendable, Hashable {
    case possible
    case began
    case changed
    case ended
    case failed
    case cancelled
}

/// Result emitted by one recognizer for one raw event.
/// Ownership: the result is copied by the arena. Isolation: MainActor. Errors: none.
/// Cancellation: cancelled and failed results terminate the current session.
@MainActor
public enum GestureResult: Sendable, Hashable {
    case ignored
    case began
    case changed
    case ended
    case failed
    case cancelled
}

/// Monotonic clock used by recognizers; production and tests provide their own implementation.
/// Ownership: the clock is borrowed by a recognizer. Isolation: MainActor. Errors: none.
/// Cancellation: clock reads never schedule work.
@MainActor
public protocol GestureClock: AnyObject {
    var nowNanoseconds: UInt64 { get }
}

/// Production monotonic clock for gesture thresholds.
/// Ownership: instances are owned by their recognizer. Isolation: MainActor. Errors: none.
/// Cancellation: reads are synchronous.
@MainActor
public final class SystemGestureClock: GestureClock {
    /// Creates a system clock. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}
    public var nowNanoseconds: UInt64 { DispatchTime.now().uptimeNanoseconds }
}

/// Tunable, deterministic gesture thresholds.
/// Ownership: immutable value copied into recognizers. Isolation: none. Errors: invalid values
/// are clamped to safe defaults. Cancellation: not applicable.
public struct GestureConfiguration: Sendable, Hashable {
    public let tapMaximumDurationNanoseconds: UInt64
    public let doubleTapIntervalNanoseconds: UInt64
    public let longPressDurationNanoseconds: UInt64
    public let movementTolerance: Double
    public let panThreshold: Double
    public let pinchThreshold: Double
    public let rotationThresholdRadians: Double

    /// Creates gesture thresholds.
    /// Ownership: values are copied. Isolation: none. Errors: negative values are clamped.
    /// Cancellation: not applicable.
    public init(
        tapMaximumDurationNanoseconds: UInt64 = 400_000_000,
        doubleTapIntervalNanoseconds: UInt64 = 300_000_000,
        longPressDurationNanoseconds: UInt64 = 500_000_000,
        movementTolerance: Double = 12,
        panThreshold: Double = 8,
        pinchThreshold: Double = 8,
        rotationThresholdRadians: Double = 0.12
    ) {
        self.tapMaximumDurationNanoseconds = tapMaximumDurationNanoseconds
        self.doubleTapIntervalNanoseconds = doubleTapIntervalNanoseconds
        self.longPressDurationNanoseconds = longPressDurationNanoseconds
        self.movementTolerance = max(0, movementTolerance.isFinite ? movementTolerance : 12)
        self.panThreshold = max(0, panThreshold.isFinite ? panThreshold : 8)
        self.pinchThreshold = max(0, pinchThreshold.isFinite ? pinchThreshold : 8)
        self.rotationThresholdRadians = max(
            0,
            rotationThresholdRadians.isFinite ? rotationThresholdRadians : 0.12
        )
    }
}

/// Core gesture state-machine contract. Adapters provide only Event snapshots.
/// Ownership: an arena owns its recognizers. Isolation: MainActor. Errors: invalid event types
/// are ignored. Cancellation: reset is terminal for the current session and is idempotent.
@MainActor
public protocol GestureRecognizer: AnyObject {
    var state: GestureState { get }
    func handleEvent(_ event: Event) -> GestureResult
    func reset()
}

@MainActor
private func pointerData(_ event: Event) -> PointerData? {
    guard case .pointer(let data) = event.payload else { return nil }
    return data
}

@MainActor
private func distance(_ lhs: LayoutPoint, _ rhs: LayoutPoint) -> Double {
    let x = lhs.x - rhs.x
    let y = lhs.y - rhs.y
    return (x * x + y * y).squareRoot()
}

/// Recognizes a single stationary, short pointer activation.
/// Ownership: the recognizer owns one active pointer session. Isolation: MainActor. Errors: other
/// event kinds are ignored. Cancellation: movement, timeout and cancel fail the session.
@MainActor
public final class TapRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let configuration: GestureConfiguration
    private let clock: GestureClock
    private var pointer: PointerData?
    private var beganAt: UInt64 = 0

    /// Creates a tap recognizer with injectable timing.
    /// Ownership: the clock is retained by the recognizer. Isolation: MainActor. Errors: none.
    /// Cancellation: no task is scheduled.
    public init(
        configuration: GestureConfiguration = .init(),
        clock: GestureClock = SystemGestureClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        switch event.type {
        case .pointerDown where pointer == nil:
            pointer = data
            beganAt = clock.nowNanoseconds
            state = .possible
            return .ignored
        case .pointerMove where pointer?.pointerID == data.pointerID:
            guard let pointer,
                distance(pointer.point, data.point) <= configuration.movementTolerance
            else {
                state = .failed
                return .failed
            }
        case .pointerUp where pointer?.pointerID == data.pointerID:
            defer { pointer = nil }
            guard clock.nowNanoseconds &- beganAt <= configuration.tapMaximumDurationNanoseconds
            else {
                state = .failed
                return .failed
            }
            guard let pointer,
                distance(pointer.point, data.point) <= configuration.movementTolerance
            else {
                state = .failed
                return .failed
            }
            state = .ended
            return .ended
        case .pointerCancel where pointer?.pointerID == data.pointerID:
            pointer = nil
            state = .cancelled
            return .cancelled
        default:
            break
        }
        return .ignored
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() {
        pointer = nil
        state = .possible
    }
}

/// Recognizes two consecutive taps in one window.
/// Ownership: the recognizer owns timing and one active pointer. Isolation: MainActor. Errors:
/// nonmatching sessions are ignored. Cancellation: reset clears the pending first tap.
@MainActor
public final class DoubleTapRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let configuration: GestureConfiguration
    private let clock: GestureClock
    private var firstTapAt: UInt64?
    private var firstPoint: LayoutPoint?
    private var pointerID: UInt64?
    private var windowID: UUID?

    /// Creates a double-tap recognizer.
    /// Ownership: the clock is retained. Isolation: MainActor. Errors: none. Cancellation: none.
    public init(
        configuration: GestureConfiguration = .init(),
        clock: GestureClock = SystemGestureClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        switch event.type {
        case .pointerDown:
            if let firstTapAt,
                clock.nowNanoseconds &- firstTapAt <= configuration.doubleTapIntervalNanoseconds,
                (firstPoint.map {
                    distance($0, data.point) <= configuration.movementTolerance
                } == true),
                windowID == data.windowID
            {
                pointerID = data.pointerID
                state = .possible
                return .ignored
            }
            firstTapAt = nil
            firstPoint = data.point
            pointerID = data.pointerID
            windowID = data.windowID
        case .pointerUp where pointerID == data.pointerID:
            if firstTapAt == nil {
                firstTapAt = clock.nowNanoseconds
                firstPoint = data.point
                state = .possible
                return .ignored
            }
            firstTapAt = nil
            pointerID = nil
            state = .ended
            return .ended
        case .pointerCancel where pointerID == data.pointerID:
            reset()
            state = .cancelled
            return .cancelled
        default:
            break
        }
        return .ignored
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() {
        firstTapAt = nil
        firstPoint = nil
        pointerID = nil
        windowID = nil
        state = .possible
    }
}

/// Recognizes a stationary press held for the configured duration.
/// Ownership: the recognizer owns one pointer session. Isolation: MainActor. Errors: movement or
/// early release fail. Cancellation: cancel/reset clears the pending long-press state.
@MainActor
public final class LongPressRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let configuration: GestureConfiguration
    private let clock: GestureClock
    private var pointer: PointerData?
    private var beganAt: UInt64 = 0

    /// Creates a long-press recognizer.
    /// Ownership: the clock is retained. Isolation: MainActor. Errors: none. Cancellation: no task.
    public init(
        configuration: GestureConfiguration = .init(),
        clock: GestureClock = SystemGestureClock()
    ) {
        self.configuration = configuration
        self.clock = clock
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        guard data.pointerID == pointer?.pointerID || event.type == .pointerDown else {
            return .ignored
        }
        switch event.type {
        case .pointerDown:
            pointer = data
            beganAt = clock.nowNanoseconds
        case .pointerMove:
            guard let pointer,
                distance(pointer.point, data.point) <= configuration.movementTolerance
            else {
                state = .failed
                return .failed
            }
            if state == .possible,
                clock.nowNanoseconds &- beganAt >= configuration.longPressDurationNanoseconds
            {
                state = .began
                return .began
            }
            if state == .began {
                state = .changed
                return .changed
            }
        case .pointerUp:
            defer { pointer = nil }
            guard state == .began || state == .changed else {
                state = .failed
                return .failed
            }
            state = .ended
            return .ended
        case .pointerCancel:
            pointer = nil
            state = .cancelled
            return .cancelled
        default:
            break
        }
        return .ignored
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() {
        pointer = nil
        state = .possible
    }
}

/// Recognizes a drag after movement passes the pan threshold.
/// Ownership: the recognizer owns one pointer session. Isolation: MainActor. Errors: none.
/// Cancellation: cancel/reset ends the session without an activation.
@MainActor
public final class PanRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let configuration: GestureConfiguration
    private var pointer: PointerData?

    /// Creates a pan recognizer.
    /// Ownership: configuration is copied. Isolation: MainActor. Errors: none. Cancellation: none.
    public init(configuration: GestureConfiguration = .init()) {
        self.configuration = configuration
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        switch event.type {
        case .pointerDown where pointer == nil:
            pointer = data
        case .pointerMove where pointer?.pointerID == data.pointerID:
            guard let pointer else { return .ignored }
            if state == .possible
                && distance(pointer.point, data.point) >= configuration.panThreshold
            {
                state = .began
                return .began
            }
            if state == .began || state == .changed {
                state = .changed
                return .changed
            }
        case .pointerUp where pointer?.pointerID == data.pointerID:
            defer { pointer = nil }
            guard state == .began || state == .changed else {
                state = .failed
                return .failed
            }
            state = .ended
            return .ended
        case .pointerCancel where pointer?.pointerID == data.pointerID:
            pointer = nil
            state = .cancelled
            return .cancelled
        default:
            break
        }
        return .ignored
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() {
        pointer = nil
        state = .possible
    }
}

/// Recognizes a two-pointer pinch using distance change.
/// Ownership: the recognizer owns two pointer snapshots. Isolation: MainActor. Errors: fewer than
/// two pointers are ignored. Cancellation: any pointer cancel resets the session.
@MainActor
public final class PinchRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let threshold: Double
    private var points: [UInt64: LayoutPoint] = [:]
    private var initialDistance: Double?

    /// Creates a pinch recognizer.
    /// Ownership: threshold is copied. Isolation: MainActor. Errors: none. Cancellation: none.
    public init(configuration: GestureConfiguration = .init()) {
        threshold = configuration.pinchThreshold
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        switch event.type {
        case .pointerDown:
            points[data.pointerID] = data.point
            if points.count == 2 { initialDistance = currentDistance() }
        case .pointerMove where points[data.pointerID] != nil:
            points[data.pointerID] = data.point
            guard let initialDistance, let current = currentDistance() else { return .ignored }
            let delta = abs(current - initialDistance)
            if state == .possible && delta >= threshold { state = .began; return .began }
            if state == .began || state == .changed { state = .changed; return .changed }
        case .pointerUp, .pointerCancel:
            points.removeValue(forKey: data.pointerID)
            if event.type == .pointerCancel { reset(); state = .cancelled; return .cancelled }
            if state == .began || state == .changed { state = .ended; return .ended }
        default:
            break
        }
        return .ignored
    }

    private func currentDistance() -> Double? {
        guard let values = points.values.first,
            let other = points.values.dropFirst().first
        else { return nil }
        return distance(values, other)
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() { points.removeAll(); initialDistance = nil; state = .possible }
}

/// Recognizes a two-pointer rotation using angle change.
/// Ownership: the recognizer owns two pointer snapshots. Isolation: MainActor. Errors: fewer than
/// two pointers are ignored. Cancellation: any pointer cancel resets the session.
@MainActor
public final class RotationRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible
    private let threshold: Double
    private var points: [UInt64: LayoutPoint] = [:]
    private var initialAngle: Double?

    /// Creates a rotation recognizer.
    /// Ownership: threshold is copied. Isolation: MainActor. Errors: none. Cancellation: none.
    public init(configuration: GestureConfiguration = .init()) {
        threshold = configuration.rotationThresholdRadians
    }

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard let data = pointerData(event) else { return .ignored }
        switch event.type {
        case .pointerDown:
            points[data.pointerID] = data.point
            if points.count == 2 { initialAngle = currentAngle() }
        case .pointerMove where points[data.pointerID] != nil:
            points[data.pointerID] = data.point
            guard let initialAngle, let current = currentAngle() else { return .ignored }
            if state == .possible && abs(current - initialAngle) >= threshold {
                state = .began
                return .began
            }
            if state == .began || state == .changed {
                state = .changed
                return .changed
            }
        case .pointerUp, .pointerCancel:
            points.removeValue(forKey: data.pointerID)
            if event.type == .pointerCancel { reset(); state = .cancelled; return .cancelled }
            if state == .began || state == .changed { state = .ended; return .ended }
        default:
            break
        }
        return .ignored
    }

    private func currentAngle() -> Double? {
        guard let first = points.values.first,
            let second = points.values.dropFirst().first
        else { return nil }
        return atan2(second.y - first.y, second.x - first.x)
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() { points.removeAll(); initialAngle = nil; state = .possible }
}

/// Normalizes tvOS select/press activation into the same recognizer result path.
/// Ownership: no state is retained between activations. Isolation: MainActor. Errors: unrelated
/// events are ignored. Cancellation: reset returns to possible.
@MainActor
public final class ActivationRecognizer: GestureRecognizer {
    public private(set) var state: GestureState = .possible

    /// Creates an activation recognizer.
    /// Ownership: no dependencies are retained. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}

    /// Handles one event. Ownership: event borrowed. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func handleEvent(_ event: Event) -> GestureResult {
        guard event.type == .pressSelect || event.type == .custom("tvOS.select") else {
            return .ignored
        }
        state = .ended
        return .ended
    }

    /// Resets the session. Ownership: none. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() { state = .possible }
}

/// Arbitrates recognizers and cancels losers when one begins.
/// Ownership: the arena owns recognizers and optional capture targets. Isolation: MainActor.
/// Errors: events with no active recognizer are ignored. Cancellation: cancel/reset resets every
/// recognizer and releases capture exactly once.
@MainActor
public final class GestureArena {
    private struct SessionKey: Hashable { let pointerID: UInt64; let windowID: UUID }
    private let recognizers: [any GestureRecognizer]
    private let captureStore: PointerCaptureStore?
    private var winners: [SessionKey: Int] = [:]
    private var captureTargets: [SessionKey: Node] = [:]

    /// Creates an arena with ordered recognizers; earlier recognizers win ties.
    /// Ownership: recognizers and capture store are retained. Isolation: MainActor. Errors: none.
    /// Cancellation: no work starts during initialization.
    public init(
        recognizers: [any GestureRecognizer],
        captureStore: PointerCaptureStore? = nil
    ) {
        self.recognizers = recognizers
        self.captureStore = captureStore
    }

    /// Associates a pointer session with a capture target for winner capture.
    /// Ownership: the node is weakly associated through PointerCaptureStore. Isolation: MainActor.
    /// Errors: disposed targets are rejected by the store. Cancellation: association is cleared on end.
    public func setCaptureTarget(pointerID: UInt64, windowID: UUID, target: Node) {
        captureTargets[SessionKey(pointerID: pointerID, windowID: windowID)] = target
    }

    /// Feeds one raw event through arbitration.
    /// Ownership: the event is borrowed synchronously. Isolation: MainActor. Errors: none.
    /// Cancellation: losing recognizers and pointer cancel reset without activation.
    @discardableResult
    public func handleEvent(_ event: Event) -> GestureResult {
        guard case .pointer(let data) = event.payload else {
            return firstResult(for: event)
        }
        let key = SessionKey(pointerID: data.pointerID, windowID: data.windowID)
        if let winner = winners[key] {
            let result = recognizers[winner].handleEvent(event)
            finish(result, key: key, event: event)
            return result
        }
        for (index, recognizer) in recognizers.enumerated() {
            let result = recognizer.handleEvent(event)
            if result == .began || result == .ended {
                winners[key] = index
                for (otherIndex, other) in recognizers.enumerated() where otherIndex != index {
                    other.reset()
                }
                if let target = captureTargets[key] {
                    _ = captureStore?.capture(
                        pointerID: data.pointerID,
                        windowID: data.windowID,
                        target: target
                    )
                }
                finish(result, key: key, event: event)
                return result
            }
            if result == .ended || result == .failed || result == .cancelled { continue }
        }
        if event.type == .pointerUp || event.type == .pointerCancel { clear(key: key) }
        return .ignored
    }

    private func firstResult(for event: Event) -> GestureResult {
        for recognizer in recognizers {
            let result = recognizer.handleEvent(event)
            if result != .ignored { return result }
        }
        return .ignored
    }

    private func finish(_ result: GestureResult, key: SessionKey, event: Event) {
        guard
            result == .ended || result == .failed || result == .cancelled
                || event.type == .pointerUp || event.type == .pointerCancel
        else { return }
        clear(key: key)
    }

    private func clear(key: SessionKey) {
        _ = captureStore?.release(pointerID: key.pointerID, windowID: key.windowID)
        winners.removeValue(forKey: key)
        captureTargets.removeValue(forKey: key)
    }

    /// Cancels every active recognizer session.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func reset() {
        for recognizer in recognizers { recognizer.reset() }
        for key in winners.keys {
            _ = captureStore?.cancel(
                pointerID: key.pointerID,
                windowID: key.windowID,
                reason: .arbitrationLost
            )
        }
        winners.removeAll()
        captureTargets.removeAll()
    }
}
