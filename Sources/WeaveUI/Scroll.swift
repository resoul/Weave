import Foundation

/// Axis controlled by a scroll container.
/// Ownership: the value is copied by the scroll node. Isolation: none. Errors: unsupported axes are ignored. Cancellation: not applicable.
public enum ScrollAxis: Sendable, Hashable {
    case vertical
    case horizontal
    case both
}

/// Alignment used when revealing content in a viewport.
/// Ownership: the value is copied by the command. Isolation: none. Errors: none. Cancellation: no task is started.
public enum ScrollAlignment: Sendable, Hashable {
    case nearest
    case start
    case center
    case end
}

/// Immutable scroll state committed by a ScrollNode.
/// Ownership: the snapshot is owned by its receiver. Isolation: none. Errors: values are clamped by the node. Cancellation: cancelled scrolling returns to the latest committed offset.
public struct ScrollState: Sendable, Hashable {
    public let offset: LayoutPoint
    public let contentSize: MeasuredSize
    public let viewportSize: MeasuredSize
    public let isScrolling: Bool
    public let revision: UInt64

    /// Creates a scroll state snapshot.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        offset: LayoutPoint = LayoutPoint(x: 0, y: 0),
        contentSize: MeasuredSize = MeasuredSize(width: 0, height: 0),
        viewportSize: MeasuredSize = MeasuredSize(width: 0, height: 0),
        isScrolling: Bool = false,
        revision: UInt64 = 0
    ) {
        self.offset = offset
        self.contentSize = contentSize
        self.viewportSize = viewportSize
        self.isScrolling = isScrolling
        self.revision = revision
    }
}

/// Directional scroll command consumed by a ScrollNode.
/// Ownership: the command is copied synchronously. Isolation: MainActor at application. Errors: invalid coordinates are normalized. Cancellation: cancel stops the current interaction without activation.
public enum ScrollCommand: Sendable, Hashable {
    case by(x: Double, y: Double)
    case to(LayoutPoint)
    case reveal(LayoutFrame, alignment: ScrollAlignment)
    case cancel
}

/// Edge of a scroll viewport at which a pull interaction may begin.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public enum ScrollContentEdge: Sendable, Hashable {
    case start
    case end
}

/// Action policy for an edge pull interaction.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public enum EdgePullBehavior: Sendable, Hashable {
    /// Shows only a bounded elastic effect and never emits a request.
    case elastic
    /// Emits one request after the threshold is crossed and the gesture is released.
    case action
}

/// Optional presentation and action policy for one scroll edge.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public struct EdgePullConfiguration: Sendable, Hashable {
    public let behavior: EdgePullBehavior
    public let indicator: EdgePullIndicator
    public let threshold: Double
    public let maximumDistance: Double
    public let resistance: Double
    public let holdWhileActive: Bool

    /// Creates an edge-pull configuration with normalized threshold and resistance bounds.
    /// Ownership: values are copied. Isolation: none. Errors: invalid numbers are normalized to fallbacks. Cancellation: not applicable.
    public init(
        behavior: EdgePullBehavior = .elastic,
        indicator: EdgePullIndicator = .none,
        threshold: Double = 64,
        maximumDistance: Double = 120,
        resistance: Double = 0.55,
        holdWhileActive: Bool = true
    ) {
        let normalizedThreshold = max(0, threshold.isFinite ? threshold : 64)
        let normalizedMaximum = max(
            normalizedThreshold, maximumDistance.isFinite ? maximumDistance : 120)
        self.behavior = behavior
        self.indicator = indicator
        self.threshold = normalizedThreshold
        self.maximumDistance = normalizedMaximum
        self.resistance = min(1, max(0, resistance.isFinite ? resistance : 0.55))
        self.holdWhileActive = holdWhileActive
    }
}

/// Indicator presentation independent of refresh/load semantics.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public enum EdgePullIndicator: Sendable, Hashable {
    case none
    case progress
    case activity
}

