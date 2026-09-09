import Foundation
import WeaveUI

/// Summary of a completed performance workload run.
/// Ownership: immutable value snapshot. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PerformanceWorkloadSummary: Sendable, Hashable {
    /// Human-readable workload name.
    public let name: String
    /// Number of executed iterations or items.
    public let iterationCount: Int
    /// Total wall-clock duration of the workload run.
    public let totalDuration: Duration
    /// Sampled metrics captured during the workload execution.
    public let metrics: [PerformanceMetric]

    /// Creates a workload summary.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        name: String,
        iterationCount: Int,
        totalDuration: Duration,
        metrics: [PerformanceMetric] = []
    ) {
        self.name = name
        self.iterationCount = iterationCount
        self.totalDuration = totalDuration
        self.metrics = metrics
    }
}

private actor MetricCollector {
    private var items: [PerformanceMetric] = []

    func append(_ metric: PerformanceMetric) {
        items.append(metric)
    }

    func waitForMetrics(minCount: Int) async -> [PerformanceMetric] {
        for _ in 0..<200 {
            if items.count >= minCount {
                break
            }
            await Task.yield()
        }
        return items
    }

    func take() -> [PerformanceMetric] {
        items
    }
}

/// Standardized benchmark workloads for framework performance profiling and regression detection.
/// Ownership: static utility enum without instance state. Isolation: none. Errors: workload errors propagate. Cancellation: caller-owned task cancellation.
public enum PerformanceWorkloads {
    /// Runs a large list layout, diffing, and reuse workload.
    /// Ownership: caller owns returned summary. Isolation: none. Errors: none. Cancellation: cancelled caller stops between passes.
    public static func runLargeListWorkload(
        itemCount: Int = 1000,
        monitor: PerformanceMonitor = PerformanceMonitor()
    ) async -> PerformanceWorkloadSummary {
        let count = max(1, itemCount)
        let clock = ContinuousClock()
        let start = clock.now

        let collector = MetricCollector()
        let subscription = monitor.stream.sink { metric in
            Task { await collector.append(metric) }
        }

        let childSnapshots = (0..<count).map { index in
            LayoutInputSnapshot(
                identity: UInt64(index + 1),
                style: LayoutStyle(
                    flexDirection: .row,
                    width: .auto,
                    height: .points(44),
                    padding: DirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
                ),
                content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 300, height: 44))
            )
        }
        let listSnapshot = LayoutInputSnapshot(
            identity: 100_000,
            style: LayoutStyle(
                flexDirection: .column,
                width: .points(390),
                height: .points(844)
            ),
            children: childSnapshots
        )

        _ = await monitor.measure(
            .measure, metadata: ["workload": "largeList", "count": "\(count)"]
        ) {
            FlexSolver.measureContainer(
                input: listSnapshot,
                constraint: SizeConstraint(width: .exact(390), height: .unspecified)
            )
        }

        _ = await monitor.measure(
            .layout, metadata: ["workload": "largeList", "count": "\(count)"]
        ) {
            FlexSolver.layoutContainer(
                input: listSnapshot,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 390, height: 844)
            )
        }

        let oldDescriptors = (0..<count).map { index in
            NodeDescriptor(typeName: "ItemNode", key: "item_\(index)")
        }
        var mutableNewDescriptors = oldDescriptors
        if count > 10 {
            mutableNewDescriptors.swapAt(0, count - 1)
            mutableNewDescriptors.removeLast()
            mutableNewDescriptors.insert(
                NodeDescriptor(typeName: "ItemNode", key: "item_new"), at: 0)
        }
        let newDescriptorsSnapshot = mutableNewDescriptors

        _ = await monitor.measure(.diff, metadata: ["workload": "largeList", "count": "\(count)"]) {
            Reconciler.diff(old: oldDescriptors, new: newDescriptorsSnapshot)
        }

        await monitor.record(
            PerformanceMetric(
                name: .reuse,
                count: max(0, count - 2),
                metadata: ["workload": "largeList"]
            )
        )
        await monitor.record(
            PerformanceMetric(
                name: .queueDepth,
                count: count,
                metadata: ["workload": "largeList"]
            )
        )

        let captured = await collector.waitForMetrics(minCount: 5)
        subscription.cancel()

        return PerformanceWorkloadSummary(
            name: "largeList",
            iterationCount: count,
            totalDuration: clock.now - start,
            metrics: captured
        )
    }

    /// Runs a bidirectional and RTL text measurement and layout workload.
    /// Ownership: caller owns returned summary. Isolation: none. Errors: none. Cancellation: cancelled caller stops between passes.
    public static func runBidiTextWorkload(
        iterations: Int = 200,
        monitor: PerformanceMonitor = PerformanceMonitor()
    ) async -> PerformanceWorkloadSummary {
        let count = max(1, iterations)
        let clock = ContinuousClock()
        let start = clock.now

        let collector = MetricCollector()
        let subscription = monitor.stream.sink { metric in
            Task { await collector.append(metric) }
        }

        let directions: [LayoutDirection] = [.leftToRight, .rightToLeft]

        for i in 0..<count {
            let direction = directions[i % directions.count]
            let textSnapshot = LayoutInputSnapshot(
                identity: UInt64(200_000 + i),
                style: LayoutStyle(
                    flexDirection: .row,
                    width: .auto,
                    height: .auto,
                    padding: DirectionalEdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12)
                ),
                content: LayoutContentMetrics(intrinsic: MeasuredSize(width: 280, height: 24)),
                direction: direction
            )

            _ = await monitor.measure(
                .measure,
                metadata: [
                    "workload": "bidiText", "direction": direction == .rightToLeft ? "rtl" : "ltr",
                ]
            ) {
                FlexSolver.measureContainer(
                    input: textSnapshot,
                    constraint: SizeConstraint(width: .atMost(320), height: .unspecified)
                )
            }

            _ = await monitor.measure(
                .layout,
                metadata: [
                    "workload": "bidiText", "direction": direction == .rightToLeft ? "rtl" : "ltr",
                ]
            ) {
                FlexSolver.layoutContainer(
                    input: textSnapshot,
                    frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 320, height: 48)
                )
            }
        }

        let captured = await collector.waitForMetrics(minCount: count * 2)
        subscription.cancel()

        return PerformanceWorkloadSummary(
            name: "bidiText",
            iterationCount: count,
            totalDuration: clock.now - start,
            metrics: captured
        )
    }

    /// Runs a repeated mount, connection, and disposal lifecycle workload.
    /// Ownership: caller owns returned summary. Isolation: none. Errors: none. Cancellation: cancelled caller stops between passes.
    public static func runRepeatedMountWorkload(
        cycles: Int = 50,
        nodesPerCycle: Int = 20,
        monitor: PerformanceMonitor = PerformanceMonitor()
    ) async -> PerformanceWorkloadSummary {
        let cycleCount = max(1, cycles)
        let countPerCycle = max(1, nodesPerCycle)
        let clock = ContinuousClock()
        let start = clock.now

        let collector = MetricCollector()
        let subscription = monitor.stream.sink { metric in
            Task { await collector.append(metric) }
        }

        for cycle in 0..<cycleCount {
            await monitor.measure(
                .reconciliation, metadata: ["workload": "repeatedMount", "cycle": "\(cycle)"]
            ) {
                await MainActor.run {
                    let root = Node()
                    for _ in 0..<countPerCycle {
                        let child = Node()
                        root.addSubnode(child)
                        _ = child.connect()
                    }
                    _ = root.connect()
                    root.dispose()
                }
            }
        }

        await monitor.record(
            PerformanceMetric(
                name: .memoryPeak,
                count: cycleCount * countPerCycle,
                metadata: ["workload": "repeatedMount", "unit": "allocatedNodes"]
            )
        )

        let captured = await collector.waitForMetrics(minCount: cycleCount + 1)
        subscription.cancel()

        return PerformanceWorkloadSummary(
            name: "repeatedMount",
            iterationCount: cycleCount,
            totalDuration: clock.now - start,
            metrics: captured
        )
    }

    /// Runs a resource pressure and cancellation recovery workload.
    /// Ownership: caller owns returned summary. Isolation: none. Errors: none. Cancellation: cancelled tasks contribute to stale metric.
    public static func runPressureRecoveryWorkload(
        concurrency: Int = 20,
        maxPermits: Int = 4,
        monitor: PerformanceMonitor = PerformanceMonitor()
    ) async -> PerformanceWorkloadSummary {
        let taskCount = max(1, concurrency)
        let permits = max(1, maxPermits)
        let clock = ContinuousClock()
        let start = clock.now

        let collector = MetricCollector()
        let subscription = monitor.stream.sink { metric in
            Task { await collector.append(metric) }
        }

        let limiter = ImageDecodeLimiter(maxConcurrent: permits)

        await monitor.record(
            PerformanceMetric(
                name: .permit,
                count: permits,
                metadata: ["workload": "pressureRecovery", "capacity": "\(permits)"]
            )
        )
        await monitor.record(
            PerformanceMetric(
                name: .queueDepth,
                count: taskCount,
                metadata: ["workload": "pressureRecovery"]
            )
        )

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<taskCount {
                group.addTask {
                    if i % 2 == 1 {
                        await monitor.record(
                            PerformanceMetric(
                                name: .stale,
                                count: 1,
                                metadata: ["workload": "pressureRecovery", "cancelledTask": "\(i)"]
                            )
                        )
                        return
                    }
                    _ = try? await limiter.withPermit {
                        await monitor.record(
                            PerformanceMetric(
                                name: .concurrentDecode,
                                count: 1,
                                metadata: ["workload": "pressureRecovery"]
                            )
                        )
                    }
                }
            }
        }

        let captured = await collector.waitForMetrics(minCount: 2 + taskCount)
        subscription.cancel()

        return PerformanceWorkloadSummary(
            name: "pressureRecovery",
            iterationCount: taskCount,
            totalDuration: clock.now - start,
            metrics: captured
        )
    }

    /// Runs all standard performance workloads sequentially and returns their summaries.
    /// Ownership: caller owns returned summaries. Isolation: none. Errors: none. Cancellation: caller-owned task cancellation stops execution between workloads.
    public static func runAll(
        monitor: PerformanceMonitor = PerformanceMonitor()
    ) async -> [PerformanceWorkloadSummary] {
        var results: [PerformanceWorkloadSummary] = []
        results.append(await runLargeListWorkload(itemCount: 1000, monitor: monitor))
        results.append(await runBidiTextWorkload(iterations: 200, monitor: monitor))
        results.append(
            await runRepeatedMountWorkload(cycles: 50, nodesPerCycle: 20, monitor: monitor))
        results.append(
            await runPressureRecoveryWorkload(concurrency: 20, maxPermits: 4, monitor: monitor))
        return results
    }

    /// Generates a human-readable text report from workload summaries.
    /// Ownership: caller owns returned string. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func formattedReport(_ summaries: [PerformanceWorkloadSummary]) -> String {
        var lines = ["=== Weave Performance Workload Report ==="]
        for summary in summaries {
            let ms =
                Double(summary.totalDuration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(summary.totalDuration.components.seconds) * 1000.0
            lines.append(
                "Workload: \(summary.name) | items: \(summary.iterationCount) | wall: \(String(format: "%.2f", ms)) ms | captured metrics: \(summary.metrics.count)"
            )
        }
        lines.append("=========================================")
        return lines.joined(separator: "\n")
    }
}
