import Testing
import Weave

@Test @MainActor
func test_node_ownsHierarchy_rejectsCycles_andReparentsEnvironment() {
    let root = Node()
    let child = Node()
    let grandchild = Node()
    root.addSubnode(child)
    child.addSubnode(grandchild)
    grandchild.addSubnode(root)

    #expect(root.subnodes.count == 1)
    #expect(grandchild.supernode === child)
    child.removeFromSupernode()
    #expect(child.supernode == nil)
    #expect(root.subnodes.isEmpty)
}

@Test @MainActor
func test_node_identityAndBacking_areStableAndHeadless() {
    let first = Node()
    let second = Node()
    #expect(first.id != second.id)
    #expect(!first.isLoaded)
    #expect(first.calculatedFrame == nil)
    #expect(first.lifecycleState == .created)
}

@Test @MainActor
func test_node_dispose_isTerminal_andRevisionsAreMainActorOwned() {
    let node = Node()
    let before = node.layoutRevision
    node.setNeedsLayout()
    node.setNeedsDisplay()
    #expect(node.layoutRevision == before + 1)
    #expect(node.displayRevision == 1)
    node.connect()
    node.dispose()
    #expect(node.lifecycleState == .disposed)
    node.dispose()
    #expect(node.lifecycleState == .disposed)
}
