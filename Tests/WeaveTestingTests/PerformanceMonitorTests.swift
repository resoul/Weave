import Foundation
import Testing
import WeaveTesting

@Test
func disabledPerformanceMonitorDoesNotPublish() async {
    let monitor = PerformanceMonitor.disabled
    let subscription = monitor.stream.sink { _ in Issue.record("disabled monitor emitted") }
    await monitor.record(PerformanceMetric(name: .layout, count: 1))
    subscription.cancel()
}

@Test
func performanceMonitorMeasuresMonotonicSpan() async throws {
    let monitor = PerformanceMonitor()
    let values = LockedMetrics()
    let subscription = monitor.stream.sink { values.append($0) }
    let result = await monitor.measure(.decode, metadata: ["source": "test"]) {
        42
    }
    for _ in 0..<20 { await Task.yield() }
    subscription.cancel()
    #expect(result == 42)
    #expect(values.items.first?.name == .decode)
    #expect(values.items.first?.duration != nil)
    #expect(values.items.first?.metadata["source"] == "test")
}

@Test
func performanceMonitorSamplingAndBufferAreBounded() async {
    let monitor = PerformanceMonitor(capacity: 2, sampling: .every(2))
    var iterator = monitor.stream.stream.makeAsyncIterator()
    for index in 1...10 { await monitor.record(PerformanceMetric(name: .reuse, count: index)) }
    let first = await iterator.next()
    let second = await iterator.next()
    #expect(first?.count == 8)
    #expect(second?.count == 10)
}

private final class LockedMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [PerformanceMetric] = []

    func append(_ metric: PerformanceMetric) { lock.withLock { items.append(metric) } }
}
