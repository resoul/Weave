import Testing
import Weave

@Test
func test_sizeValues_resolvePointsFractionsAndUnspecifiedParent() {
    #expect(SizeValue.points(24).resolved(parent: nil) == 24)
    #expect(SizeValue.fraction(0.5).resolved(parent: 200) == 100)
    #expect(SizeValue.fraction(0.5).resolved(parent: nil) == nil)
    #expect(SizeValue.fraction(2).resolved(parent: 200) == nil)
}

@Test
func test_layoutStyle_appliesExactAtMostAndAspectRatio() {
    let style = LayoutStyle(width: .points(300), aspectRatio: 2)
    #expect(
        style.measured(constraint: SizeConstraint(width: .atMost(120), height: .unspecified))
            == MeasuredSize(width: 120, height: 150))
    #expect(
        LayoutStyle(height: .points(40), aspectRatio: 2).measured()
            == MeasuredSize(width: 80, height: 40))
    #expect(
        LayoutStyle(width: .points(10)).measured(constraint: SizeConstraint(width: .exact(90)))
            == MeasuredSize(width: 90, height: 0))
}

@Test
func test_directionalEdges_resolveLeadingTrailingAtLayoutTime() {
    let insets = DirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
    #expect(
        insets.resolved(for: .leftToRight)
            == PhysicalEdgeInsets(top: 1, left: 2, bottom: 3, right: 4))
    #expect(
        insets.resolved(for: .rightToLeft)
            == PhysicalEdgeInsets(top: 1, left: 4, bottom: 3, right: 2))
}

@Test
func test_geometry_invalidInputs_areSafeAndFinite() {
    #expect(MeasuredSize(width: .infinity, height: -1) == MeasuredSize(width: 0, height: 0))
    #expect(LayoutStyle(flexGrow: -.infinity, gap: .nan).flexGrow == 0)
    #expect(SizeConstraint(width: .exact(-1)).width == .unspecified)
}
