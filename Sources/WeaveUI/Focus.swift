public import Flux

/// Direction used by keyboard, remote and directional focus navigation.
/// Ownership: the value is copied by FocusTree. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FocusDirection: Sendable, Hashable {
    case up, down, left, right, forward, backward
}

/// Focus participation and explicit directional overrides for one node.
/// Ownership: immutable value copied by FocusTree. Isolation: none. Errors: invalid IDs are ignored.
/// Cancellation: not applicable.
public struct FocusableSpec: Sendable, Hashable {
    public let isFocusable: Bool
    public let priority: Int
    public let preferredNextFocus: [FocusDirection: ElementID]

    /// Creates focus metadata.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        isFocusable: Bool = true,
        priority: Int = 0,
        preferredNextFocus: [FocusDirection: ElementID] = [:]
    ) {
        self.isFocusable = isFocusable
        self.priority = priority
        self.preferredNextFocus = preferredNextFocus
    }
}

/// Immutable focus transition output.
/// Ownership: the value is copied by Flux subscribers. Isolation: none. Errors: none. Cancellation: not applicable.
public struct FocusChange: Sendable, Hashable {
    public let previous: ElementID?
    public let next: ElementID?

    /// Creates a focus transition.
    /// Ownership: IDs are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(previous: ElementID?, next: ElementID?) {
        self.previous = previous
        self.next = next
    }
}

/// Debug trace of one directional candidate search.
/// Ownership: the trace is an immutable diagnostic snapshot. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FocusTrace: Sendable, Hashable {
    public let direction: FocusDirection
    public let candidates: [ElementID]
    public let selected: ElementID?

    /// Creates a candidate trace.
    /// Ownership: arrays are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(direction: FocusDirection, candidates: [ElementID], selected: ElementID?) {
        self.direction = direction
        self.candidates = candidates
        self.selected = selected
    }
}

/// MainActor focus registry and deterministic directional navigation engine.
/// Ownership: the tree weakly references Nodes and owns its Flux output. Isolation: MainActor.
/// Errors: stale or hidden targets are ignored. Cancellation: unregister/reset removes focus state.
@MainActor
public final class FocusTree {
    private struct Entry {
        weak var node: Node?
        let spec: FocusableSpec
    }

    private var entries: [ElementID: Entry] = [:]
    private let changesPipe = Pipe<FocusChange>(bufferingPolicy: .bufferingNewest(32))
    private let dispatcher: EventDispatcher
    public private(set) var focusedNode: Node?
    public private(set) var lastTrace: FocusTrace?
    private weak var modalRoot: Node?
    private weak var focusBeforeModal: Node?

    /// Creates an empty focus tree.
    /// Ownership: the tree owns registry metadata and dispatcher. Isolation: MainActor. Errors: none.
    /// Cancellation: no work starts during initialization.
    public init(dispatcher: EventDispatcher = EventDispatcher()) {
        self.dispatcher = dispatcher
    }

    /// Stream of immutable focus transitions.
    public var focusChanges: Flux<FocusChange> { changesPipe.flux }

    /// Limits focus traversal to a modal subtree and restores the prior valid focus when dismissed.
    /// Ownership: roots are weakly referenced. Isolation: MainActor. Errors: a detached modal root
    /// with no eligible descendants clears focus. Cancellation: nil ends the modal scope immediately.
    public func setModalRoot(_ node: Node?) {
        if let node {
            if modalRoot == nil { focusBeforeModal = focusedNode }
            modalRoot = node
            if let focusedNode, isDescendantOrSame(focusedNode, of: node) { return }
            setFocus(validEntries().sorted(by: fallbackOrder).first?.node)
            return
        }

        modalRoot = nil
        if let previous = focusBeforeModal, isEligible(previous) {
            setFocus(previous)
        } else if focusedNode == nil {
            setFocus(validEntries().sorted(by: fallbackOrder).first?.node)
        } else if let focusedNode, !isEligible(focusedNode) {
            setFocus(validEntries().sorted(by: fallbackOrder).first?.node)
        }
        focusBeforeModal = nil
    }

    /// Registers or replaces a node's focus metadata.
    /// Ownership: the node is weakly referenced. Isolation: MainActor. Errors: disposed nodes are ignored.
    /// Cancellation: replacing registration does not cancel focus unless the node becomes invalid.
    public func register(_ node: Node, focusable: FocusableSpec) {
        guard node.lifecycleState != .disposed else { return }
        entries[node.id] = Entry(node: node, spec: focusable)
    }

    /// Removes a node and restores focus to the next valid registered candidate when needed.
    /// Ownership: the tree releases its weak entry. Isolation: MainActor. Errors: idempotent.
    /// Cancellation: active focus is cancelled once when its node disappears.
    public func unregister(_ node: Node) {
        entries.removeValue(forKey: node.id)
        guard focusedNode === node else { return }
        focusedNode = nil
        let fallback = validEntries().sorted(by: fallbackOrder).first?.node
        setFocus(fallback)
    }

