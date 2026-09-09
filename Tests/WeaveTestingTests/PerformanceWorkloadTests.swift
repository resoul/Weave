import Foundation
import Testing
import Weave
import WeaveTesting

@Test
func largeListWorkloadEmitsExpectedMetrics() async {
    let monitor = PerformanceMonitor(capacity: 100, sampling: .all)
    let summary = await PerformanceWorkloads.runLargeListWorkload(itemCount: 100, monitor: monitor)

    #expect(summary.name == "largeList")
    #expect(summary.iterationCount == 100)
    #expect(summary.totalDuration > .zero)

    let metricNames = Set(summary.metrics.map(\.name))
    #expect(metricNames.contains(.measure))
    #expect(metricNames.contains(.layout))
    #expect(metricNames.contains(.diff))
    #expect(metricNames.contains(.reuse))
    #expect(metricNames.contains(.queueDepth))
}

@Test
func bidiTextWorkloadEmitsDirectionalMetrics() async {
    let monitor = PerformanceMonitor(capacity: 500, sampling: .all)
    let summary = await PerformanceWorkloads.runBidiTextWorkload(iterations: 20, monitor: monitor)

    #expect(summary.name == "bidiText")
    #expect(summary.iterationCount == 20)
    #expect(summary.totalDuration > .zero)

    let directions = summary.metrics.compactMap { $0.metadata["direction"] }
    #expect(directions.contains("rtl"))
    #expect(directions.contains("ltr"))
}

@Test
func repeatedMountWorkloadExecutesLifecycleCleanly() async {
    let monitor = PerformanceMonitor(capacity: 100, sampling: .all)
    let summary = await PerformanceWorkloads.runRepeatedMountWorkload(
        cycles: 10, nodesPerCycle: 5, monitor: monitor)

    #expect(summary.name == "repeatedMount")
    #expect(summary.iterationCount == 10)
    #expect(summary.totalDuration > .zero)

    let metricNames = Set(summary.metrics.map(\.name))
    #expect(metricNames.contains(.reconciliation))
    #expect(metricNames.contains(.memoryPeak))
}

@Test
func pressureRecoveryWorkloadLimitsConcurrencyAndCancelsStale() async {
    let monitor = PerformanceMonitor(capacity: 100, sampling: .all)
    let summary = await PerformanceWorkloads.runPressureRecoveryWorkload(
        concurrency: 10, maxPermits: 2, monitor: monitor)

    #expect(summary.name == "pressureRecovery")
    #expect(summary.iterationCount == 10)
    #expect(summary.totalDuration > .zero)

    let metricNames = Set(summary.metrics.map(\.name))
    #expect(metricNames.contains(.permit))
    #expect(metricNames.contains(.queueDepth))
    #expect(metricNames.contains(.stale))
}

@Test
func runAllAndFormattedReportProduceReadableSummary() async {
    let monitor = PerformanceMonitor(capacity: 500, sampling: .all)
    let summaries = await PerformanceWorkloads.runAll(monitor: monitor)

    #expect(summaries.count == 4)
    let report = PerformanceWorkloads.formattedReport(summaries)
    #expect(report.contains("=== Weave Performance Workload Report ==="))
    #expect(report.contains("largeList"))
    #expect(report.contains("bidiText"))
    #expect(report.contains("repeatedMount"))
    #expect(report.contains("pressureRecovery"))
    print(report)
}