/// Committed edge-pull interaction state.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public enum EdgePullState: Sendable, Hashable {
    case idle
    case pulling(edge: ScrollContentEdge, progress: Double, distance: Double)
    case armed(edge: ScrollContentEdge, distance: Double)
    case active(edge: ScrollContentEdge)
    case settling(edge: ScrollContentEdge, distance: Double)
    case cancelled
}

/// Request emitted only by an action-mode edge pull after release.
/// Ownership: value type, copied on assignment. Isolation: none. Errors: none. Cancellation: none.
public struct EdgePullRequest: Sendable, Hashable {
    public let edge: ScrollContentEdge
    public let generation: UInt64

    /// Creates an edge-pull request snapshot.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(edge: ScrollContentEdge, generation: UInt64) {
        self.edge = edge
        self.generation = generation
    }
}

/// Internal adapter boundary for transient edge presentation.
/// Ownership: reference type, conforming instances are held by the adapter. Isolation: MainActor. Errors: none. Cancellation: interactions can be cancelled via `cancelEdgePull()`.
@MainActor
public protocol EdgePullContainer: AnyObject {
    var edgePullState: EdgePullState { get }
    var edgePullPresentationDistance: Double { get }
    func beginEdgePull(for delta: Double) -> Bool
    func updateEdgePull(delta: Double)
    func finishEdgePull()
    func cancelEdgePull()
}

/// Immutable viewport visibility callback context.
/// Ownership: the context is copied by callbacks. Isolation: none. Errors: missing frames produce a zero intersection. Cancellation: leaving the viewport is terminal for that visibility generation.
public struct VisibilityContext: Sendable, Hashable {
    public let nodeID: ElementID
    public let viewportFrame: LayoutFrame
    public let visibleFrame: LayoutFrame?
    public let intersectionRatio: Double
    public let revision: UInt64

    /// Creates a visibility context.
    /// Ownership: values are copied. Isolation: none. Errors: the ratio is clamped to zero...one. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        viewportFrame: LayoutFrame,
        visibleFrame: LayoutFrame?,
        intersectionRatio: Double,
        revision: UInt64
    ) {
        self.nodeID = nodeID
        self.viewportFrame = viewportFrame
        self.visibleFrame = visibleFrame
        self.intersectionRatio = min(1, max(0, intersectionRatio.isFinite ? intersectionRatio : 0))
        self.revision = revision
    }
}

/// Priority assigned to viewport preparation demand.
/// Ownership: the value is copied by the demand snapshot. Isolation: none. Errors: none. Cancellation: demand is cancelled when its node leaves the viewport.
public enum ViewportDemandPriority: Int, Sendable, Hashable {
    case visible = 0
    case near = 1
    case prefetched = 2
}

/// Bounded viewport preparation request.
/// Ownership: the request is copied into the bounded demand pipe. Isolation: none. Errors: overflow is reported by the pipe. Cancellation: leaving viewport invalidates the revision.
public struct ViewportDemand: Sendable, Hashable {
    public let nodeID: ElementID
    public let priority: ViewportDemandPriority
    public let revision: UInt64

    /// Creates a demand snapshot.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(nodeID: ElementID, priority: ViewportDemandPriority, revision: UInt64) {
        self.nodeID = nodeID
        self.priority = priority
        self.revision = revision
    }
}

/// Result of nested-scroll arbitration before a gesture is claimed.
/// Ownership: the decision is copied by the adapter. Isolation: MainActor during arbitration. Errors: none. Cancellation: deferred gestures remain available to the parent container.
public enum ScrollArbitration: Sendable, Hashable {
    case claim
    case deferToChild
    case deferToParent
}

/// Normalized nested-scroll gesture request.
/// Ownership: the request is borrowed for synchronous arbitration. Isolation: MainActor. Errors: non-finite deltas are treated as zero. Cancellation: no work is scheduled.
public struct ScrollGestureRequest: Sendable, Hashable {
    public let axis: ScrollAxis
    public let deltaX: Double
    public let deltaY: Double
    public let targetsControl: Bool

