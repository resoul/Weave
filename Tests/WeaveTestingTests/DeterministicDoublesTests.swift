import Testing
@testable import WeaveTesting

@MainActor
@Test
func testStoreIsDeterministicAndCountsWrites() {
    let store = TestStore(1)
    #expect(store.load() == 1)
    store.write(2)
    #expect(store.load() == 2)
    #expect(store.writeCount == 1)
}

@MainActor
@Test
func readinessDoesNotRequireSleep() async {
    let readiness = TestReadiness()
    let waiter = Task { @MainActor in await readiness.wait() }
    readiness.signal()
    await waiter.value
    readiness.finish()
}
