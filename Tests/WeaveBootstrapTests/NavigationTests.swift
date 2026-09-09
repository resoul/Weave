import Testing
import Weave

private enum NavigationRoute: String, Route {
    case detail
    var path: String { rawValue }
}

@Test
@MainActor
func navigationPushPopOwnsChildrenAndPublishesStack() {
    let navigation = NavigationController<NavigationRoute>()
    let first = Controller<Node, Never, NavigationRoute>(node: Node())
    let second = Controller<Node, Never, NavigationRoute>(node: Node())

    #expect(navigation.pop() == nil)
    #expect(navigation.push(first))
    #expect(navigation.containerNode.subnodes.first === first.node)
    #expect(!navigation.push(first))
    #expect(navigation.push(second))
    #expect(navigation.stack.count == 2)
    #expect(navigation.containerNode.subnodes.first === second.node)
    #expect(first.node.supernode == nil)
    #expect(navigation.pop() === second)
    #expect(second.isDisposed)
    #expect(navigation.stack.count == 1)
    #expect(navigation.containerNode.subnodes.first === first.node)
    #expect(navigation.popToRoot() == 0)
    navigation.dispose()
    #expect(first.isDisposed)
}

@Test
@MainActor
func navigationRestoresPreviousFocusAfterPopAndDismissIsIdempotent() {
    let focus = FocusTree()
    let navigation = NavigationController<NavigationRoute>(focusTree: focus)
    let firstNode = Node()
    let first = Controller<Node, Never, NavigationRoute>(node: firstNode)
    let second = Controller<Node, Never, NavigationRoute>(node: Node())
    focus.register(firstNode, focusable: FocusableSpec())

    #expect(navigation.push(first))
    #expect(focus.moveFocus(to: firstNode))
    #expect(navigation.push(second))
    #expect(!focus.moveFocus(to: second.node))
    _ = navigation.dismiss()
    #expect(navigation.stack.count == 1)
    #expect(focus.focusedNode === firstNode)
    #expect(navigation.dismiss() === first)
}

@Test
@MainActor
func navigationTransitionCancellationLeavesOneActiveScreen() {
    let navigation = NavigationController<NavigationRoute>()
    let first = Controller<Node, Never, NavigationRoute>(node: Node())
    let second = Controller<Node, Never, NavigationRoute>(node: Node())
    #expect(navigation.push(first))
    navigation.cancelTransition()
    #expect(navigation.transitionState == .idle)
    #expect(navigation.push(second))
    #expect(navigation.stack.count == 2)
    #expect(!first.isDisposed)
    navigation.dispose()
}
