/// Runtime identity of one Node instance.
///
/// Ownership: the value is immutable and owned by its Node. Isolation: MainActor when allocated.
/// Errors: none. Cancellation: not applicable.
public typealias ElementID = UInt64

/// Minimal immutable composition description used before the full builder/DSL exists.
///
/// Ownership: content values are copied by the composing Node. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum NodeContent: Sendable, Hashable {
    case empty
    case children([NodeDescriptor])
}

/// Platform-neutral child description for a future builder or reconciler.
///
/// Ownership: the descriptor is an immutable value owned by its caller. Isolation: none. Errors:
/// none. Cancellation: not applicable.
public struct NodeDescriptor: Sendable, Hashable {
    public let typeName: String
    public let key: String?

    /// Creates a descriptor without allocating a Node or platform object.
    ///
    /// Ownership: the returned descriptor owns copied strings. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(typeName: String, key: String? = nil) {
        self.typeName = typeName
        self.key = key
    }
}

/// Baseline semantic information kept separate from rendering and focus trees.
///
/// Ownership: the value is immutable until replaced by its MainActor owner. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public struct NodeSemantics: Sendable, Hashable {
    public let label: String?
    public let isHidden: Bool

    /// Creates semantic properties.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(label: String? = nil, isHidden: Bool = false) {
        self.label = label
        self.isHidden = isHidden
    }
}

/// Focus eligibility used by the future FocusTree adapter.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum FocusEligibility: Sendable, Hashable {
    case automatic
    case eligible
    case excluded
}

public import Flux

/// MainActor-owned logical UI node with no platform allocation during construction or composition.
///
/// Ownership: the node owns its child array and environment scope. Isolation: MainActor. Errors:
/// invalid hierarchy operations are ignored. Cancellation: disposal cancels lifecycle-owned work.
@MainActor
open class Node {
    private static var nextID: ElementID = 0

    /// Stable runtime identity for the lifetime of this node.
    public let id: ElementID
    /// Mutable layout style owned by the MainActor node.
    public var style: LayoutStyle {
        didSet { setNeedsLayout() }
    }
    var safeAreaBoundary = false
    var safeAreaIgnoredEdges: SafeAreaEdges = .none
    /// Paint-only presentation properties owned by the MainActor node.
    public var appearance = VisualStyle() {
        didSet { setNeedsVisualStyleUpdate() }
    }
    /// Current calculated frame after a layout result is applied.
    public private(set) var calculatedFrame: LayoutFrame?
    /// Semantic properties independent from rendering.
    public var semantics = NodeSemantics()
    /// Declarative accessibility properties independent from FocusTree and rendering.
    public var accessibility = AccessibilityProperties() {
        didSet { setNeedsAccessibilityUpdate() }
    }
    /// Focus eligibility independent from accessibility and rendering.
    public var focusEligibility: FocusEligibility = .automatic
    /// Optional directional focus metadata; nil excludes the node from FocusTree registration.
    open var focusable: FocusableSpec? { nil }
    /// Whether a platform backing object has been materialized by an adapter.
    public private(set) var isLoaded = false
    /// Number of layout invalidations requested by this node.
    public private(set) var layoutRevision: UInt64 = 0
    /// Number of display invalidations requested by this node.
    public private(set) var displayRevision: UInt64 = 0
    /// Number of paint-only presentation invalidations requested by this node.
    public private(set) var appearanceRevision: UInt64 = 0
    /// Number of accessibility invalidations requested by this node.
    public private(set) var accessibilityRevision: UInt64 = 0

    private weak var parent: Node?
    private var children: [Node] = []
    /// Last committed immutable descriptor used to reconcile this runtime node.
    /// Ownership: the MainActor node owns the snapshot. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public internal(set) var reconciliationDescriptor: NodeDescriptor?
    private let scope: EnvironmentScope
    private let lifecycle: LifecycleMachine
    private var backing: (any NodeBacking)?
    private let subscriptions = SubscriptionBag()
    private let accessibilityActionsPipe = Pipe<AccessibilityActionInvocation>(
        bufferingPolicy: .bufferingNewest(32)
    )

