import Testing
@testable import Weave

@MainActor
struct NestedScrollArbitrationTests {
    /// A scroll node with enough content to be scrollable along its own axis, in a viewport
    /// small enough that `canScrollHorizontally`/`canScrollVertically` are true where expected.
    private func makeScrollable(axis: ScrollAxis, nestedThreshold: Double = 2) -> ScrollNode {
        let node = ScrollNode(axis: axis, nestedThreshold: nestedThreshold)
        // `canScrollHorizontally`/`canScrollVertically` come from content vs. viewport size, not
        // from `axis` alone — so a genuinely "horizontal-only" node needs its content height
        // capped to the viewport height (and vice versa) to actually be unable to scroll the
        // other way.
        let contentWidth = axis == .vertical ? 100.0 : 500.0
        let contentHeight = axis == .horizontal ? 100.0 : 500.0
        node.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 100),
            contentSize: MeasuredSize(width: contentWidth, height: contentHeight)
        )
        return node
    }

    // MARK: - scrollAncestors

    @Test
    func scrollAncestorsReturnsInnermostFirst() {
        let outer = ScrollNode(axis: .vertical)
        let inner = ScrollNode(axis: .horizontal)
        let leaf = Node()
        outer.addSubnode(inner)
        inner.addSubnode(leaf)

        let placements = [
            LayoutPlacement(
                identity: outer.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 300)),
            LayoutPlacement(
                identity: inner.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
            LayoutPlacement(
                identity: leaf.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
        ]
        let result = LayoutResult(
            placements: placements, treeIdentity: outer.id, environmentRevision: 1,
            contentRevision: 1)
        outer.applyRecursively(result)

        let candidates = NestedScrollArbiter.scrollAncestors(
            in: outer, at: LayoutPoint(x: 10, y: 10))
        #expect(candidates.count == 2)
        #expect(candidates.first === inner)
        #expect(candidates.last === outer)
    }

    @Test
    func scrollAncestorsIsEmptyOutsideAnyFrame() {
        let outer = ScrollNode(axis: .vertical)
        outer.applyRecursively(
            LayoutResult(
                placements: [
                    LayoutPlacement(
                        identity: outer.id,
                        frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 100, height: 100)
                    )
                ], treeIdentity: outer.id, environmentRevision: 1, contentRevision: 1))

        let candidates = NestedScrollArbiter.scrollAncestors(
            in: outer, at: LayoutPoint(x: 500, y: 500))
        #expect(candidates.isEmpty)
    }

    // MARK: - resolve

    @Test
    func resolveClaimsInnermostScrollableAlongRequestedAxis() {
        let inner = makeScrollable(axis: .horizontal)
        let outer = makeScrollable(axis: .vertical)

        let resolved = NestedScrollArbiter.resolve(
            candidates: [inner, outer], axis: .horizontal, deltaX: 20, deltaY: 0,
            targetsControl: false)
        #expect(resolved === inner)
    }

    @Test
    func resolveDefersToParentWhenInnerCannotScrollThatAxis() {
        let inner = makeScrollable(axis: .horizontal)
        let outer = makeScrollable(axis: .vertical)

        let resolved = NestedScrollArbiter.resolve(
            candidates: [inner, outer], axis: .vertical, deltaX: 0, deltaY: 20,
            targetsControl: false)
        #expect(resolved === outer)
    }

    @Test
    func resolveReturnsNilWhenNoCandidateCanScrollThatAxis() {
        let inner = makeScrollable(axis: .horizontal)
        let outer = makeScrollable(axis: .horizontal)

        let resolved = NestedScrollArbiter.resolve(
            candidates: [inner, outer], axis: .vertical, deltaX: 0, deltaY: 20,
            targetsControl: false)
        #expect(resolved == nil)
    }

    @Test
    func resolveReturnsNilBelowNestedThreshold() {
        let inner = makeScrollable(axis: .horizontal, nestedThreshold: 10)
        let resolved = NestedScrollArbiter.resolve(
            candidates: [inner], axis: .horizontal, deltaX: 3, deltaY: 0, targetsControl: false)
        #expect(resolved == nil)
    }

    // MARK: - NestedScrollGestureTracker

    @Test
    func trackerClaimsAndStaysWithSameNodeAcrossSubsequentMoves() {
        // Both scrollable in both directions. `resolve` walks outermost-first (see
        // NestedScrollArbitration.swift), so `outer` claims first — the point of this test is
        // that the tracker doesn't run a fresh arbitration at all once claimed, not which
        // candidate wins that first arbitration.
        let inner = makeScrollable(axis: .both)
        let outer = makeScrollable(axis: .both)
        let tracker = NestedScrollGestureTracker()
        tracker.begin(candidates: [inner, outer], targetsControl: false)

        let claimed = tracker.move(dx: 20, dy: 0)
        #expect(claimed === outer)
        #expect(tracker.claimedScrollNode === outer)

        // A move that a fresh arbitration might resolve differently must still land on the
        // already-claimed outer node — no mid-gesture handoff — and actually move it.
        let secondMove = tracker.move(dx: 0, dy: 50)
        #expect(secondMove === outer)
        #expect(outer.state.offset.x == 20)
        #expect(outer.state.offset.y == 50)
        #expect(inner.state.offset == LayoutPoint(x: 0, y: 0))
    }

    @Test
    func trackerAccumulatesDeltaWhileUndecidedThenAppliesItOnClaim() {
        let inner = makeScrollable(axis: .horizontal, nestedThreshold: 10)
        let tracker = NestedScrollGestureTracker()
        tracker.begin(candidates: [inner], targetsControl: false)

        // Below threshold: no claim yet, nothing moves.
        #expect(tracker.move(dx: 3, dy: 0) == nil)
        #expect(inner.state.offset.x == 0)

        // Cumulative delta (3 + 4 = 7) is still below threshold 10.
        #expect(tracker.move(dx: 4, dy: 0) == nil)
        #expect(inner.state.offset.x == 0)

        // Cumulative delta now crosses the threshold; the *whole* accumulated delta applies.
        let claimed = tracker.move(dx: 5, dy: 0)
        #expect(claimed === inner)
        #expect(inner.state.offset.x == 12)
    }

    @Test
    func trackerGatesControlOriginatedDragsAtDoubleThreshold() {
        let inner = makeScrollable(axis: .horizontal, nestedThreshold: 2)
        let tracker = NestedScrollGestureTracker()
        tracker.begin(candidates: [inner], targetsControl: true)

        // Past the plain threshold (2) but not double it (4): still deferred.
        #expect(tracker.move(dx: 3, dy: 0) == nil)
        #expect(inner.state.offset.x == 0)

        // Cumulative delta now 3 + 2 = 5, past double the threshold.
        let claimed = tracker.move(dx: 2, dy: 0)
        #expect(claimed === inner)
    }

    @Test
    func trackerEndAndCancelClearState() {
        let inner = makeScrollable(axis: .horizontal)
        let tracker = NestedScrollGestureTracker()
        tracker.begin(candidates: [inner], targetsControl: false)
        _ = tracker.move(dx: 20, dy: 0)
        #expect(tracker.isActive)

        tracker.end()
        #expect(!tracker.isActive)
        #expect(tracker.claimedScrollNode == nil)

        tracker.begin(candidates: [inner], targetsControl: false)
        _ = tracker.move(dx: 20, dy: 0)
        tracker.cancel()
        #expect(!tracker.isActive)
    }

    @Test
    func trackerIsActiveIsFalseBeforeBegin() {
        let tracker = NestedScrollGestureTracker()
        #expect(!tracker.isActive)
    }
}
