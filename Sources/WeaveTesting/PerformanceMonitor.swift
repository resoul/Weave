import Flux

/// Framework performance spans and counters.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PerformanceMetricName: String, Sendable, Hashable {
    case measure, layout, apply, display, reconciliation, diff, decode, stale, reuse
    case queueDepth, concurrentDecode, memoryPeak, permit
}

/// Deterministic sampling policy for bounded diagnostics.
/// Ownership: immutable value. Isolation: none. Errors: invalid intervals normalize. Cancellation: not applicable.
public enum PerformanceSampling: Sendable, Hashable {
    case disabled
    case every(Int)
    case all

    var interval: Int? {
        switch self {
        case .disabled: return nil
        case let .every(value): return max(1, value)
        case .all: return 1
        }
    }
}

/// Immutable performance record with explicit units.
/// Ownership: record owns copied metadata. Isolation: none. Errors: none. Cancellation: not applicable.
public struct PerformanceMetric: Sendable, Hashable {
    public let name: PerformanceMetricName
    public let duration: Duration?
    public let count: Int?
    public let metadata: [String: String]

    /// Creates a metric record. Duration is monotonic elapsed time; count is a unitless integer.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        name: PerformanceMetricName,
        duration: Duration? = nil,
        count: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.name = name
        self.duration = duration
        self.count = count
        self.metadata = metadata
    }
}

/// Bounded actor-owned performance monitor backed by Flux.
/// Ownership: monitor owns its pipe and sampling state. Isolation: actor. Errors: none from recording. Cancellation: stream subscribers own cancellation.
public actor PerformanceMonitor {
    /// A disabled monitor that publishes no records.
    public static let disabled = PerformanceMonitor(enabled: false, sampling: .disabled)

    private let enabled: Bool
    private let sampling: PerformanceSampling
    private let pipe: Pipe<PerformanceMetric>
    private var sequence = 0

    /// Bounded stream of sampled metrics.
    /// Ownership: subscribers own their Flux subscription. Isolation: nonisolated stream. Errors: none. Cancellation: cancelling a subscription detaches it.
    public nonisolated var stream: Flux<PerformanceMetric> { pipe.flux }

    /// Creates a monitor with explicit bounded buffering and sampling overhead.
    /// Ownership: monitor retains immutable policy. Isolation: actor. Errors: capacity values below one normalize. Cancellation: no work starts during initialization.
    public init(
        enabled: Bool = true,
        capacity: Int = 256,
        sampling: PerformanceSampling = .all
    ) {
        self.enabled = enabled
        self.sampling = sampling
        self.pipe = Pipe(bufferingPolicy: .bufferingNewest(max(1, capacity)))
    }

    /// Records a span or counter according to the sampling policy.
    /// Ownership: metric is copied into bounded subscribers. Isolation: actor. Errors: none. Cancellation: cancelled callers may skip recording.
    public func record(_ metric: PerformanceMetric) {
        guard enabled, let interval = sampling.interval else { return }
        sequence &+= 1
        guard sequence % interval == 0 else { return }
        pipe.send(metric)
    }

    /// Records elapsed monotonic time around an async operation and preserves its result/error.
    /// Ownership: operation remains caller-owned. Isolation: actor around bookkeeping. Errors: operation errors are rethrown unchanged. Cancellation: cancellation propagates to the operation.
    public func measure<T: Sendable>(
        _ name: PerformanceMetricName,
        metadata: [String: String] = [:],
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        guard enabled, sampling.interval != nil else { return try await operation() }
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let value = try await operation()
            record(PerformanceMetric(name: name, duration: clock.now - start, metadata: metadata))
            return value
        } catch {
            record(PerformanceMetric(name: name, duration: clock.now - start, metadata: metadata))
            throw error
        }
    }

    /// Finishes the metric stream; subsequent records are ignored by terminated subscribers.
    /// Ownership: monitor releases its stream continuation. Isolation: actor. Errors: none. Cancellation: subscribers complete.
    public func finish() { pipe.finish() }
}
