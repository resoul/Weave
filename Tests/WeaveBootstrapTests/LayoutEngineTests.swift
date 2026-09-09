import Testing
import Weave

@Test @MainActor
func test_layoutEngine_appliesLatestRequest_andCarriesRevisions() async {
    var applied: [UInt64] = []
    let engine = LayoutEngine { result in applied.append(result.contentRevision) }
    let first = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(10)), contentRevision: 1)
    let second = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(20)), contentRevision: 2)
    engine.request(input: first, frame: LayoutFrame(width: 20, height: 20))
    engine.request(input: second, frame: LayoutFrame(width: 20, height: 20))
    for _ in 0..<20 where engine.applyCount == 0 { await Task.yield() }
    #expect(engine.requestCount == 2)
    #expect(applied == [2])
}

@Test @MainActor
func test_layoutEngine_cancelAndDispose_preventLateApply() async {
    var applyCount = 0
    let engine = LayoutEngine { _ in applyCount += 1 }
    let input = LayoutInputSnapshot(identity: 1, contentRevision: 1)
    engine.request(input: input, frame: LayoutFrame(width: 10, height: 10))
    engine.cancel()
    for _ in 0..<10 { await Task.yield() }
    #expect(applyCount == 0)
    engine.dispose()
    engine.request(input: input, frame: LayoutFrame(width: 10, height: 10))
    #expect(engine.requestCount == 1)
}
