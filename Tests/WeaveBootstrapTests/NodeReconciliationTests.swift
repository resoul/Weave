import Testing
import Weave

@MainActor
@Test
func test_nodeReconciliationAppliesMixedPatches_andRetainsNodeIDs() {
    let parent = Node()
    let controller = NodeReconciliationController()
    let factory: @MainActor (NodeDescriptor) -> Node = { _ in Node() }
    let first = [
        NodeDescriptor(typeName: "Row", key: "a"),
        NodeDescriptor(typeName: "Row", key: "b"),
    ]
    #expect(
        controller.apply(to: parent, descriptors: first, generation: 1, factory: factory).applied
    )
    let retainedID = parent.subnodes[0].id
    let second = [
        NodeDescriptor(typeName: "Row", key: "b"),
        NodeDescriptor(typeName: "Row", key: "a"),
        NodeDescriptor(typeName: "Row", key: "c"),
    ]
    let trace = controller.apply(to: parent, descriptors: second, generation: 2, factory: factory)
    #expect(trace.applied)
    #expect(parent.subnodes.map(\.reconciliationDescriptor?.key) == ["b", "a", "c"])
    #expect(parent.subnodes[1].id == retainedID)
}

@MainActor
@Test
func test_nodeReconciliationStaleGenerationDoesNotMutate_andReplaceDisposesOnce() {
    let parent = Node()
    let controller = NodeReconciliationController()
    let factory: @MainActor (NodeDescriptor) -> Node = { _ in Node() }
    let old = [NodeDescriptor(typeName: "Row", key: "x")]
    _ = controller.apply(to: parent, descriptors: old, generation: 5, factory: factory)
    let oldNode = parent.subnodes[0]
    let replacement = [NodeDescriptor(typeName: "Card", key: "x")]
    #expect(
        controller.apply(
            to: parent, descriptors: replacement, generation: 6, factory: factory
        ).applied
    )
    #expect(oldNode.lifecycleState == .disposed)
    #expect(parent.subnodes[0].id != oldNode.id)
    let stale = controller.apply(
        to: parent, descriptors: old, generation: 5, factory: factory
    )
    #expect(stale.discardedAsStale)
    #expect(parent.subnodes[0].id != oldNode.id)
}