    /// Creates a gesture request.
    /// Ownership: values are copied. Isolation: none. Errors: non-finite deltas normalize to zero. Cancellation: not applicable.
    public init(axis: ScrollAxis, deltaX: Double, deltaY: Double, targetsControl: Bool = false) {
        self.axis = axis
        self.deltaX = deltaX.isFinite ? deltaX : 0
        self.deltaY = deltaY.isFinite ? deltaY : 0
        self.targetsControl = targetsControl
    }
}

/// A platform-neutral scroll container. Native scrolling mechanics remain in adapters; this type owns state, visibility, and arbitration.
/// Ownership: the node owns bounded event pipes and child visibility generations. Isolation: MainActor. Errors: invalid commands are ignored. Cancellation: cancel, unmount and dispose invalidate scrolling and demand revisions.
@MainActor
open class ScrollNode: Node, EdgePullContainer {
    public let axis: ScrollAxis
    public let stateChanges: ActionPipe<ScrollState>
    public let visibilityChanges: ActionPipe<VisibilityContext>
    public let demandRequests: ActionPipe<ViewportDemand>
    public let edgePullRequests: ActionPipe<EdgePullRequest>
    public private(set) var state: ScrollState
    public private(set) var edgePullState: EdgePullState = .idle
    public private(set) var edgePullPresentationDistance: Double = 0
    /// Elastic/action configuration for the leading (top/left) edge. `nil` disables edge pull there.
    public var startEdgePull: EdgePullConfiguration?
    /// Elastic/action configuration for the trailing (bottom/right) edge. `nil` disables edge pull there.
    public var endEdgePull: EdgePullConfiguration?
    public var layoutDirection: LayoutDirection { didSet { preserveLeadingOffset() } }
    public var nestedThreshold: Double

    private var visibleIDs: Set<ElementID> = []
    private var visibilityRevision: UInt64 = 0
    private var edgePullEdge: ScrollContentEdge?
    private var edgePullDistance: Double = 0
    private var edgePullGeneration: UInt64 = 0

    /// Creates a scroll container without allocating a native scroll view.
    /// Ownership: the node owns its bounded pipes and state. Isolation: MainActor. Errors: negative threshold is clamped. Cancellation: no work starts.
    public init(
        axis: ScrollAxis = .vertical,
        layoutDirection: LayoutDirection = .leftToRight,
        nestedThreshold: Double = 2,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.axis = axis
        self.layoutDirection = layoutDirection
        self.nestedThreshold = max(0, nestedThreshold.isFinite ? nestedThreshold : 2)
        state = ScrollState()
        stateChanges = ActionPipe(capacity: 32)
        visibilityChanges = ActionPipe(capacity: 64)
        demandRequests = ActionPipe(capacity: 64)
        edgePullRequests = ActionPipe(capacity: 16)
        super.init(style: style, environment: environment)
    }

    /// Updates viewport and content geometry and clamps the committed offset.
    /// Ownership: sizes are copied into state. Isolation: MainActor. Errors: invalid sizes normalize to zero. Cancellation: stale visibility generations are discarded.
    public func updateViewport(viewportSize: MeasuredSize, contentSize: MeasuredSize) {
        commit(
            offset: state.offset, viewportSize: viewportSize, contentSize: contentSize,
            isScrolling: false)
        visibilityRevision &+= 1
        visibleIDs.removeAll()
    }

    /// Starts an edge pull when the signed direct-drag delta points beyond a scroll boundary.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: an edge without a configured
    /// `startEdgePull`/`endEdgePull` refuses. Cancellation: not applicable.
    @discardableResult
    public func beginEdgePull(for delta: Double) -> Bool {
        guard edgePullEdge == nil, delta.isFinite, delta != 0 else { return false }
        let edge: ScrollContentEdge = delta < 0 ? .start : .end
        guard edgePullConfiguration(for: edge) != nil else { return false }
        let maximum =
            axis == .vertical
            ? max(0, state.contentSize.height - state.viewportSize.height)
            : max(0, state.contentSize.width - state.viewportSize.width)
        let offset = axis == .vertical ? state.offset.y : state.offset.x
        let atBoundary = edge == .start ? offset <= 0.0001 : offset >= maximum - 0.0001
        guard atBoundary else { return false }
        edgePullEdge = edge
        edgePullDistance = 0
        edgePullPresentationDistance = 0
        edgePullGeneration &+= 1
        return true
    }

