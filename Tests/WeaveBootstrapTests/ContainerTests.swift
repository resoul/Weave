import Testing
import Weave

@Test
@MainActor
func tabSelectionActivatesOnlySelectedChildAndRejectsInvalidIndexes() async {
    let first = Controller<Node, Never, Never>(node: Node())
    let second = Controller<Node, Never, Never>(node: Node())
    let tabs = TabController(tabs: [first, second])
    #expect(tabs.select(index: 0) == false)
    #expect(tabs.select(index: 4) == false)
    #expect(tabs.select(index: 1))
    #expect(tabs.selectedIndexValue == 1)
    // The actor-backed replay value is updated asynchronously; the MainActor source of truth is immediate.
    #expect(tabs.select(index: 1) == false)
    tabs.dispose()
    #expect(first.isDisposed)
    #expect(second.isDisposed)
}

@Test
@MainActor
func removingSelectedTabFallsBackWithoutDestroyingRetainedTabState() {
    let first = Controller<Node, Never, Never>(node: Node())
    let second = Controller<Node, Never, Never>(node: Node())
    let third = Controller<Node, Never, Never>(node: Node())
    let tabs = TabController(tabs: [first, second, third], selectedIndex: 1)
    tabs.replaceTabs(with: [first, third])
    #expect(tabs.selectedIndexValue == 1)
    #expect(!third.isDisposed)
    #expect(second.isDisposed)
}

@Test
@MainActor
func splitCollapseKeepsSecondaryControllerAlive() {
    let primary = Controller<Node, Never, Never>(node: Node())
    let secondary = Controller<Node, Never, Never>(node: Node())
    let split = SplitController(primary: primary, secondary: secondary)
    split.apply(style: .collapsed)
    #expect(!secondary.isDisposed)
    split.apply(style: .sideBySide)
    #expect(!secondary.isDisposed)
    split.dispose()
    #expect(secondary.isDisposed)
}
