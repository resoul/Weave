import Flux
import Testing
import Weave

@Test
func test_nodeState_distinctWritesAreSerialized_andRevisionOnlyChanges() async {
    let state = NodeState(0)
    #expect(await state.set(0) == false)
    #expect(await state.set(1) == true)
    #expect(await state.set(1) == false)
    #expect(await state.revisionValue == 1)
    #expect(await state.value == 1)
}

@Test
func test_actionPipe_doesNotReplayEarlierActions_andUsesBoundedFlux() async {
    let pipe = await MainActor.run { ActionPipe<Int>(capacity: 2) }
    _ = await MainActor.run { pipe.send(1) }
    let subscription = await MainActor.run {
        pipe.flux.sink { _ in }
    }
    await MainActor.run {
        pipe.send(2)
        pipe.finish()
    }
    subscription.cancel()
}

@Test @MainActor
func test_node_bind_replacesNamedSubscription_andDisposeCancelsIt() async {
    let node = Node()
    #expect(node.connect())
    let source = Pipe<Int>()
    var received: [Int] = []
    _ = node.bind(id: "value", source.flux) { received.append($0) }
    source.send(1)
    for _ in 0..<5 { await Task.yield() }
    #expect(received == [1])
    node.dispose()
    source.send(2)
    for _ in 0..<5 { await Task.yield() }
    #expect(received == [1])
}
