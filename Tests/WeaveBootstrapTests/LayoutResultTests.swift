import Testing
import Weave

@Test
func test_layoutResult_placesRowChildren_andKeepsRevisions() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(30), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexDirection: .row, gap: 10),
        children: [child, LayoutInputSnapshot(identity: 3, style: child.style)],
        environmentRevision: 4,
        contentRevision: 5
    )
    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 20))
    #expect(result.placement(for: 2)?.frame.origin.x == 0)
    #expect(result.placement(for: 3)?.frame.origin.x == 40)
    #expect(result.environmentRevision == 4)
    #expect(result.contentRevision == 5)
}

@Test
func test_layoutResult_mirrorsRowForRTL_andRoundsAtScale() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(10), height: .points(5)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(flexDirection: .row), children: [child],
        direction: .rightToLeft)
    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 20, height: 10),
        roundingPolicy: PixelRoundingPolicy(scale: 2))
    #expect(result.placement(for: 2)?.frame.origin.x == 10)
}

@Test
func test_layoutResult_snapsFramesAtSupportedScales_withoutNegativeSizes() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(3.2), height: .points(2.7)))
    let root = LayoutInputSnapshot(identity: 1, children: [child])
    for scale in [1.0, 2.0, 3.0] {
        let result = FlexSolver.layoutContainer(
            input: root,
            frame: LayoutFrame(width: 10, height: 10),
            roundingPolicy: PixelRoundingPolicy(scale: scale))
        let frame = result.placement(for: 2)?.frame
        #expect(frame?.width ?? -1 >= 0)
        #expect(frame?.height ?? -1 >= 0)
    }
}