    /// Adds direct-drag distance to the active edge pull using resistance.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: no active pull is a no-op.
    /// Cancellation: not applicable.
    public func updateEdgePull(delta: Double) {
        guard let edge = edgePullEdge, let configuration = edgePullConfiguration(for: edge),
            delta.isFinite
        else { return }
        let signedDistance = edge == .start ? -delta : delta
        edgePullDistance = max(0, edgePullDistance + signedDistance)
        let distance = min(
            configuration.maximumDistance,
            edgePullDistance * configuration.resistance)
        let progress =
            configuration.threshold > 0
            ? min(1, distance / configuration.threshold)
            : 1
        edgePullPresentationDistance = distance
        edgePullState =
            distance >= configuration.threshold
            ? .armed(edge: edge, distance: distance)
            : .pulling(edge: edge, progress: progress, distance: distance)
        rootNode.onEdgePullChanged?(self)
    }

    /// Releases the edge pull and emits an action request only in action mode.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: no active pull is a no-op.
    /// Cancellation: not applicable.
    public func finishEdgePull() {
        guard let edge = edgePullEdge, let configuration = edgePullConfiguration(for: edge) else {
            return
        }
        let distance = currentEdgePullDistance(configuration: configuration)
        if distance >= configuration.threshold, configuration.behavior == .action {
            edgePullState = .active(edge: edge)
            _ = edgePullRequests.send(EdgePullRequest(edge: edge, generation: edgePullGeneration))
            if !configuration.holdWhileActive {
                edgePullState = .settling(edge: edge, distance: distance)
                clearEdgePullState()
            }
        } else {
            edgePullState = .settling(edge: edge, distance: distance)
            clearEdgePullState()
        }
        rootNode.onEdgePullChanged?(self)
    }

