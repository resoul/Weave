import Testing
@testable import Weave

@MainActor
struct ScrollTests {
    private final class VisibilityNode: Node {
        var entered = 0
        var left = 0

        override func enteredViewport(_ context: VisibilityContext) { entered += 1 }
        override func leftViewport(_ context: VisibilityContext) { left += 1 }
    }

    @Test
    func contentBoundsClampAndDirectionalCommands() {
        let scroll = ScrollNode(axis: .both)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 100),
            contentSize: MeasuredSize(width: 300, height: 250)
        )
        #expect(scroll.scroll(.by(x: 500, y: 500)).offset == LayoutPoint(x: 200, y: 150))
        #expect(scroll.scroll(.to(LayoutPoint(x: -10, y: -10))).offset == LayoutPoint(x: 0, y: 0))
    }

    @Test
    func visibilityHooksAndDemandAreGenerationBounded() {
        let scroll = ScrollNode()
        let child = VisibilityNode()
        scroll.addSubnode(child)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 100),
            contentSize: MeasuredSize(width: 100, height: 300)
        )
        let frame = LayoutFrame(origin: LayoutPoint(x: 0, y: 10), width: 50, height: 50)
        scroll.updateVisibleFrames([child.id: frame])
        scroll.updateVisibleFrames([child.id: frame])
        #expect(child.entered == 1)
        scroll.updateVisibleFrames([
            child.id: LayoutFrame(origin: LayoutPoint(x: 0, y: 200), width: 50, height: 50)
        ])
        #expect(child.left == 1)
    }

    @Test
    func focusRevealAndRTLLeadingOffsetPreserveBounds() {
        let scroll = ScrollNode(axis: .horizontal, layoutDirection: .rightToLeft)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 50),
            contentSize: MeasuredSize(width: 400, height: 50)
        )
        _ = scroll.scrollToLeadingOffset(40)
        #expect(scroll.leadingOffset == 40)
        _ = scroll.reveal(
            frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 30, height: 20),
            alignment: .start
        )
        #expect(scroll.state.offset.x == 0)
    }

    @Test
    func nestedControlGestureDefersUntilIntentIsClear() {
        let scroll = ScrollNode(axis: .vertical, nestedThreshold: 4)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 100),
            contentSize: MeasuredSize(width: 100, height: 300)
        )
        #expect(
            scroll.arbitrate(
                ScrollGestureRequest(axis: .vertical, deltaX: 0, deltaY: 2, targetsControl: true))
                == .deferToChild)
        #expect(
            scroll.arbitrate(
                ScrollGestureRequest(axis: .vertical, deltaX: 0, deltaY: 12, targetsControl: false))
                == .claim)
    }
}
