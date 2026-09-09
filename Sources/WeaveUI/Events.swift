import Foundation

/// Event categories understood by the platform-neutral dispatcher.
/// Ownership: the value is copied by an Event. Isolation: none. Errors: none. Cancellation: none.
public enum EventType: Sendable, Hashable {
    case pointerDown, pointerUp, pointerMove, pointerCancel
    case pressSelect
    case keyDown, keyUp
    case scroll
    case focusIn, focusOut
    case custom(String)
}

/// Dispatch phase for one mutable synchronous event context.
/// Ownership: the value is owned by the dispatcher. Isolation: MainActor during dispatch. Errors:
/// none. Cancellation: propagation can be stopped by the event.
public enum EventPhase: Sendable, Hashable {
    case capturing, atTarget, bubbling
}

/// Immutable pointer payload.
/// Ownership: the value owns its coordinates. Isolation: none. Errors: none. Cancellation: none.
public struct PointerData: Sendable, Hashable {
    public let point: LayoutPoint
    public let pointerID: UInt64
    public let windowID: UUID

    /// Creates pointer data.
    /// Ownership: the point is copied. Isolation: none. Errors: none. Cancellation: none.
    public init(point: LayoutPoint) {
        self.init(point: point, pointerID: 0, windowID: UUID())
    }

    /// Creates pointer data with explicit session identity.
    /// Ownership: the point and identity are copied. Isolation: none. Errors: none. Cancellation: none.
    public init(point: LayoutPoint, pointerID: UInt64, windowID: UUID) {
        self.point = point
        self.pointerID = pointerID
        self.windowID = windowID
    }
}

/// Immutable keyboard payload.
/// Ownership: the value owns copied text. Isolation: none. Errors: none. Cancellation: none.
public struct KeyData: Sendable, Hashable {
    public let keyCode: UInt16
    public let characters: String?

    /// Creates keyboard data.
    /// Ownership: characters are copied. Isolation: none. Errors: none. Cancellation: none.
    public init(keyCode: UInt16, characters: String? = nil) {
        self.keyCode = keyCode
        self.characters = characters
    }
}

/// Immutable event payload snapshot.
/// Ownership: associated values are copied. Isolation: none. Errors: none. Cancellation: none.
public enum EventPayload: Sendable, Hashable {
    case pointer(PointerData)
    case key(KeyData)
    case scroll(horizontal: Double, vertical: Double)
    case none
}

/// Mutable synchronous event context used only during one MainActor dispatch.
/// Ownership: the dispatcher owns the context. Isolation: MainActor. Errors: none. Cancellation:
/// stopPropagation and preventDefault are terminal for the current dispatch path.
@MainActor
public final class Event {
    public let id: UUID
    public let type: EventType
    public let targetID: ElementID
    public let payload: EventPayload
    public private(set) var phase: EventPhase = .capturing
    public private(set) var isPropagationStopped = false
    public private(set) var isDefaultPrevented = false

    /// Creates an event context.
    /// Ownership: payload is copied. Isolation: MainActor. Errors: none. Cancellation: flags start clear.
    public init(
        id: UUID = UUID(),
        type: EventType,
        targetID: ElementID,
        payload: EventPayload = .none
    ) {
        self.id = id
        self.type = type
        self.targetID = targetID
        self.payload = payload
    }

    /// Stops capture/target/bubble callbacks after the current callback.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: propagation stops.
    public func stopPropagation() { isPropagationStopped = true }

    /// Prevents the default action for this event.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: default is prevented.
    public func preventDefault() { isDefaultPrevented = true }

    fileprivate func setPhase(_ phase: EventPhase) { self.phase = phase }
}

/// Result of one event dispatch.
/// Ownership: the result is copied by the caller. Isolation: MainActor. Errors: none. Cancellation:
/// flags describe propagation and default cancellation.
@MainActor
public struct EventResult: Sendable, Hashable {
    public let propagationStopped: Bool
    public let defaultPrevented: Bool

    fileprivate init(event: Event) {
        propagationStopped = event.isPropagationStopped
        defaultPrevented = event.isDefaultPrevented
    }
}

/// Performs capture, target and bubble dispatch through a Node ancestry snapshot.
/// Ownership: the dispatcher owns no nodes. Isolation: MainActor. Errors: missing targets are ignored.
/// Cancellation: a stopped event does not call later phases.
@MainActor
public final class EventDispatcher {
    /// Creates an empty dispatcher.
    /// Ownership: no graph is retained. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}