    /// Cancels and clears an active edge pull without emitting a request.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func cancelEdgePull() {
        guard edgePullEdge != nil else { return }
        edgePullState = .cancelled
        clearEdgePullState()
        rootNode.onEdgePullChanged?(self)
    }

    /// Completes an active action-mode pull and returns its presentation to zero.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: an edge mismatch is a no-op.
    /// Cancellation: not applicable.
    public func completeEdgePull(at edge: ScrollContentEdge) {
        guard edgePullEdge == edge else { return }
        edgePullState = .settling(edge: edge, distance: edgePullDistance)
        clearEdgePullState()
        rootNode.onEdgePullChanged?(self)
    }

    private func edgePullConfiguration(for edge: ScrollContentEdge) -> EdgePullConfiguration? {
        switch edge {
        case .start: return startEdgePull
        case .end: return endEdgePull
        }
    }

    private func currentEdgePullDistance(configuration: EdgePullConfiguration) -> Double {
        min(configuration.maximumDistance, edgePullDistance * configuration.resistance)
    }

    private func clearEdgePullState() {
        edgePullEdge = nil
        edgePullDistance = 0
    }

    /// Applies a directional scroll command synchronously.
    /// Ownership: the command is borrowed for the call. Isolation: MainActor. Errors: out-of-bounds offsets clamp. Cancellation: cancel never emits a stale activation.
    @discardableResult
    public func scroll(_ command: ScrollCommand) -> ScrollState {
        switch command {
        case let .by(x, y):
            return moveBy(x: x, y: y)
        case let .to(offset):
            return commit(
                offset: offset, viewportSize: state.viewportSize, contentSize: state.contentSize,
                isScrolling: true)
        case let .reveal(frame, alignment):
            return reveal(frame: frame, alignment: alignment)
        case .cancel:
            return commit(
                offset: state.offset, viewportSize: state.viewportSize,
                contentSize: state.contentSize, isScrolling: false)
        }
    }

    /// Moves by a physical delta and clamps against content bounds.
    /// Ownership: no mutable state escapes. Isolation: MainActor. Errors: non-finite deltas are ignored. Cancellation: no task is scheduled.
    @discardableResult
    public func moveBy(x: Double, y: Double) -> ScrollState {
        let dx = x.isFinite ? x : 0
        let dy = y.isFinite ? y : 0
        return commit(
            offset: LayoutPoint(x: state.offset.x + dx, y: state.offset.y + dy),
            viewportSize: state.viewportSize,
            contentSize: state.contentSize,
            isScrolling: true
        )
    }

    /// Reveals a content frame using nearest/start/center/end alignment.
    /// Ownership: the frame is borrowed for this call. Isolation: MainActor. Errors: empty frames are clamped. Cancellation: no work survives the synchronous command.
    @discardableResult
    public func reveal(frame: LayoutFrame, alignment: ScrollAlignment = .nearest) -> ScrollState {
        let viewport = state.viewportSize
        var x = state.offset.x
        var y = state.offset.y
        if axis == .horizontal || axis == .both {
            x = alignedOffset(
                current: x, start: frame.origin.x, length: frame.width, viewport: viewport.width,
                alignment: alignment)
        }
        if axis == .vertical || axis == .both {
            y = alignedOffset(
                current: y, start: frame.origin.y, length: frame.height, viewport: viewport.height,
                alignment: alignment)
        }
        return commit(
            offset: LayoutPoint(x: x, y: y), viewportSize: viewport, contentSize: state.contentSize,
            isScrolling: true)
    }

    /// Returns the logical leading offset, preserving RTL semantics.
    /// Ownership: the scalar is returned by value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var leadingOffset: Double {
        let maximum = maxOffset().x
        return layoutDirection == .leftToRight ? state.offset.x : maximum - state.offset.x
    }

    /// Updates logical leading offset while preserving RTL anchoring.
    /// Ownership: the scalar is borrowed for this call. Isolation: MainActor. Errors: values clamp to bounds. Cancellation: none.
    public func scrollToLeadingOffset(_ value: Double) -> ScrollState {
        let logical = value.isFinite ? value : 0
        let x = layoutDirection == .leftToRight ? logical : maxOffset().x - logical
        return commit(
            offset: LayoutPoint(x: x, y: state.offset.y), viewportSize: state.viewportSize,
            contentSize: state.contentSize, isScrolling: true)
    }

    /// Updates child visibility and emits entered/left callbacks exactly once per generation.
    /// Ownership: frames are copied for the synchronous pass. Isolation: MainActor. Errors: absent frames are treated as not visible. Cancellation: a new geometry revision invalidates prior demand.
    public func updateVisibleFrames(_ frames: [ElementID: LayoutFrame]) {
        visibilityRevision &+= 1
        let viewport = LayoutFrame(
            width: state.viewportSize.width, height: state.viewportSize.height)
        var nextVisible: Set<ElementID> = []
        for child in subnodes {
            guard let frame = frames[child.id] ?? child.calculatedFrame else { continue }
            let ratio = intersectionRatio(frame, viewport)
            let context = VisibilityContext(
                nodeID: child.id, viewportFrame: viewport, visibleFrame: frame,
                intersectionRatio: ratio, revision: visibilityRevision)
            if ratio > 0 {
                nextVisible.insert(child.id)
                _ = visibilityChanges.send(context)
                if !visibleIDs.contains(child.id) { child.enteredViewport(context) }
                _ = demandRequests.send(
                    ViewportDemand(
                        nodeID: child.id, priority: .visible, revision: visibilityRevision))
            } else if visibleIDs.contains(child.id) {
                child.leftViewport(context)
            }
        }
        visibleIDs = nextVisible
    }

    /// Decides whether this container may claim a nested gesture.
    /// Ownership: the request is borrowed synchronously. Isolation: MainActor. Errors: zero deltas defer to the child. Cancellation: deferral does not mutate child controls.
    public func arbitrate(_ request: ScrollGestureRequest) -> ScrollArbitration {
        let dx = abs(request.deltaX)
        let dy = abs(request.deltaY)
        guard max(dx, dy) >= nestedThreshold else { return .deferToChild }
        if request.targetsControl && max(dx, dy) < nestedThreshold * 2 { return .deferToChild }
        let canMove =
            switch request.axis {
            case .horizontal: dx > 0 && canScrollHorizontally
            case .vertical: dy > 0 && canScrollVertically
            case .both: (dx > 0 && canScrollHorizontally) || (dy > 0 && canScrollVertically)
            }
        return canMove ? .claim : .deferToParent
    }

    /// Cancels the current scroll interaction and invalidates pending viewport demand.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: idempotent. Cancellation: demand revisions advance and no late callback is accepted.
    public func cancelScroll() {
        visibilityRevision &+= 1
        _ = scroll(.cancel)
    }

    public override func dispose() {
        cancelScroll()
        cancelEdgePull()
        stateChanges.finish()
        visibilityChanges.finish()
        demandRequests.finish()
        edgePullRequests.finish()
        super.dispose()
    }

    private var canScrollHorizontally: Bool { maxOffset().x > 0 }
    private var canScrollVertically: Bool { maxOffset().y > 0 }

    @discardableResult
    private func commit(
        offset: LayoutPoint, viewportSize: MeasuredSize, contentSize: MeasuredSize,
        isScrolling: Bool
    ) -> ScrollState {
        let normalizedViewport = MeasuredSize(
            width: viewportSize.width, height: viewportSize.height)
        let normalizedContent = MeasuredSize(width: contentSize.width, height: contentSize.height)
        let maximum = LayoutPoint(
            x: max(0, normalizedContent.width - normalizedViewport.width),
            y: max(0, normalizedContent.height - normalizedViewport.height)
        )
        let geometryChanged =
            normalizedViewport != state.viewportSize || normalizedContent != state.contentSize
        let next = ScrollState(
            offset: LayoutPoint(
                x: min(max(0, offset.x), maximum.x), y: min(max(0, offset.y), maximum.y)),
            contentSize: normalizedContent,
            viewportSize: normalizedViewport,
            isScrolling: isScrolling,
            revision: state.revision &+ 1
        )
        state = next
        _ = stateChanges.send(next)
        rootNode.onScrollStateChanged?(self)
        if geometryChanged { setNeedsLayout() }
        return next
    }

    private func maxOffset() -> LayoutPoint {
        LayoutPoint(
            x: max(0, state.contentSize.width - state.viewportSize.width),
            y: max(0, state.contentSize.height - state.viewportSize.height))
    }

    private func preserveLeadingOffset() {
        let logical = leadingOffset
        _ = scrollToLeadingOffset(logical)
    }

    private func alignedOffset(
        current: Double, start: Double, length: Double, viewport: Double, alignment: ScrollAlignment
    ) -> Double {
        let end = start + max(0, length)
        switch alignment {
        case .start: return start
        case .center: return start - max(0, (viewport - length) / 2)
        case .end: return end - viewport
        case .nearest:
            if start < current { return start }
            if end > current + viewport { return end - viewport }
            return current
        }
    }

    private func intersectionRatio(_ frame: LayoutFrame, _ viewport: LayoutFrame) -> Double {
        let left = max(frame.origin.x, viewport.origin.x)
        let top = max(frame.origin.y, viewport.origin.y)
        let right = min(frame.origin.x + frame.width, viewport.origin.x + viewport.width)
        let bottom = min(frame.origin.y + frame.height, viewport.origin.y + viewport.height)
        let intersection = max(0, right - left) * max(0, bottom - top)
        let area = frame.width * frame.height
        return area > 0 ? intersection / area : 0
    }
}
