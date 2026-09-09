import Testing
import Weave

@MainActor
private final class FocusNode: Node {
    let label: String
    var received: [EventType] = []
    override var focusable: FocusableSpec? { FocusableSpec() }

    init(_ label: String) {
        self.label = label
        super.init()
    }

    override func handleEvent(_ event: Event) {
        received.append(event.type)
    }
}

@MainActor
private func applyFocusFrames(_ nodes: [Node]) {
    let result = LayoutResult(
        placements: nodes.enumerated().map { index, node in
            LayoutPlacement(
                identity: node.id,
                frame: LayoutFrame(
                    origin: LayoutPoint(x: Double(index * 100), y: 0),
                    width: 80,
                    height: 80
                )
            )
        },
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    for node in nodes { node.apply(result) }
}

@Test
@MainActor
func focusTreeMovesDirectionallyAndPublishesEvents() {
    let first = FocusNode("first")
    let second = FocusNode("second")
    applyFocusFrames([first, second])
    let tree = FocusTree()
    tree.register(first, focusable: FocusableSpec())
    tree.register(second, focusable: FocusableSpec())

    #expect(tree.moveFocus(to: first))
    #expect(tree.moveFocus(direction: .right))
    #expect(tree.focusedNode === second)
    #expect(first.received == [.focusIn, .focusOut])
    #expect(second.received == [.focusIn])
}

@Test
@MainActor
func focusTreeHonorsPreferredOverrideAndFallbackAfterRemoval() {
    let first = FocusNode("first")
    let second = FocusNode("second")
    let third = FocusNode("third")
    applyFocusFrames([first, second, third])
    let tree = FocusTree()
    tree.register(
        first,
        focusable: FocusableSpec(preferredNextFocus: [.right: third.id])
    )
    tree.register(second, focusable: FocusableSpec(priority: 10))
    tree.register(third, focusable: FocusableSpec())

    #expect(tree.moveFocus(to: first))
    #expect(tree.moveFocus(direction: .right))
    #expect(tree.focusedNode === third)
    tree.unregister(third)
    #expect(tree.focusedNode === second)
}

@Test
@MainActor
func focusTreeSkipsHiddenAndReturnsFalseAtDirectionalEdge() {
    let first = FocusNode("first")
    let hidden = FocusNode("hidden")
    hidden.semantics = NodeSemantics(isHidden: true)
    applyFocusFrames([first, hidden])
    let tree = FocusTree()
    tree.register(first, focusable: FocusableSpec())
    tree.register(hidden, focusable: FocusableSpec())

    #expect(tree.moveFocus(to: first))
    #expect(!tree.moveFocus(direction: .right))
    #expect(tree.lastTrace?.selected == nil)
}

@Test
@MainActor
func focusTreeRestrictsModalTraversalAndRestoresPreviousFocus() {
    let root = Node()
    let background = FocusNode("background")
    let modal = Node()
    let confirm = FocusNode("confirm")
    let cancel = FocusNode("cancel")
    root.addSubnode(background)
    root.addSubnode(modal)
    modal.addSubnode(confirm)
    modal.addSubnode(cancel)
    applyFocusFrames([background, confirm, cancel])

    let tree = FocusTree()
    tree.register(background, focusable: FocusableSpec())
    tree.register(confirm, focusable: FocusableSpec())
    tree.register(cancel, focusable: FocusableSpec())
    #expect(tree.moveFocus(to: background))

    tree.setModalRoot(modal)
    #expect(tree.focusedNode === confirm)
    #expect(!tree.moveFocus(to: background))
    #expect(tree.moveFocus(direction: .right))
    #expect(tree.focusedNode === cancel)

    tree.setModalRoot(nil)
    #expect(tree.focusedNode === background)
}
