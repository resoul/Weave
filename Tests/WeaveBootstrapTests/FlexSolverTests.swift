import Testing
import Weave

@Test
func test_flexSolver_nestedRowMeasuresChildrenAndGapDeterministically() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(40), height: .points(20)))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexDirection: .row,
            padding: DirectionalEdgeInsets(leading: 5, trailing: 5),
            gap: 10),
        children: [child, child],
        environmentRevision: 7,
        contentRevision: 3
    )
    let first = FlexSolver.measureContainer(input: root)
    let second = FlexSolver.measureContainer(input: root)
    #expect(first == second)
    #expect(first.size == MeasuredSize(width: 100, height: 20))
    #expect(first.cacheKey.environmentRevision == 7)
}

@Test
func test_flexSolver_wrapUsesCrossGapAndAtMostConstraint() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(60), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexDirection: .row, flexWrap: .wrap, crossGap: 4),
        children: [child, child, child]
    )
    let result = FlexSolver.measureContainer(
        input: root,
        constraint: SizeConstraint(width: .atMost(130), height: .unspecified)
    )
    #expect(result.size == MeasuredSize(width: 120, height: 24))
}

@Test
func test_flexSolver_usesSnapshotDirectionWithoutCapturingNode() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(20), height: .points(8)))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexDirection: .row),
        children: [child],
        direction: .rightToLeft
    )
    #expect(FlexSolver.measureContainer(input: root).size == MeasuredSize(width: 20, height: 8))
}
