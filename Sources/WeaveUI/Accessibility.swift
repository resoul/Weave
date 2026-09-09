import Foundation

/// Standard semantic role exposed to assistive technologies.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityRole: Sendable, Hashable {
    case button, checkbox, image, header, link, text, adjustable, slider, searchField, group
}

/// Semantic traits independent from directional FocusTree state.
/// Ownership: immutable option set. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityTrait: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public static let selected = Self(rawValue: 1 << 0)
    public static let disabled = Self(rawValue: 1 << 1)
    public static let heading = Self(rawValue: 1 << 2)
    public static let button = Self(rawValue: 1 << 3)
    public static let adjustable = Self(rawValue: 1 << 4)

    /// Creates traits from a stable raw representation.
    /// Ownership: the value is copied. Isolation: none. Errors: unknown bits are retained.
    /// Cancellation: not applicable.
    public init(rawValue: UInt16) { self.rawValue = rawValue }
}

/// Grouping policy for semantic descendants.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityChildrenPolicy: Sendable, Hashable {
    case contain, combine, ignoreSelf, hide
}

/// Supported standard and custom accessibility actions.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AccessibilityAction: Sendable, Hashable {
    case activate, increment, decrement, custom(String)
}

/// Current semantic state of one accessibility element.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityState: Sendable, Hashable {
    public let isEnabled: Bool
    public let isSelected: Bool
    public let value: String?

    /// Creates semantic state.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(isEnabled: Bool = true, isSelected: Bool = false, value: String? = nil) {
        self.isEnabled = isEnabled
        self.isSelected = isSelected
        self.value = value
    }
}

/// Declarative accessibility properties stored independently from FocusTree and rendering.
/// Ownership: immutable value owned by its Node. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityProperties: Sendable, Hashable {
    public let isElement: Bool
    public let label: String?
    public let value: String?
    public let hint: String?
    public let traits: AccessibilityTrait
    public let role: AccessibilityRole?
    public let identifier: String?
    public let sortPriority: Double
    public let childrenPolicy: AccessibilityChildrenPolicy
    public let actions: [AccessibilityAction]
    public let state: AccessibilityState

    /// Creates semantic properties.
    /// Ownership: strings and arrays are copied. Isolation: none. Errors: non-finite priority uses zero.
    /// Cancellation: not applicable.
    public init(
        isElement: Bool = false,
        label: String? = nil,
        value: String? = nil,
        hint: String? = nil,
        traits: AccessibilityTrait = [],
        role: AccessibilityRole? = nil,
        identifier: String? = nil,
        sortPriority: Double = 0,
        childrenPolicy: AccessibilityChildrenPolicy = .contain,
        actions: [AccessibilityAction] = [],
        state: AccessibilityState = AccessibilityState()
    ) {
        self.isElement = isElement
        self.label = label
        self.value = value
        self.hint = hint
        self.traits = traits
        self.role = role
        self.identifier = identifier
        self.sortPriority = sortPriority.isFinite ? sortPriority : 0
        self.childrenPolicy = childrenPolicy
        self.actions = actions
        self.state = state
    }
}

/// Invocation emitted when an accessibility action is requested.
/// Ownership: immutable event snapshot. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilityActionInvocation: Sendable, Hashable {
    public let nodeID: ElementID
    public let action: AccessibilityAction

    /// Creates an action invocation.
    /// Ownership: IDs and action are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(nodeID: ElementID, action: AccessibilityAction) {
        self.nodeID = nodeID
        self.action = action
    }
}

/// Immutable semantic element snapshot consumed by platform bridges.
/// Ownership: the snapshot owns all semantic values and child snapshots. Isolation: none.
/// Errors: stale frames are omitted. Cancellation: not applicable.
public struct AccessibilityElementSnapshot: Sendable, Hashable {
    public let nodeID: ElementID
    public let frame: LayoutFrame
    public let properties: AccessibilityProperties
    public let children: [AccessibilityElementSnapshot]

    /// Creates an element snapshot.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        frame: LayoutFrame,
        properties: AccessibilityProperties,
        children: [AccessibilityElementSnapshot] = []
    ) {
        self.nodeID = nodeID
        self.frame = frame
        self.properties = properties
        self.children = children
    }
}

