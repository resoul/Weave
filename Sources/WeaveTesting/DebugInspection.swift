import WeaveUI

/// Immutable inspection record for one logical node.
/// Ownership: record owns copied diagnostics. Isolation: none. Errors: absent frame is nil. Cancellation: not applicable.
public struct DebugNodeSnapshot: Sendable, Hashable {
    public let identity: ElementID
    public let frame: LayoutFrame?
    public let layoutRevision: UInt64
    public let displayRevision: UInt64
    public let accessibilityRevision: UInt64
    public let semantics: NodeSemantics
    public let isFocused: Bool

    /// Creates an inspection record.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    @MainActor
    public init(node: Node, isFocused: Bool = false) {
        identity = node.id
        frame = node.calculatedFrame
        layoutRevision = node.layoutRevision
        displayRevision = node.displayRevision
        accessibilityRevision = node.accessibilityRevision
        semantics = node.semantics
        self.isFocused = isFocused
    }
}

/// MainActor-owned, non-interactive debug inspector.
/// Ownership: inspector returns immutable snapshots and never retains Nodes. Isolation: MainActor. Errors: disposed nodes are still reported as records. Cancellation: no work starts.
@MainActor
public struct DebugInspector {
    /// Creates an inspector that cannot intercept application input.
    /// Ownership: stateless value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Inspects a committed logical tree and optional focus state.
    /// Ownership: returned array owns copied records. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func inspect(root: Node, focusTree: FocusTree? = nil) -> [DebugNodeSnapshot] {
        func walk(_ node: Node) -> [DebugNodeSnapshot] {
            [DebugNodeSnapshot(node: node, isFocused: focusTree?.focusedNode?.id == node.id)]
                + node.subnodes.flatMap(walk)
        }
        return walk(root)
    }
}