    /// Dispatches an event to a target and its current ancestor chain.
    /// Ownership: the event is borrowed for the duration of dispatch. Isolation: MainActor.
    /// Errors: invalid ancestry is skipped. Cancellation: event flags control continuation.
    @discardableResult
    public func dispatch(_ event: Event, target: Node) -> EventResult {
        var ancestry: [Node] = []
        var current: Node? = target
        while let node = current {
            ancestry.append(node)
            current = node.supernode
        }
        ancestry.reverse()

        for node in ancestry.dropLast() {
            guard !event.isPropagationStopped else { break }
            event.setPhase(.capturing)
            node.handleCapture(event)
        }
        if !event.isPropagationStopped {
            event.setPhase(.atTarget)
            target.handleEvent(event)
        }
        if !event.isPropagationStopped {
            for node in ancestry.dropLast().reversed() {
                guard !event.isPropagationStopped else { break }
                event.setPhase(.bubbling)
                node.handleBubble(event)
            }
        }
        return EventResult(event: event)
    }

    /// Resolves a pointer target from capture or committed hit testing, then dispatches it.
    /// Ownership: the event is borrowed and nodes remain owned by the tree. Isolation: MainActor.
    /// Errors: an event with no live target returns nil. Cancellation: pointer up/cancel releases capture.
    @discardableResult
    public func dispatch(
        _ event: Event,
        root: Node,
        captureStore: PointerCaptureStore
    ) -> EventResult? {
        let target: Node?
        if case .pointer(let data) = event.payload {
            switch event.type {
            case .pointerDown:
                target = HitTester.hitTest(point: data.point, root: root)
            case .pointerMove, .pointerUp, .pointerCancel:
                let captured = captureStore.target(
                    pointerID: data.pointerID,
                    windowID: data.windowID
                )
                target = captured ?? HitTester.hitTest(point: data.point, root: root)
            default:
                target = HitTester.hitTest(point: data.point, root: root)
            }
            guard let target else { return nil }
            let result = dispatch(event, target: target)
            if event.type == .pointerUp || event.type == .pointerCancel {
                _ = captureStore.release(pointerID: data.pointerID, windowID: data.windowID)
            }
            return result
        }
        guard let target = HitTester.hitTest(point: LayoutPoint(x: 0, y: 0), root: root) else {
            return nil
        }
        return dispatch(event, target: target)
    }
}

/// Reasons that terminate a pointer session and release its capture.
/// Ownership: the value is copied by the session owner. Isolation: none. Errors: none.
/// Cancellation: every case represents cancellation rather than activation.
public enum PointerCancelReason: Sendable, Hashable {
    case pointerCancelled
    case targetRemoved
    case windowInactive
    case modalExcluded
    case arbitrationLost
}

/// MainActor-owned pointer capture sessions keyed by window and pointer identity.
/// Ownership: the store weakly references captured Nodes. Isolation: MainActor. Errors: invalid
/// or disposed targets are rejected. Cancellation: release/cancel removes a session exactly once.
@MainActor
public final class PointerCaptureStore {
    private struct Key: Hashable {
        let pointerID: UInt64
        let windowID: UUID
    }

    private final class Entry {
        weak var target: Node?
        init(target: Node) { self.target = target }
    }

    private var captures: [Key: Entry] = [:]

    /// Creates an empty capture store.
    /// Ownership: no nodes are retained. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}

    /// Captures one pointer for one window and target.
    /// Ownership: the target is weakly referenced. Isolation: MainActor. Errors: disposed targets
    /// are rejected. Cancellation: a previous capture for the same key is replaced deterministically.
    @discardableResult
    public func capture(
        pointerID: UInt64,
        windowID: UUID,
        target: Node
    ) -> Bool {
        guard target.lifecycleState != .disposed else { return false }
        captures[Key(pointerID: pointerID, windowID: windowID)] = Entry(target: target)
        return true
    }

    /// Returns the live target captured by a pointer session.
    /// Ownership: the node is borrowed. Isolation: MainActor. Errors: stale entries are removed.
    /// Cancellation: a missing target means the session is no longer valid.
    public func target(pointerID: UInt64, windowID: UUID) -> Node? {
        let key = Key(pointerID: pointerID, windowID: windowID)
        guard let target = captures[key]?.target else {
            captures.removeValue(forKey: key)
            return nil
        }
        guard target.lifecycleState != .disposed else {
            captures.removeValue(forKey: key)
            return nil
        }
        return target
    }

