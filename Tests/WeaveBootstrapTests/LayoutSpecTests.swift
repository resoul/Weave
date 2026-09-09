import Testing
import Weave

@Test
func test_layoutSpecs_measureNestedStackAndInsets_inBothDirections() {
    let stack = StackSpec(
        axis: .horizontal,
        spacing: 4,
        children: [
            WrapperSpec(child: EmptySpec()),
            RatioSpec(ratio: 2, child: FixedSpec(size: MeasuredSize(width: 20, height: 0))),
        ])
    let spec = InsetSpec(insets: DirectionalEdgeInsets(leading: 3, trailing: 5), child: stack)
    #expect(
        spec.measure(in: LayoutSpecContext(direction: .leftToRight))
            == MeasuredSize(width: 32, height: 10))
    #expect(
        spec.measure(in: LayoutSpecContext(direction: .rightToLeft))
            == MeasuredSize(width: 32, height: 10))
}

@Test
func test_layoutSpecs_emptyOverlayAndBackground_haveDeterministicConstraints() {
    let base = FixedSpec(size: MeasuredSize(width: 30, height: 12))
    #expect(
        OverlaySpec(child: base, overlay: FixedSpec(size: MeasuredSize(width: 40, height: 8)))
            .measure(in: LayoutSpecContext()) == MeasuredSize(width: 40, height: 12))
    #expect(
        BackgroundSpec(child: base, background: EmptySpec()).measure(in: LayoutSpecContext())
            == MeasuredSize(width: 30, height: 12))
    #expect(EmptySpec().measure(in: LayoutSpecContext()) == MeasuredSize(width: 0, height: 0))
}

private struct FixedSpec: LayoutSpec, Hashable {
    let size: MeasuredSize
    func measure(in context: LayoutSpecContext) -> MeasuredSize { size }
}
