import Testing
import Weave

@Test
func test_baselineAlignment_twoItemsShareTheLargestBaseline() {
    let first = LayoutInputSnapshot(
        identity: 2,
        style: LayoutStyle(height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20), firstBaseline: 12)
    )
    let second = LayoutInputSnapshot(
        identity: 3,
        style: LayoutStyle(height: .points(30)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 30), firstBaseline: 20)
    )
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(alignItems: .baseline, width: .points(100), height: .points(40)),
        children: [first, second]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 40))

    #expect(result.placement(for: 2)?.frame.origin.y == 8)
    #expect(result.placement(for: 3)?.frame.origin.y == 0)
}

@Test
func test_baselineAlignment_itemWithoutBaselineFallsBackToStart() {
    let text = LayoutInputSnapshot(
        identity: 2,
        style: LayoutStyle(height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20), firstBaseline: 12)
    )
    let image = LayoutInputSnapshot(
        identity: 3,
        style: LayoutStyle(height: .points(30)),
        content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 40, height: 30))
    )
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(alignItems: .baseline, width: .points(100), height: .points(40)),
        children: [text, image]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 40))

    #expect(result.placement(for: 2)?.frame.origin.y == 0)
    #expect(result.placement(for: 3)?.frame.origin.y == 0)
}

@Test
func test_baselineAlignment_alignSelfOverridesParentAlignment() {
    let baselineChild = LayoutInputSnapshot(
        identity: 2,
        style: LayoutStyle(alignSelf: .baseline, height: .points(20)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 20), firstBaseline: 12)
    )
    let sibling = LayoutInputSnapshot(
        identity: 3,
        style: LayoutStyle(height: .points(30)),
        content: LayoutContentMetrics(
            intrinsic: MeasuredSize(width: 40, height: 30), firstBaseline: 20)
    )
    let root = LayoutInputSnapshot(
        identity: 1,
        style: LayoutStyle(alignItems: .end, width: .points(100), height: .points(40)),
        children: [baselineChild, sibling]
    )

    let result = FlexSolver.layoutContainer(input: root, frame: LayoutFrame(width: 100, height: 40))

    #expect(result.placement(for: 2)?.frame.origin.y == 8)
    #expect(result.placement(for: 3)?.frame.origin.y == 10)
}

@MainActor
private final class MeasurableTextBackend: TextLayoutBackend {
    private(set) var constraints: [SizeConstraint] = []

    func measure(_ input: TextLayoutInput) -> TextMetrics {
        constraints.append(input.constraint)
        let constrained = input.constraint.width != .unspecified
        return TextMetrics(
            size: MeasuredSize(width: constrained ? 100 : 200, height: constrained ? 40 : 20),
            firstBaseline: 15,
            lineCount: constrained ? 2 : 1
        )
    }

    func display(_ input: TextLayoutInput, generation: UInt64) async throws -> TextDisplayResult {
        TextDisplayResult(
            renderedText: input.text,
            metrics: measure(input),
            generation: generation
        )
    }
}

@Test
@MainActor
func test_snapshotBuilder_usesMeasurableNodeIntrinsicAndConstraint() {
    let backend = MeasurableTextBackend()
    let node = TextNode(text: "constrained text", backend: backend)

    let snapshot = node.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .atMost(100), height: .unspecified)
    )

    #expect(snapshot.content.intrinsic.height == 40)
    #expect(snapshot.content.firstBaseline == 15)
    #expect(backend.constraints.contains(SizeConstraint(width: .atMost(100), height: .unspecified)))
}
