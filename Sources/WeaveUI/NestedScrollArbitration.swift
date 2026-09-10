import Foundation

/// Stateless helpers that resolve which `ScrollNode` — among several nested candidates — should
/// claim one gesture. Platform-neutral so both `UIKitAdapter` and `AppKitAdapter` share one
/// arbitration policy instead of independently reimplementing it (`ScrollNode.arbitrate(_:)`
/// existed with no caller before this file; see card 03's task notes).
/// Ownership: no state is retained. Isolation: MainActor (hit-testing and `ScrollNode` are both MainActor). Errors: none. Cancellation: not applicable.
@MainActor
public enum NestedScrollArbiter {
    /// Collects every `ScrollNode` ancestor of the deepest node hit at `point`, innermost first —
    /// this is the natural order hit-test ancestry walks in. `resolve` below walks the *reverse*
    /// of this list; see its doc for why.
    /// Ownership: the returned nodes are borrowed. Isolation: MainActor. Errors: an empty result means no scroll container is under `point`. Cancellation: not applicable.
    public static func scrollAncestors(in root: Node, at point: LayoutPoint) -> [ScrollNode] {
        var candidates: [ScrollNode] = []
        var current = HitTester.hitTest(point: point, root: root)
        while let node = current {
            if let scroll = node as? ScrollNode { candidates.append(scroll) }
            current = node.supernode
        }
        return candidates
    }

    /// Walks `candidates` and returns the first one that claims the gesture. `nil` means nothing
    /// is ready to claim — either every candidate deferred (nothing here can move along this
    /// axis) or some candidate found the delta still ambiguous (below its own `nestedThreshold`).
    /// Both cases mean the same thing to a caller: do not scroll yet, and re-resolve on the next
    /// move with an updated delta.
    ///
    /// The walk direction flips with the sign of the requested delta, and that's deliberate, not
    /// incidental. `arbitrate(_:)` already steps a node aside (`.deferToParent`) whenever *that
    /// node itself* can't move along the requested axis, so for **different-axis** nesting (e.g.
    /// a horizontal tile row inside a vertical list) walk order never mattered — whichever
    /// candidate can actually move along the gesture's axis wins regardless of which end of the
    /// list you start from, and the sign flip is a no-op there since only one candidate is ever a
    /// real contender. It only matters when **multiple candidates can all move along the same
    /// axis** — same-axis nesting, e.g. a profile screen's outer scroll (header + a full-height
    /// page list stacked in it) around a page's own list. There the two directions are not
    /// symmetric: scrolling *forward* (revealing later content) must claim outer first — the
    /// header has to scroll away before the inner list gets a turn — while scrolling *backward*
    /// (returning toward the start) must claim inner first — the inner list has to unwind back to
    /// its own top before the header is allowed to come back. Always preferring outer, in either
    /// direction, steals the gesture from an inner list that is still mid-scroll the moment a new
    /// touch begins a reversal (`arbitrate(_:)` only reports scroll *capacity*, not whether the
    /// node is already at its boundary in this direction, so outer looks just as claimable as
    /// inner even while collapsed). Combined with
    /// `NestedScrollGestureTracker.distribute`'s boundary hand-off (a claimed node that can't
    /// absorb the full delta passes the remainder to its neighbor), this gives the expected
    /// behavior in both directions: forward, the outer scroll moves until exhausted and then the
    /// inner list takes over; backward, the inner list unwinds until exhausted and then the outer
    /// scroll takes over.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func resolve(
        candidates: [ScrollNode],
        axis: ScrollAxis,
        deltaX: Double,
        deltaY: Double,
        targetsControl: Bool
    ) -> ScrollNode? {
        let request = ScrollGestureRequest(
            axis: axis, deltaX: deltaX, deltaY: deltaY, targetsControl: targetsControl)
        let forward: Bool
        switch axis {
        case .horizontal: forward = deltaX >= 0
        case .vertical: forward = deltaY >= 0
        case .both: forward = abs(deltaX) >= abs(deltaY) ? deltaX >= 0 : deltaY >= 0
        }
        // `candidates` arrives innermost-first (the natural hit-test ancestry order). Forward
        // walks outermost-first (reversed); backward walks innermost-first (as given).
        let ordered: [ScrollNode] = forward ? candidates.reversed() : candidates
        for candidate in ordered {
            switch candidate.arbitrate(request) {
            case .claim: return candidate
            case .deferToParent: continue
            case .deferToChild: return nil
            }
        }
        return nil
    }
}

/// Stateful per-gesture nested-scroll arbitration: sticky once claimed (no mid-gesture handoff),
/// accumulating delta while undecided so a small ambiguous movement doesn't prematurely commit
/// to the wrong axis or the wrong container. One instance tracks one concurrent gesture; a host
/// needing to track two independent input sources (e.g. AppKit's click-drag vs. scroll-wheel)
/// uses two instances.
/// Ownership: the tracker retains no `Node`/`ScrollNode` beyond the lifetime of one gesture — `end()`/`cancel()` release them. Isolation: MainActor. Errors: none. Cancellation: `cancel()` and `end()` are equivalent; both are safe to call from any state, including before `begin(...)`.
@MainActor
public final class NestedScrollGestureTracker {
    private var candidates: [ScrollNode] = []
    private var claimed: ScrollNode?
    private var cumulativeDeltaX: Double = 0
    private var cumulativeDeltaY: Double = 0
    private var targetsControl: Bool = false

