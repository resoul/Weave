import Testing
import Weave

@Test
func test_flexSolver_grow_distributesFreeMainSpace() {
    let child = LayoutInputSnapshot(identity: 2, style: LayoutStyle(flexGrow: 1))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(200)), children: [child])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(200)))

    #expect(result.lines[0].items[0].mainSize == 200)
}

@Test
func test_flexSolver_shrink_respectsMinimumAndRedistributes() {
    let first = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(80), minWidth: .points(60)))
    let second = LayoutInputSnapshot(identity: 3, style: LayoutStyle(width: .points(80)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(100)), children: [first, second])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(100)))
    let items = result.lines[0].items

    #expect(items[0].mainSize == 60)
    #expect(items[1].mainSize == 40)
}

@Test
func test_flexSolver_wrap_preservesLineAssignment() {
    let child = { (id: UInt64) in
        LayoutInputSnapshot(
            identity: id, style: LayoutStyle(width: .points(60), height: .points(10)))
    }
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexWrap: .wrap, width: .points(100)),
        children: [child(2), child(3), child(4)]
    )

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(100)))

    #expect(result.lines.count == 3)
    #expect(result.lines.allSatisfy { $0.items.count == 1 })
}

@Test
func test_flexSolver_absoluteChildIsExcludedFromFlexLines() {
    let relative = LayoutInputSnapshot(identity: 2, style: LayoutStyle(flexGrow: 1))
    let absolute = LayoutInputSnapshot(identity: 3, style: LayoutStyle(positionType: .absolute))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(200)), children: [relative, absolute])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(200)))

    #expect(result.lines.count == 1)
    #expect(result.lines[0].items.map(\.identity) == [2])
}

private func algorithmChild(
    _ id: UInt64,
    width: SizeValue = .auto,
    height: SizeValue = .points(10),
    style: LayoutStyle? = nil,
    content: LayoutContentMetrics = LayoutContentMetrics()
) -> LayoutInputSnapshot {
    LayoutInputSnapshot(
        identity: id,
        style: style ?? LayoutStyle(width: width, height: height),
        content: content
    )
}

@Test
func test_flexSolver_weightedGrow_usesPreRoundingGeometry() {
    let children = [
        algorithmChild(2, width: .points(30)),
        algorithmChild(3, width: .points(30)),
        algorithmChild(4, width: .points(30)),
    ].enumerated().map { index, child in
        LayoutInputSnapshot(
            identity: child.identity,
            style: LayoutStyle(
                flexGrow: index == 1 ? 2 : 1, width: .points(30), height: .points(10))
        )
    }
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(300)), children: children)

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(300)))
    let sizes = result.lines[0].items.map(\.mainSize)

    #expect(abs(sizes[0] - 82.5) < 0.0001)
    #expect(abs(sizes[1] - 135.0) < 0.0001)
    #expect(abs(sizes[2] - 82.5) < 0.0001)
}

@Test
func test_flexSolver_proportionalShrink_usesFlexBasis() {
    let first = algorithmChild(
        2, style: LayoutStyle(flexBasis: .points(150), width: .points(50), height: .points(10)))
    let second = algorithmChild(
        3, style: LayoutStyle(flexBasis: .points(100), width: .points(50), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(200)), children: [first, second])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(200)))

    #expect(abs(result.lines[0].items[0].mainSize - 120) < 0.0001)
    #expect(abs(result.lines[0].items[1].mainSize - 80) < 0.0001)
}

@Test
func test_flexSolver_shrinkZero_preventsCompression() {
    let child = algorithmChild(
        2, style: LayoutStyle(flexShrink: 0, width: .points(150), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(100)), children: [child])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(100)))

    #expect(result.lines[0].items[0].mainSize == 150)
}

@Test
func test_flexSolver_growZero_doesNotExpand() {
    let child = algorithmChild(
        2, style: LayoutStyle(flexGrow: 0, width: .points(50), height: .points(10)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(200)), children: [child])

    let result = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(200)))

    #expect(result.lines[0].items[0].mainSize == 50)
}

@Test
func test_flexSolver_wrap_placesLinesAfterPreviousCrossSize() {
    let first = algorithmChild(2, width: .points(80), height: .points(40))
    let second = algorithmChild(3, width: .points(80), height: .points(30))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexWrap: .wrap, alignContent: .start, width: .points(100)),
        children: [first, second]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 3)?.frame.origin.y == 40)
}

@Test
func test_flexSolver_wrap_twoItemsFitOnOneLine() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(flexWrap: .wrap, alignContent: .start, width: .points(120)),
        children: [algorithmChild(2, width: .points(60)), algorithmChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 120, height: 30))

    #expect(result.placement(for: 3)?.frame.origin.x == 60)
}

