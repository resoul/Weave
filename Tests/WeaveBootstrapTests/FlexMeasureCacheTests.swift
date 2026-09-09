import Testing
import Weave

private func cacheKey(_ identity: UInt64, revision: UInt64 = 0, width: Double = 100)
    -> LayoutMeasureCacheKey
{
    LayoutMeasureCacheKey(
        treeIdentity: identity,
        contentRevision: revision,
        environmentRevision: 0,
        constraint: SizeConstraint(width: .exact(width)),
        direction: .leftToRight
    )
}

private func cachedResult(for key: LayoutMeasureCacheKey) -> FlexMeasureResult {
    FlexMeasureResult(parentSize: MeasuredSize(width: 1, height: 1), lines: [], cacheKey: key)
}

@Test
func test_measureCache_hitOnUnchangedSubtree_skipsRecursion() {
    let leaf = LayoutInputSnapshot(
        identity: 2, style: LayoutStyle(width: .points(40), height: .points(20)))
    let root = LayoutInputSnapshot(
        identity: 1, style: LayoutStyle(width: .points(100)), children: [leaf])
    var cache = FlexMeasureCache()

    let first = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(100)), cache: &cache)
    let second = FlexSolver.measureContainer(
        input: root, constraint: SizeConstraint(width: .exact(100)), cache: &cache)

    #expect(first == second)
    #expect(cache.lookup(key: first.cacheKey) == first)
}

@Test
func test_measureCache_missOnContentRevisionChange() {
    let firstInput = LayoutInputSnapshot(identity: 1, contentRevision: 1)
    let secondInput = LayoutInputSnapshot(identity: 1, contentRevision: 2)
    var cache = FlexMeasureCache()

    let first = FlexSolver.measureContainer(input: firstInput, cache: &cache)
    let second = FlexSolver.measureContainer(input: secondInput, cache: &cache)

    #expect(first.cacheKey != second.cacheKey)
    #expect(cache.lookup(key: first.cacheKey) == first)
    #expect(cache.lookup(key: second.cacheKey) == second)
}

@Test
func test_measureCache_missOnConstraintChange() {
    let input = LayoutInputSnapshot(identity: 1, style: LayoutStyle(width: .auto))
    var cache = FlexMeasureCache()

    let narrow = FlexSolver.measureContainer(
        input: input, constraint: SizeConstraint(width: .exact(100)), cache: &cache)
    let wide = FlexSolver.measureContainer(
        input: input, constraint: SizeConstraint(width: .exact(200)), cache: &cache)

    #expect(narrow.cacheKey != wide.cacheKey)
    #expect(cache.lookup(key: narrow.cacheKey) == narrow)
    #expect(cache.lookup(key: wide.cacheKey) == wide)
}

@Test
func test_measureCache_LRU_evictsOldestOnOverflow_deterministic() {
    var cache = FlexMeasureCache()
    for identity in 0..<65 {
        let key = cacheKey(UInt64(identity))
        cache.store(key: key, result: cachedResult(for: key))
    }

    #expect(cache.lookup(key: cacheKey(0)) == nil)
    #expect(cache.lookup(key: cacheKey(1)) != nil)
    #expect(cache.lookup(key: cacheKey(64)) != nil)
}

@Test
@MainActor
func test_layoutEngine_createsNewCachePerRequest() async {
    actor Probe {
        var coldRequests = 0
        func record(cold: Bool) { if cold { coldRequests += 1 } }
    }
    let probe = Probe()
    let input = LayoutInputSnapshot(identity: 1)
    let engine = LayoutEngine(solver: { input, frame, _, cache in
        let key = LayoutMeasureCacheKey(
            treeIdentity: input.identity,
            contentRevision: input.contentRevision,
            environmentRevision: input.environmentRevision,
            constraint: SizeConstraint(width: .exact(frame.width), height: .exact(frame.height)),
            direction: input.direction
        )
        let cold = cache.lookup(key: key) == nil
        cache.store(key: key, result: cachedResult(for: key))
        Task { await probe.record(cold: cold) }
        return LayoutResult(
            placements: [LayoutPlacement(identity: input.identity, frame: frame)],
            treeIdentity: input.identity,
            environmentRevision: input.environmentRevision,
            contentRevision: input.contentRevision
        )
    })
    engine.request(input: input, frame: LayoutFrame(width: 100, height: 100))
    for _ in 0..<20 { await Task.yield() }
    engine.request(input: input, frame: LayoutFrame(width: 100, height: 100))
    for _ in 0..<20 { await Task.yield() }

    #expect(await probe.coldRequests == 2)
}