/// Atomic committed semantic snapshot with explicit reading order and layout revision.
/// Ownership: the snapshot owns its immutable tree. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AccessibilitySnapshot: Sendable, Hashable {
    public let revision: UInt64
    public let root: AccessibilityElementSnapshot?
    public let readingOrder: [ElementID]

    /// Creates an accessibility snapshot.
    /// Ownership: the snapshot owns its tree and order. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(revision: UInt64, root: AccessibilityElementSnapshot?, readingOrder: [ElementID]) {
        self.revision = revision
        self.root = root
        self.readingOrder = readingOrder
    }
}

/// Adapter boundary for publishing one committed semantic snapshot to assistive technology.
/// Ownership: a bridge retains the latest snapshot only. Isolation: MainActor. Errors: platform
/// notification failures are handled by the adapter. Cancellation: applying a newer snapshot replaces the old one.
@MainActor
public protocol AccessibilityBridge: AnyObject {
    func apply(_ snapshot: AccessibilitySnapshot)
}

/// Headless accessibility tree and modal exposure boundary.
/// Ownership: the tree weakly references Nodes and owns the latest immutable snapshot. Isolation:
/// MainActor. Errors: stale or hidden nodes are omitted. Cancellation: rebuild replaces one snapshot atomically.
@MainActor
public final class AccessibilityTree {
    public private(set) var snapshot = AccessibilitySnapshot(
        revision: 0,
        root: nil,
        readingOrder: []
    )
    private weak var modalRoot: Node?

    /// Creates an empty accessibility tree.
    /// Ownership: no Nodes are retained. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}

    /// Temporarily limits semantic exposure to one modal subtree without changing Node properties.
    /// Ownership: the root is weakly referenced. Isolation: MainActor. Errors: nil restores the full tree.
    /// Cancellation: rebuilding after change publishes one replacement snapshot.
    public func setModalRoot(_ node: Node?) { modalRoot = node }

    /// Builds and atomically publishes semantics from committed Node frames.
    /// Ownership: the returned snapshot is copied by the caller. Isolation: MainActor. Errors: nodes
    /// without committed frames are excluded. Cancellation: no asynchronous work is started.
    @discardableResult
    public func rebuild(root: Node, revision: UInt64) -> AccessibilitySnapshot {
        let semanticRoot: Node
        if let modalRoot, isDescendantOrSame(modalRoot, of: root) {
            semanticRoot = modalRoot
        } else {
            semanticRoot = root
        }
        let built = build(semanticRoot)
        var order: [ElementID] = []
        appendReadingOrder(built, to: &order)
        let next = AccessibilitySnapshot(revision: revision, root: built, readingOrder: order)
        snapshot = next
        return next
    }

    private func build(_ node: Node) -> AccessibilityElementSnapshot? {
        guard !node.semantics.isHidden, let frame = node.calculatedFrame else { return nil }
        let properties = node.accessibility
        guard properties.childrenPolicy != .hide else { return nil }
        let children = node.subnodes.compactMap(build)
        switch properties.childrenPolicy {
        case .contain:
            guard properties.isElement || !children.isEmpty else { return nil }
            return AccessibilityElementSnapshot(
                nodeID: node.id,
                frame: frame,
                properties: properties,
                children: children
            )
        case .combine:
            guard properties.isElement || !children.isEmpty else { return nil }
            return AccessibilityElementSnapshot(
                nodeID: node.id,
                frame: frame,
                properties: properties,
                children: children
            )
        case .ignoreSelf:
            guard !children.isEmpty else { return nil }
            return AccessibilityElementSnapshot(
                nodeID: node.id,
                frame: frame,
                properties: properties,
                children: children
            )
        case .hide:
            return nil
        }
    }

    private func appendReadingOrder(
        _ element: AccessibilityElementSnapshot?,
        to order: inout [ElementID]
    ) {
        guard let element else { return }
        if element.properties.isElement { order.append(element.nodeID) }
        let children = element.children.sorted {
            if $0.properties.sortPriority != $1.properties.sortPriority {
                return $0.properties.sortPriority > $1.properties.sortPriority
            }
            return $0.nodeID < $1.nodeID
        }
        for child in children { appendReadingOrder(child, to: &order) }
    }

    private func isDescendantOrSame(_ node: Node, of root: Node) -> Bool {
        var current: Node? = node
        while let value = current {
            if value === root { return true }
            current = value.supernode
        }
        return false
    }
}