    /// Creates an idle tracker.
    /// Ownership: no state is retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init() {}

    /// True once `begin(...)` has run and neither `end()` nor `cancel()` has run since. Lets a
    /// caller detect a gesture source with no explicit "began" event (a plain mouse wheel has no
    /// phase information) and lazily call `begin` on the first move instead.
    public var isActive: Bool { !candidates.isEmpty || claimed != nil }

    /// The `ScrollNode` currently claiming this gesture, if arbitration has committed to one.
    /// Used to route momentum/deceleration to the same node the drag claimed.
    public var claimedScrollNode: ScrollNode? { claimed }

    /// Starts tracking a new gesture from a frozen candidate list — normally
    /// `NestedScrollArbiter.scrollAncestors(in:at:)` at the touch-down/mouse-down point.
    /// Ownership: `candidates` are borrowed for the gesture's duration. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func begin(candidates: [ScrollNode], targetsControl: Bool) {
        self.candidates = candidates
        self.targetsControl = targetsControl
        claimed = nil
        cumulativeDeltaX = 0
        cumulativeDeltaY = 0
    }

    /// Feeds one incremental move. Before a claim, delta accumulates and arbitration is
    /// re-attempted each call, picking innermost-first among candidates that can move at all.
    /// Once claimed, that node keeps the gesture *unless it cannot absorb the full delta* — i.e.
    /// it has hit its own scroll boundary (`moveBy` clamps internally, so the unconsumed
    /// remainder is `requested - actual`). That remainder hands to the neighboring candidate
    /// (outward first, then inward), which is what makes same-axis nested scrolling work — a
    /// collapsing header above a tab list, say, where the header must fully scroll away before
    /// the list below starts moving, and scrolling back the other way must hand control back.
    /// Different-axis nesting (the case this tracker originally shipped for) never exercises this
    /// path in practice: the two nodes don't compete for the same delta, so one absorbs all of it
    /// and there's nothing left to hand off.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: non-finite deltas are ignored (treated as zero) by the underlying `ScrollGestureRequest`/`moveBy`. Cancellation: not applicable.
    @discardableResult
    public func move(dx: Double, dy: Double) -> ScrollNode? {
        if claimed != nil {
            return distribute(dx: dx, dy: dy)
        }
        cumulativeDeltaX += dx
        cumulativeDeltaY += dy
        let axis: ScrollAxis =
            abs(cumulativeDeltaX) >= abs(cumulativeDeltaY) ? .horizontal : .vertical
        guard
            let resolved = NestedScrollArbiter.resolve(
                candidates: candidates,
                axis: axis,
                deltaX: cumulativeDeltaX,
                deltaY: cumulativeDeltaY,
                targetsControl: targetsControl
            )
        else { return nil }
        claimed = resolved
        return distribute(dx: cumulativeDeltaX, dy: cumulativeDeltaY)
    }

    /// Applies `(dx, dy)` to the claimed node; if it can't absorb all of it, hands the remainder
    /// to a neighboring candidate — outward (the next-enclosing scroll node) first, since
    /// "the inner list ran out of room, bubble to what contains it" is the common case, then
    /// inward, so reversing direction later can hand control back. `claimed` only moves to a
    /// neighbor that actually consumed some of the remainder — trying a candidate that itself
    /// can't move (both ends already exhausted) does not transfer the claim to it. Bounded to one
    /// pass over `candidates` (at most 3 nodes touched for a 2-level nesting): no unbounded
    /// bouncing between two mutually-exhausted candidates.
    private func distribute(dx: Double, dy: Double) -> ScrollNode? {
        guard let current = claimed, let index = candidates.firstIndex(where: { $0 === current })
        else { return claimed }
        var remainingX = dx
        var remainingY = dy
        var order = [index]
        if index + 1 < candidates.count { order.append(index + 1) }
        if index - 1 >= 0 { order.append(index - 1) }
        for candidateIndex in order {
            guard remainingX != 0 || remainingY != 0 else { break }
            let node = candidates[candidateIndex]
            let before = node.state.offset
            _ = node.moveBy(x: remainingX, y: remainingY)
            let after = node.state.offset
            let consumedX = after.x - before.x
            let consumedY = after.y - before.y
            if consumedX != 0 || consumedY != 0 {
                claimed = node
            }
            remainingX -= consumedX
            remainingY -= consumedY
        }
        return claimed
    }

    /// Ends the gesture normally (e.g. touch-up / mouse-up), clearing arbitration state without
    /// otherwise affecting the claimed node.
    /// Ownership: released candidates/claim are not disposed — the tracker never owned their lifecycle. Isolation: MainActor. Errors: none. Cancellation: idempotent; calling this without a prior `begin(...)` is a no-op.
    public func end() {
        candidates = []
        claimed = nil
        cumulativeDeltaX = 0
        cumulativeDeltaY = 0
    }

    /// Cancels the gesture (capture loss / system interruption). Same effect as `end()` — kept as
    /// a distinct name so call sites read correctly for each situation.
    /// Ownership: released candidates/claim are not disposed — the tracker never owned their lifecycle. Isolation: MainActor. Errors: none. Cancellation: idempotent; calling this without a prior `begin(...)` is a no-op.
    public func cancel() {
        end()
    }
}