    /// Moves focus to a valid registered target.
    /// Ownership: the target is borrowed. Isolation: MainActor. Errors: hidden, disabled or unknown
    /// targets return false. Cancellation: prior focus receives focusOut synchronously.
    @discardableResult
    public func moveFocus(to node: Node) -> Bool {
        guard isEligible(node) else { return false }
        setFocus(node)
        return true
    }

    /// Finds and moves focus using committed geometry or an explicit override.
    /// Ownership: no candidate escapes the tree. Isolation: MainActor. Errors: no candidate returns false.
    /// Cancellation: current focus remains unchanged when navigation fails.
    @discardableResult
    public func moveFocus(direction: FocusDirection) -> Bool {
        guard let current = focusedNode, let currentFrame = current.calculatedFrame else {
            let first = validEntries().sorted(by: fallbackOrder).first?.node
            setFocus(first)
            return first != nil
        }
        let candidates = validEntries().filter { $0.node !== current }
        if let preferredID = entries[current.id]?.spec.preferredNextFocus[direction],
            let preferred = entries[preferredID]?.node,
            isEligible(preferred)
        {
            let candidateIDs = candidates.compactMap { $0.node?.id }
            lastTrace = FocusTrace(
                direction: direction,
                candidates: candidateIDs,
                selected: preferred.id
            )
            setFocus(preferred)
            return true
        }
        let scored = candidates.compactMap { entry -> (Node, Double)? in
            guard let node = entry.node, let frame = node.calculatedFrame else { return nil }
            let score = directionalScore(from: currentFrame, to: frame, direction: direction)
            return score.map { (node, $0 - Double(entry.spec.priority) * 0.001) }
        }.sorted { $0.1 < $1.1 }
        let candidateIDs = scored.map { $0.0.id }
        let selected = scored.first?.0
        lastTrace = FocusTrace(
            direction: direction,
            candidates: candidateIDs,
            selected: selected?.id
        )
        guard let selected else { return false }
        setFocus(selected)
        return true
    }

    private func setFocus(_ node: Node?) {
        guard node?.id != focusedNode?.id else { return }
        let previous = focusedNode
        if let previous {
            let event = Event(type: .focusOut, targetID: previous.id)
            _ = dispatcher.dispatch(event, target: previous)
        }
        focusedNode = node
        if let node {
            let event = Event(type: .focusIn, targetID: node.id)
            _ = dispatcher.dispatch(event, target: node)
        }
        _ = changesPipe.sendObservingOverflow(FocusChange(previous: previous?.id, next: node?.id))
    }

    private func validEntries() -> [Entry] {
        entries.values.filter { entry in
            guard let node = entry.node else { return false }
            return isEligible(node)
        }
    }

    private func isEligible(_ node: Node) -> Bool {
        guard let entry = entries[node.id], entry.spec.isFocusable else { return false }
        guard node.lifecycleState != .disposed && !node.semantics.isHidden else { return false }
        guard let modalRoot else { return true }
        return isDescendantOrSame(node, of: modalRoot)
    }

    private func isDescendantOrSame(_ node: Node, of root: Node) -> Bool {
        var current: Node? = node
        while let value = current {
            if value === root { return true }
            current = value.supernode
        }
        return false
    }

    private func fallbackOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.spec.priority != rhs.spec.priority { return lhs.spec.priority > rhs.spec.priority }
        return (lhs.node?.id ?? 0) < (rhs.node?.id ?? 0)
    }

    private func directionalScore(
        from source: LayoutFrame,
        to destination: LayoutFrame,
        direction: FocusDirection
    ) -> Double? {
        let sourceCenter = LayoutPoint(
            x: source.origin.x + source.width / 2,
            y: source.origin.y + source.height / 2
        )
        let destinationCenter = LayoutPoint(
            x: destination.origin.x + destination.width / 2,
            y: destination.origin.y + destination.height / 2
        )
        let dx = destinationCenter.x - sourceCenter.x
        let dy = destinationCenter.y - sourceCenter.y
        switch direction {
        case .up where dy >= 0, .down where dy <= 0, .left where dx >= 0, .right where dx <= 0:
            return nil
        case .forward, .backward:
            return abs(dx) + abs(dy) + (direction == .backward ? 0.001 : 0)
        default:
            break
        }
        let primary: Double
        let secondary: Double
        switch direction {
        case .up, .down:
            primary = abs(dy)
            secondary = abs(dx)
        case .left, .right:
            primary = abs(dx)
            secondary = abs(dy)
        case .forward, .backward:
            primary = abs(dx) + abs(dy)
            secondary = 0
        }
        return primary + secondary * 0.5
    }
}
