/// Trace emitted after a staged MainActor tree apply.
/// Ownership: the trace is an immutable value owned by the caller. Isolation: MainActor at apply.
/// Errors: stale generations are reported as discarded. Cancellation: no work is retained.
public struct NodeApplyTrace: Sendable, Hashable {
    public let generation: UInt64
    public let patchCount: Int
    public let applied: Bool
    public let discardedAsStale: Bool

    /// Creates an apply trace.
    /// Ownership: values are copied into the trace. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(generation: UInt64, patchCount: Int, applied: Bool, discardedAsStale: Bool) {
        self.generation = generation
        self.patchCount = patchCount
        self.applied = applied
        self.discardedAsStale = discardedAsStale
    }
}

/// MainActor owner of staged descriptor reconciliation for a Node parent.
/// Ownership: the controller owns generation state; the parent owns resulting child Nodes.
/// Isolation: MainActor. Errors: invalid patches are rejected before mutation. Cancellation: stale
/// generations are discarded without starting lifecycle work.
@MainActor
public final class NodeReconciliationController {
    private var latestGeneration: UInt64 = 0

    /// Creates an empty reconciliation controller.
    /// Ownership: the controller owns its generation counter. Isolation: MainActor. Errors: none.
    /// Cancellation: no work is active until `apply` is called.
    public init() {}

    /// Applies a descriptor snapshot atomically after validating its staged patches.
    /// Ownership: the factory creates Nodes owned by the parent after commit. Isolation: MainActor.
    /// Errors: malformed or stale patches return a discarded trace. Cancellation: stale generations
    /// are ignored before allocation or lifecycle effects.
    @discardableResult
    public func apply(
        to parent: Node,
        descriptors: [NodeDescriptor],
        generation: UInt64,
        factory: @MainActor (NodeDescriptor) -> Node,
        recycle: (@MainActor (Node) -> Void)? = nil
    ) -> NodeApplyTrace {
        let old = parent.subnodes.map {
            $0.reconciliationDescriptor
                ?? NodeDescriptor(typeName: String(reflecting: type(of: $0)))
        }
        let diff = Reconciler.diff(old: old, new: descriptors)
        guard generation >= latestGeneration else {
            return NodeApplyTrace(
                generation: generation,
                patchCount: diff.patches.count,
                applied: false,
                discardedAsStale: true
            )
        }
        guard Self.isApplicable(diff.patches, old: old, new: descriptors) else {
            return NodeApplyTrace(
                generation: generation,
                patchCount: diff.patches.count,
                applied: false,
                discardedAsStale: false
            )
        }
        latestGeneration = generation
        var index = 0
        for patch in diff.patches {
            switch patch {
            case let .insert(descriptor, atIndex):
                let node = factory(descriptor)
                node.reconciliationDescriptor = descriptor
                _ = node.connect()
                parent.insertReconciledChild(node, at: atIndex)
            case let .remove(_, fromIndex):
                if let removed = parent.removeReconciledChild(at: fromIndex) {
                    if let recycle { recycle(removed) } else { removed.dispose() }
                }
            case let .update(atIndex, descriptor):
                parent.subnodes[atIndex].reconciliationDescriptor = descriptor
            case let .move(_, fromIndex, toIndex):
                parent.moveReconciledChild(from: fromIndex, to: toIndex)
            case let .replace(atIndex, descriptor):
                if let removed = parent.removeReconciledChild(at: atIndex) {
                    if let recycle { recycle(removed) } else { removed.dispose() }
                }
                let node = factory(descriptor)
                node.reconciliationDescriptor = descriptor
                _ = node.connect()
                parent.insertReconciledChild(node, at: atIndex)
            }
            index += 1
        }
        if index > 0 { parent.setNeedsLayout() }
        return NodeApplyTrace(
            generation: generation,
            patchCount: index,
            applied: true,
            discardedAsStale: false
        )
    }

    private static func isApplicable(
        _ patches: [ReconciliationPatch],
        old: [NodeDescriptor],
        new: [NodeDescriptor]
    ) -> Bool {
        var values = old
        for patch in patches {
            switch patch {
            case let .insert(descriptor, index):
                guard index >= 0, index <= values.count else { return false }
                values.insert(descriptor, at: index)
            case let .remove(_, index):
                guard values.indices.contains(index) else { return false }
                values.remove(at: index)
            case let .update(index, descriptor), let .replace(index, descriptor):
                guard values.indices.contains(index) else { return false }
                values[index] = descriptor
            case let .move(_, from, to):
                guard values.indices.contains(from),
                    to >= 0,
                    to <= values.count
                else { return false }
                let descriptor = values.remove(at: from)
                values.insert(descriptor, at: min(to, values.count))
            }
        }
        return values == new
    }
}
