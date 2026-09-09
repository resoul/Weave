import Testing
import Weave

private func featureChild(
    _ id: UInt64, width: SizeValue = .points(20), height: SizeValue = .points(10)
) -> LayoutInputSnapshot {
    LayoutInputSnapshot(identity: id, style: LayoutStyle(width: width, height: height))
}

@Test
func test_flexBasis_overridesWidthOnMainAxis() {
    let child = LayoutInputSnapshot(
        identity: 2,
        style: LayoutStyle(flexBasis: .points(100), width: .points(200), height: .points(10))
    )
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(300)), children: [child])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(300)))

    #expect(result.lines[0].items[0].mainSize == 100)
}

@Test
func test_flexBasis_fraction_resolvesAgainstParentMainSize() {
    let child = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(flexBasis: .fraction(0.5), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(200)), children: [child])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(200)))

    #expect(result.lines[0].items[0].mainSize == 100)
}

@Test
func test_alignContent_center_centersWrappedLines() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexWrap: .wrap, alignContent: .center, width: .points(100), height: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.origin.y == 40)
    #expect(result.placement(for: 3)?.frame.origin.y == 50)
}

@Test
func test_alignContent_spaceBetween_distributesWrappedLines() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexWrap: .wrap, alignContent: .spaceBetween, width: .points(100), height: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.origin.y == 0)
    #expect(result.placement(for: 3)?.frame.origin.y == 90)
}

@Test
func test_alignContent_stretch_expandsWrappedLineSlots() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexWrap: .wrap, alignContent: .stretch, width: .points(100), height: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.origin.y == 0)
    #expect(result.placement(for: 3)?.frame.origin.y == 50)
}

@Test
func test_alignContent_stretch_withoutExplicitCrossSizeBehavesLikeStart() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexWrap: .wrap, alignContent: .stretch, width: .points(100)),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 20))

    #expect(result.placement(for: 2)?.frame.origin.y == 0)
    #expect(result.placement(for: 3)?.frame.origin.y == 10)
    #expect(result.placement(for: 2)?.frame.origin.y.isFinite == true)
}

@Test
func test_wrapReverse_reversesLineOrderWithoutReorderingItems() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexWrap: .wrapReverse, alignContent: .start, width: .points(100), height: .points(100)
        ),
        children: [featureChild(2, width: .points(60)), featureChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 3)?.frame.origin.y == 0)
    #expect(result.placement(for: 2)?.frame.origin.y == 10)
}
