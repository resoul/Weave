import Testing
@testable import Weave

@MainActor
@Test
func keyedStateSurvivesReorderAndDropsRemovedIDs() {
    let store = KeyedItemStateStore<String, Int>()
    store.setState(42, for: "item")
    store.setState(7, for: "stale")
    store.retainOnly(["item"])
    #expect(store.state(for: "item") == 42)
    #expect(store.state(for: "stale") == nil)
}

@MainActor
@Test
func itemDemandCancellationIsOwnerScopedAndIdempotent() {
    let store = KeyedItemStateStore<String, Int>()
    var cancellations = 0
    let demand = store.beginDemand(for: "item") { cancellations += 1 }
    demand.cancel()
    demand.cancel()
    #expect(cancellations == 1)
    let replacement = store.beginDemand(for: "item") { cancellations += 1 }
    store.remove("item")
    replacement.cancel()
    #expect(cancellations == 2)
}