@Test
func test_flexSolver_crossGap_appliesBetweenLines() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            flexWrap: .wrap, alignContent: .start, width: .points(100), crossGap: 5),
        children: [algorithmChild(2, width: .points(60)), algorithmChild(3, width: .points(60))]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 40))

    #expect(result.placement(for: 3)?.frame.origin.y == 15)
}

@Test
func test_flexSolver_alignItems_centerAndEndPositionCrossAxis() {
    let centered = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(alignItems: .center, width: .points(100), height: .points(100)),
        children: [algorithmChild(2, width: .points(20), height: .points(40))]
    )
    let trailing = LayoutInputSnapshot(
        identity: 3,
        style: LayoutStyle(alignItems: .end, width: .points(100), height: .points(100)),
        children: [algorithmChild(4, width: .points(20), height: .points(40))]
    )

    let centeredResult = FlexSolver.layoutContainer(
        input: centered, frame: LayoutFrame(width: 100, height: 100))
    let trailingResult = FlexSolver.layoutContainer(
        input: trailing, frame: LayoutFrame(width: 100, height: 100))

    #expect(centeredResult.placement(for: 2)?.frame.origin.y == 30)
    #expect(trailingResult.placement(for: 4)?.frame.origin.y == 60)
}

@Test
func test_flexSolver_alignItems_stretchExpandsAutoCrossSize() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(width: .points(100), height: .points(100)),
        children: [algorithmChild(2, width: .points(20), height: .auto)]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.height == 100)
}

@Test
func test_flexSolver_alignSelfOverridesParentCrossAlignment() {
    let child = algorithmChild(
        2,
        style: LayoutStyle(alignSelf: .center, width: .points(20), height: .points(40)))
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(alignItems: .end, width: .points(100), height: .points(100)),
        children: [child]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.origin.y == 30)
}

@Test
func test_flexSolver_aspectRatio_resolvesAutoDimension() {
    let child = algorithmChild(
        2,
        style: LayoutStyle(width: .points(100), height: .auto, aspectRatio: 2))
    let root = LayoutInputSnapshot(identity: 1, children: [child])

    let result = FlexSolver.measureContainer(input: root)

    #expect(result.lines[0].items[0].crossSize == 50)
}

@Test
func test_flexSolver_absoluteOffsetsUsePaddingBox() {
    let child = algorithmChild(
        2,
        style: LayoutStyle(
            width: .points(20),
            height: .points(20),
            positionType: .absolute,
            offsets: DirectionalEdgeOffsets(top: 5, leading: 20))
    )
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(
            width: .points(100), height: .points(100),
            padding: DirectionalEdgeInsets(top: 10, leading: 10)),
        children: [child]
    )

    let result = FlexSolver.layoutContainer(
        input: root, frame: LayoutFrame(width: 100, height: 100))

    #expect(result.placement(for: 2)?.frame.origin.x == 30)
    #expect(result.placement(for: 2)?.frame.origin.y == 15)
}

@Test
func test_flexSolver_absoluteChildDoesNotContributeToShrinkToFitSize() {
    let relative = algorithmChild(2, width: .points(50))
    let absolute = algorithmChild(
        3, style: LayoutStyle(width: .points(200), height: .points(10), positionType: .absolute))
    let root = LayoutInputSnapshot(identity: 1, children: [relative, absolute])

    let result = FlexSolver.measureContainer(input: root)

    #expect(result.parentSize.width == 50)
}

@Test
func test_flexSolver_fractionWidth_resolvesAgainstParent() {
    let child = algorithmChild(2, width: .fraction(0.5))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(400)), children: [child])

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 400, height: 30))

    #expect(result.placement(for: 2)?.frame.width == 200)
}

@Test
func test_flexSolver_fractionWithoutParentUsesIntrinsicContent() {
    let child = algorithmChild(
        2,
        width: .fraction(0.5),
        content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 37, height: 10)))
    let root = LayoutInputSnapshot(identity: 1, children: [child])

    let result = FlexSolver.measureContainer(input: root)

    #expect(result.lines[0].items[0].mainSize == 37)
}

@Test
func test_flexSolver_rtlRowReversesMainAxis() {
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(width: .points(100)),
        children: [algorithmChild(2, width: .points(50)), algorithmChild(3, width: .points(50))],
        direction: .rightToLeft
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 20))

    #expect(result.placement(for: 2)?.frame.origin.x == 50)
    #expect(result.placement(for: 3)?.frame.origin.x == 0)
}
