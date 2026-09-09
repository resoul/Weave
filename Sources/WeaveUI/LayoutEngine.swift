import Foundation

/// MainActor scheduler that owns asynchronous measure/layout work and applies only current results.
///
/// Ownership: the engine owns its worker task and callback. Isolation: MainActor for scheduling and
/// apply; workers receive immutable snapshots. Errors: stale and cancelled results are discarded.
/// Cancellation: a new request, `cancel()`, or `dispose()` cancels owned work.
@MainActor
public final class LayoutEngine {
    /// Strategy for calculating container layout from snapshot and constraints.
    /// Ownership: closure is copied. Isolation: Sendable. Errors: none. Cancellation: caller task.
    public typealias Solver =
        @Sendable (LayoutInputSnapshot, LayoutFrame, PixelRoundingPolicy, inout FlexMeasureCache)
        -> LayoutResult

    /// Number of requests submitted to the engine.
    public private(set) var requestCount = 0
    /// Number of results committed to the apply callback.
    public private(set) var applyCount = 0
    /// Number of cancelled requests.
    public private(set) var cancelCount = 0
    /// Number of stale results discarded before apply.
    public private(set) var staleCount = 0
    /// Called on MainActor after a result passes its revision check.
    /// Ownership: callback is retained. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onApply: (@MainActor @Sendable (LayoutResult) -> Void)?

    private let solver: Solver
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var disposed = false

    /// Creates an empty scheduler with an apply callback.
    /// Ownership: the engine owns its task and callback. Isolation: MainActor. Errors: none. Cancellation: no work exists until `request` is called.
    public convenience init(onApply: (@MainActor @Sendable (LayoutResult) -> Void)? = nil) {
        self.init(
            solver: { input, frame, roundingPolicy, cache in
                FlexSolver.layoutContainer(
                    input: input, frame: frame, roundingPolicy: roundingPolicy, cache: &cache)
            },
            onApply: onApply
        )
    }

    /// Creates an empty scheduler with an optional custom solver and apply callback.
    /// Ownership: the engine owns its task and callback. Isolation: MainActor. Errors: none. Cancellation: no work exists until `request` is called.
    public init(
        solver: @escaping Solver,
        onApply: (@MainActor @Sendable (LayoutResult) -> Void)? = nil
    ) {
        self.solver = solver
        self.onApply = onApply
    }

    /// Schedules the newest immutable input and coalesces any previous request.
    ///
    /// Ownership: the snapshot is copied into a worker task. Isolation: MainActor at submission;
    /// measure/layout execute from immutable values. Errors: none. Cancellation: replaces prior work.
    public func request(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy()
    ) {
        guard !disposed else { return }
        generation &+= 1
        let requestGeneration = generation
        if worker != nil {
            cancelCount += 1
            worker?.cancel()
        }
        requestCount += 1
        let solver = self.solver
        worker = Task.detached { [weak self] in
            guard !Task.isCancelled else { return }
            var cache = FlexMeasureCache()
            let result = solver(input, frame, roundingPolicy, &cache)
            guard !Task.isCancelled else { return }
            await self?.commit(result, generation: requestGeneration)
        }
    }

    /// Cancels the current worker without disposing the engine.
    ///
    /// Ownership: the engine retains no task after cancellation. Isolation: MainActor. Errors: none.
    /// Cancellation: the worker observes task cancellation before commit.
    public func cancel() {
        generation &+= 1
        if worker != nil {
            cancelCount += 1
            worker?.cancel()
            worker = nil
        }
    }

    /// Permanently cancels work and disables later requests.
    ///
    /// Ownership: all engine-owned work is released. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        cancel()
        onApply = nil
    }

    private func commit(_ result: LayoutResult, generation resultGeneration: UInt64) {
        guard !disposed else { return }
        guard resultGeneration == generation else {
            staleCount += 1
            return
        }
        worker = nil
        applyCount += 1
        onApply?(result)
    }
}