    /// Creates a node with dependencies only; no lifecycle effect or platform allocation runs here.
    ///
    /// Ownership: the node owns its style, scope and lifecycle machine. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public init(style: LayoutStyle = LayoutStyle(), environment: EnvironmentScope? = nil) {
        Self.nextID &+= 1
        id = Self.nextID
        self.style = style
        if let environment {
            scope = EnvironmentScope(parent: environment)
        } else {
            scope = EnvironmentScope()
        }
        lifecycle = LifecycleMachine()
    }

    /// Returns the logical parent, if attached.
    public var supernode: Node? { parent }
    /// Returns the root ancestor of this subtree, or self if this is the root.
    public var rootNode: Node {
        var current = self
        while let next = current.parent {
            current = next
        }
        return current
    }
    /// Returns a stable copy of the current child list.
    public var subnodes: [Node] { children }
    /// Returns effective environment values for this node's scope.
    public var environment: EnvironmentValues { scope.snapshot.values }

    /// Returns an immutable snapshot of this node's effective environment and revision.
    /// Ownership: the snapshot is returned by value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var environmentSnapshot: EnvironmentSnapshot { scope.snapshot }

    /// Attaches an inherited environment parent while retaining this node's overrides.
    /// Ownership: the node keeps a weak parent scope. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func inheritEnvironment(from parent: EnvironmentScope) {
        scope.reparent(to: parent)
    }
    /// Returns the current lifecycle state.
    public var lifecycleState: LifecycleState { lifecycle.state }

    /// Returns the minimal composition description for this node.
    ///
    /// Ownership: the returned descriptor is owned by the caller. Isolation: MainActor. Errors:
    /// none. Cancellation: not applicable.
    open func compose() -> NodeContent { .empty }

    /// Supplies immutable intrinsic metrics to the framework layout snapshot.
    /// Ownership: the returned value is copied into a Sendable snapshot. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    open var layoutContentMetrics: LayoutContentMetrics { LayoutContentMetrics() }

    /// Supplies immutable content metrics for a parent-provided constraint.
    /// The default preserves intrinsic metrics. Ownership: the result is copied into a Sendable
    /// snapshot. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func layoutContentMetrics(for constraint: SizeConstraint) -> LayoutContentMetrics {
        layoutContentMetrics
    }

    /// Captures this live tree as immutable input for a layout worker.
    /// Ownership: the snapshot owns copied styles, metrics and child snapshots. Isolation:
    /// MainActor. Errors: none. Cancellation: the caller owns any worker using the result.
    public func makeLayoutInputSnapshot(
        constraint: SizeConstraint = SizeConstraint()
    ) -> LayoutInputSnapshot {
        makeLayoutInputSnapshot(constraint: constraint, isRoot: true)
    }

    private func makeLayoutInputSnapshot(
        constraint: SizeConstraint,
        isRoot: Bool
    ) -> LayoutInputSnapshot {
        let environmentSnapshot = scope.snapshot
        let parentWidth: Double? =
            switch constraint.width {
            case let .atMost(value), let .exact(value):
                value
            case .unspecified:
                nil
            }
        let parentHeight: Double? =
            switch constraint.height {
            case let .atMost(value), let .exact(value):
                value
            case .unspecified:
                nil
            }
        let contentConstraint = SizeConstraint(
            width: style.width.resolved(parent: parentWidth).map { .exact($0) } ?? constraint.width,
            height: style.height.resolved(parent: parentHeight).map { .exact($0) }
                ?? constraint.height
        )
        var snapshotStyle = style
        if isRoot || safeAreaBoundary {
            let safe = environmentSnapshot.values.safeAreaInsets
            let ignored = safeAreaIgnoredEdges
            var draft = LayoutStyle.Draft(style)
            draft.padding = DirectionalEdgeInsets(
                top: style.padding.top + (ignored.contains(.top) ? 0 : safe.top),
                leading: style.padding.leading + (ignored.contains(.leading) ? 0 : safe.leading),
                bottom: style.padding.bottom + (ignored.contains(.bottom) ? 0 : safe.bottom),
                trailing: style.padding.trailing + (ignored.contains(.trailing) ? 0 : safe.trailing)
            )
            snapshotStyle = LayoutStyle.bake(draft)
        }
        return LayoutInputSnapshot(
            identity: id,
            style: snapshotStyle,
            content: layoutContentMetrics(for: contentConstraint),
            children: children.map {
                $0.makeLayoutInputSnapshot(constraint: constraint, isRoot: false)
            },
            direction: environmentSnapshot.values.layoutDirection,
            environmentRevision: environmentSnapshot.revision,
            contentRevision: max(layoutRevision, displayRevision)
        )
    }

    /// Called synchronously on MainActor after layout placement is applied to this node and its subtree.
    /// Ownership: result is borrowed. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func didApplyLayoutResult(_ result: LayoutResult) {}

    /// Applies one coherent layout result throughout the current logical subtree.
    /// Ownership: each node copies only its own placement. Isolation: MainActor. Errors:
    /// placements absent from the result are ignored. Cancellation: stale-result rejection belongs
    /// to the host that owns the layout generation.
    public func applyRecursively(_ result: LayoutResult) {
        apply(result)
        children.forEach { $0.applyRecursively(result) }
        didApplyLayoutResult(result)
    }

    /// Handles capture-phase events before the target callback.
    /// Ownership: the event is borrowed during synchronous dispatch. Isolation: MainActor.
    /// Errors: none. Cancellation: call `stopPropagation()` to stop later callbacks.
    open func handleCapture(_ event: Event) {}

    /// Handles an event targeted at this node.
    /// Ownership: the event is borrowed during synchronous dispatch. Isolation: MainActor.
    /// Errors: none. Cancellation: call `stopPropagation()` to stop bubbling.
    open func handleEvent(_ event: Event) {}

    /// Handles bubble-phase events after the target callback.
    /// Ownership: the event is borrowed during synchronous dispatch. Isolation: MainActor.
    /// Errors: none. Cancellation: call `stopPropagation()` to stop later callbacks.
    open func handleBubble(_ event: Event) {}

    /// Called once when this node enters a committed scroll viewport.
    /// Ownership: the context is borrowed for the synchronous callback. Isolation: MainActor. Errors: callback failures are isolated to the node. Cancellation: leaving the viewport invalidates the visibility generation.
    open func enteredViewport(_ context: VisibilityContext) {}

    /// Called once when this node leaves a committed scroll viewport.
    /// Ownership: the context is borrowed for the synchronous callback. Isolation: MainActor. Errors: callback failures are isolated to the node. Cancellation: pending viewport work must stop at the owner boundary.
    open func leftViewport(_ context: VisibilityContext) {}

    /// Adds a child and reparents it atomically, rejecting self/cycle insertion.
    ///
    /// Ownership: this node owns the child relationship; the child remains caller-owned otherwise.
    /// Isolation: MainActor. Errors: self and ancestor cycles are ignored. Cancellation: none.
    public func addSubnode(_ node: Node) {
        guard node !== self, !isDescendant(of: node), node.parent !== self else { return }
        node.removeFromSupernode()
        children.append(node)
        node.parent = self
        node.scope.reparent(to: scope)
        setNeedsLayout()
    }

    /// Removes this node from its parent without disposing it.
    ///
    /// Ownership: the previous parent releases the child relationship. Isolation: MainActor.
    /// Errors: none. Cancellation: no lifecycle work is cancelled by reparent alone.
    public func removeFromSupernode() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        self.parent = nil
        scope.reparent(to: nil)
        parent.setNeedsLayout()
    }

    /// Finds a descendant node by its runtime ElementID.
    /// Ownership: the node is borrowed. Isolation: MainActor. Errors: returns nil if not found. Cancellation: not applicable.
    public func findNode(id targetID: ElementID) -> Node? {
        if id == targetID { return self }
        for child in children {
            if let found = child.findNode(id: targetID) {
                return found
            }
        }
        return nil
    }

    /// Callback triggered when this node or any of its descendants requests layout or display invalidation.
    /// Ownership: callback closure is owned by the host/adapter. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onInvalidate: (@MainActor (Node) -> Void)?

    /// Callback for paint-only presentation invalidation routed by a mounted host.
    /// Ownership: the callback is owned by the host. Isolation: MainActor. Errors: none.
    /// Cancellation: the host clears it during detach/unmount.
    public var onInvalidateVisualStyle: (@MainActor (Node) -> Void)?

    /// Callback for scroll-offset commits that do not invalidate layout geometry.
    /// Ownership: the callback is owned by the mounted host. Isolation: MainActor. Errors: none.
    /// Cancellation: the host clears it during detach/unmount.
    public var onScrollStateChanged: (@MainActor (ScrollNode) -> Void)?

    /// Callback for transient edge-pull presentation updates.
    public var onEdgePullChanged: (@MainActor (ScrollNode) -> Void)?

    /// Marks geometry as invalid and advances its revision.
    ///
    /// Ownership: the revision remains owned by the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setNeedsLayout() {
        layoutRevision &+= 1
        if let parent {
            parent.setNeedsLayout()
        } else {
            onInvalidate?(self)
        }
    }

    /// Marks presentation as invalid and advances its revision.
    ///
    /// Ownership: the revision remains owned by the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setNeedsDisplay() {
        displayRevision &+= 1
        var current: Node? = parent
        while let p = current {
            p.displayRevision &+= 1
            current = p.parent
        }
        rootNode.onInvalidate?(self)
    }

    /// Marks paint-only presentation as invalid without changing layout or display revisions.
    ///
    /// Ownership: the revision remains owned by the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable. The mounted root receives the original target node.
    public func setNeedsVisualStyleUpdate() {
        appearanceRevision &+= 1
        rootNode.onInvalidateVisualStyle?(self)
    }

    /// Marks semantic accessibility data as invalid.
    /// Ownership: the revision remains owned by the node. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public func setNeedsAccessibilityUpdate() { accessibilityRevision &+= 1 }

    /// Stream of custom accessibility action requests.
    public var onAccessibilityAction: Flux<AccessibilityActionInvocation> {
        accessibilityActionsPipe.flux
    }

    /// Emits a custom accessibility action request.
    /// Ownership: the invocation is copied into bounded buffers. Isolation: MainActor. Errors:
    /// overflow is reported by the yield result. Cancellation: not applicable.
    @discardableResult
    public func emitAccessibilityAction(
        _ action: AccessibilityAction
    ) -> AsyncStream<AccessibilityActionInvocation>.Continuation.YieldResult {
        accessibilityActionsPipe.sendObservingOverflow(
            AccessibilityActionInvocation(nodeID: id, action: action)
        ).first ?? .dropped(AccessibilityActionInvocation(nodeID: id, action: action))
    }

    /// Applies a result only when it represents this node's runtime identity.
    ///
    /// Ownership: the node copies its frame from the immutable result. Isolation: MainActor.
    /// Errors: results for another tree are ignored. Cancellation: stale work is ignored by caller.
    public func apply(_ result: LayoutResult) {
        guard let placement = result.placement(for: id) else { return }
        calculatedFrame = placement.frame
    }

    /// Commits lifecycle composition and creates no platform backing.
    ///
    /// Ownership: the node owns its lifecycle scope. Isolation: MainActor. Errors: invalid state
    /// transitions return `false`. Cancellation: not applicable.
    @discardableResult
    public func connect() -> Bool {
        _ = lifecycle.transition(.compose)
        return lifecycle.transition(.connect)
    }

    /// Binds a Flux to a MainActor render callback owned by this node's connection scope.
    ///
    /// Ownership: the node owns the subscription until replacement or disposal. Isolation: MainActor
    /// for registration and callback. Errors: none. Cancellation: matching IDs cancel prior bindings.
    @discardableResult
    public func bind<Value: Sendable>(
        id: some Hashable,
        _ flux: Flux<Value>,
        update: @MainActor @escaping (Value) -> Void
    ) -> Subscription {
        let subscription = flux.sinkOnMain(update)
        subscription.store(in: subscriptions)
        lifecycle.connectionScope?.bind(id: id) { subscription.cancel() }
        return subscription
    }

    /// Disposes this node and releases owned children and effects.
    ///
    /// Ownership: the node releases its child relationships and backing handle. Isolation:
    /// MainActor. Errors: none. Cancellation: lifecycle-owned effects are cancelled.
    open func dispose() {
        children.forEach { $0.dispose() }
        children.removeAll()
        subscriptions.cancelAll()
        lifecycle.transition(.dispose)
        parent = nil
        backing = nil
    }

    private func isDescendant(of candidate: Node) -> Bool {
        var current = parent
        while let node = current {
            if node === candidate { return true }
            current = node.parent
        }
        return false
    }

    func insertReconciledChild(_ node: Node, at index: Int) {
        guard index >= 0, index <= children.count else { return }
        node.removeFromSupernode()
        children.insert(node, at: index)
        node.parent = self
        node.scope.reparent(to: scope)
    }

    func removeReconciledChild(at index: Int) -> Node? {
        guard children.indices.contains(index) else { return nil }
        let node = children.remove(at: index)
        node.parent = nil
        node.scope.reparent(to: nil)
        return node
    }

    func moveReconciledChild(from: Int, to: Int) {
        guard children.indices.contains(from), to >= 0, to <= children.count else { return }
        let node = children.remove(at: from)
        children.insert(node, at: min(to, children.count))
    }
}

protocol NodeBacking: AnyObject {}