    /// Releases one capture without delivering an activation.
    /// Ownership: the store releases its weak entry. Isolation: MainActor. Errors: idempotent.
    /// Cancellation: none.
    @discardableResult
    public func release(pointerID: UInt64, windowID: UUID) -> Node? {
        captures.removeValue(forKey: Key(pointerID: pointerID, windowID: windowID))?.target
    }

    /// Cancels one capture and returns its target for typed cancel dispatch.
    /// Ownership: the returned node is borrowed. Isolation: MainActor. Errors: idempotent.
    /// Cancellation: the capture is always removed.
    @discardableResult
    public func cancel(
        pointerID: UInt64,
        windowID: UUID,
        reason: PointerCancelReason
    ) -> Node? {
        release(pointerID: pointerID, windowID: windowID)
    }

    /// Cancels every capture owned by one window.
    /// Ownership: returned nodes are borrowed. Isolation: MainActor. Errors: idempotent.
    /// Cancellation: every matching session is removed once.
    @discardableResult
    public func cancelAll(windowID: UUID, reason: PointerCancelReason) -> [Node] {
        let keys = captures.keys.filter { $0.windowID == windowID }
        return keys.compactMap { release(pointerID: $0.pointerID, windowID: $0.windowID) }
    }
}

/// Performs reverse-z hit testing against committed Node frames.
/// Ownership: no node is retained. Isolation: MainActor. Errors: stale or missing frames miss.
/// Cancellation: hidden nodes are excluded.
@MainActor
public enum HitTester {
    /// Finds the frontmost visible node containing a point.
    /// Ownership: the returned node is borrowed by the caller. Isolation: MainActor. Errors: none.
    /// Cancellation: hidden nodes and nodes outside their frame are skipped.
    public static func hitTest(point: LayoutPoint, root: Node) -> Node? {
        hitTest(point: point, root: root, clip: nil)
    }

    private static func hitTest(
        point: LayoutPoint,
        root: Node,
        clip: LayoutFrame?
    ) -> Node? {
        let localPoint = root.style.visual.transform.inverseApplying(
            point,
            around: root.calculatedFrame?.origin ?? LayoutPoint(x: 0, y: 0)
        )
        guard
            contains(localPoint, in: root.calculatedFrame),
            !root.semantics.isHidden,
            root.style.visual.opacity > 0,
            contains(localPoint, in: clip)
        else {
            return nil
        }
        // A ScrollNode always clips to its own viewport at render time (native masksToBounds),
        // independent of `style.visual.overflow`, which nothing currently sets for it.
        let scrollNode = root as? ScrollNode
        let nextClip: LayoutFrame?
        if root.style.visual.overflow == .hidden || scrollNode != nil {
            nextClip = intersect(clip, root.calculatedFrame)
        } else {
            nextClip = clip
        }
        // Children of a ScrollNode are laid out in unscrolled content coordinates, while the
        // touch point is in on-screen viewport coordinates; translate by the current offset so
        // hit-testing still lands correctly once the user has scrolled away from the top.
        let childPoint: LayoutPoint
        if let scrollNode {
            childPoint = LayoutPoint(
                x: localPoint.x + scrollNode.state.offset.x,
                y: localPoint.y + scrollNode.state.offset.y
            )
        } else {
            childPoint = localPoint
        }
        let children = root.subnodes.sorted {
            if $0.style.visual.zIndex != $1.style.visual.zIndex {
                return $0.style.visual.zIndex > $1.style.visual.zIndex
            }
            return $0.id > $1.id
        }
        for child in children {
            if let hit = hitTest(point: childPoint, root: child, clip: nextClip) { return hit }
        }
        return root
    }

    private static func contains(_ point: LayoutPoint, in frame: LayoutFrame?) -> Bool {
        guard let frame else { return true }
        return point.x >= frame.origin.x && point.y >= frame.origin.y
            && point.x <= frame.origin.x + frame.width
            && point.y <= frame.origin.y + frame.height
    }

    private static func intersect(_ lhs: LayoutFrame?, _ rhs: LayoutFrame?) -> LayoutFrame? {
        guard let rhs else { return lhs }
        guard let lhs else { return rhs }
        let left = max(lhs.origin.x, rhs.origin.x)
        let top = max(lhs.origin.y, rhs.origin.y)
        let right = min(lhs.origin.x + lhs.width, rhs.origin.x + rhs.width)
        let bottom = min(lhs.origin.y + lhs.height, rhs.origin.y + rhs.height)
        return LayoutFrame(
            origin: LayoutPoint(x: left, y: top),
            width: max(0, right - left),
            height: max(0, bottom - top)
        )
    }
}
