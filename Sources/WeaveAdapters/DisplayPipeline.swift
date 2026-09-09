import CoreGraphics
import Foundation
import WeaveUI

/// Priority levels for scheduling asynchronous content display tasks.
/// Ownership: the priority is copied by value. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public enum DisplayPriority: Int, Sendable, Comparable, CaseIterable {
    case background = 0
    case nearVisible = 1
    case visible = 2

    /// Compares two display priorities.
    /// Ownership: values are compared by value. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public static func < (lhs: DisplayPriority, rhs: DisplayPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Platform-neutral payload produced by an asynchronous display pass.
/// Ownership: the payload owns its pixel data or CoreGraphics reference. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public enum DisplayPayload: Sendable {
    case image(CGImage)
    case color(ThemeColor)
    case bytes(data: Data, width: Int, height: Int, bytesPerRow: Int)
    case empty
}

/// Immutable parameters captured on MainActor describing a single node display request.
/// Ownership: request is copied across concurrency boundaries by value. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public struct DisplayRequest: Sendable, Hashable {
    public let nodeID: ElementID
    public let generation: UInt64
    public let geometryGeneration: UInt64
    public let contentRevision: UInt64
    public let bounds: LayoutFrame
    public let scale: Double
    public let priority: DisplayPriority

    /// Creates an immutable display request.
    /// Ownership: values are copied. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        generation: UInt64,
        geometryGeneration: UInt64,
        contentRevision: UInt64,
        bounds: LayoutFrame,
        scale: Double,
        priority: DisplayPriority = .visible
    ) {
        self.nodeID = nodeID
        self.generation = generation
        self.geometryGeneration = geometryGeneration
        self.contentRevision = contentRevision
        self.bounds = bounds
        self.scale = scale
        self.priority = priority
    }
}

/// Immutable artifact output produced by an asynchronous display worker.
/// Ownership: the artifact owns its rendered payload and metadata. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public struct DisplayArtifact: Sendable {
    public let nodeID: ElementID
    public let generation: UInt64
    public let geometryGeneration: UInt64
    public let contentRevision: UInt64
    public let payload: DisplayPayload
    public let size: CGSize
    public let scale: Double

    /// Creates an immutable display artifact.
    /// Ownership: values are copied. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        generation: UInt64,
        geometryGeneration: UInt64,
        contentRevision: UInt64,
        payload: DisplayPayload,
        size: CGSize,
        scale: Double
    ) {
        self.nodeID = nodeID
        self.generation = generation
        self.geometryGeneration = geometryGeneration
        self.contentRevision = contentRevision
        self.payload = payload
        self.size = size
        self.scale = scale
    }
}

/// Internal wrapper holding a pending display task.
struct PendingDisplayJob {
    let request: DisplayRequest
    let render: @Sendable () async throws -> DisplayArtifact
    let completion: @MainActor @Sendable (Result<DisplayArtifact, Error>) -> Void
}

/// Bounded asynchronous display scheduler enforcing priority and resource limits.
///
/// Ownership: the scheduler owns its pending queue and active worker tasks.
/// Isolation: MainActor for queue coordination, metrics and callbacks; worker render closures execute on background tasks.
/// Errors: cancelled, stale, or dropped jobs are reported through metrics and do not throw.
/// Cancellation: cancellation is cooperative and cleans up in-flight workers.
@MainActor
public final class DisplayScheduler {
    public let maxConcurrency: Int
    public let maxQueueDepth: Int

    public private(set) var scheduledCount = 0
    public private(set) var startedCount = 0
    public private(set) var completedCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var overflowCount = 0

    public private(set) var isSuspended = false
    public private(set) var isDisposed = false

    private var pendingQueue: [PendingDisplayJob] = []
    private var activeWorkers: [ElementID: Task<Void, Never>] = [:]
    private var quiescenceContinuations: [CheckedContinuation<Void, Never>] = []

    /// Current number of items waiting in the pending queue.
    public var queueDepth: Int { pendingQueue.count }

    /// Current number of concurrently running worker tasks.
    public var inFlightCount: Int { activeWorkers.count }

    /// Creates a display scheduler with configurable concurrency and queue capacity.
    /// Ownership: the scheduler retains its configuration. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(
        maxConcurrency: Int = max(2, ProcessInfo.processInfo.activeProcessorCount - 1),
        maxQueueDepth: Int = 128
    ) {
        self.maxConcurrency = max(1, maxConcurrency)
        self.maxQueueDepth = max(1, maxQueueDepth)
    }

    /// Submits a display job for asynchronous rendering.
    /// Ownership: the render closure is copied to background worker. Isolation: MainActor. Errors: none. Cancellation: cancelled by newer job or explicit cancel.
    public func schedule(
        request: DisplayRequest,
        render: @escaping @Sendable () async throws -> DisplayArtifact,
        completion: @escaping @MainActor @Sendable (Result<DisplayArtifact, Error>) -> Void
    ) {
        guard !isDisposed else {
            completion(.failure(CancellationError()))
            return
        }

        // Cancel any existing in-flight or queued work for the same node
        cancel(nodeID: request.nodeID)

        if pendingQueue.count >= maxQueueDepth {
            // Drop lowest priority pending job if full
            if let lowestIndex = pendingQueue.indices.min(by: {
                pendingQueue[$0].request.priority < pendingQueue[$1].request.priority
            }) {
                if pendingQueue[lowestIndex].request.priority <= request.priority {
                    let dropped = pendingQueue.remove(at: lowestIndex)
                    overflowCount += 1
                    dropped.completion(.failure(CancellationError()))
                } else {
                    // New job is lower priority than all queued items; drop incoming
                    overflowCount += 1
                    completion(.failure(CancellationError()))
                    return
                }
            }
        }

        scheduledCount += 1
        let job = PendingDisplayJob(request: request, render: render, completion: completion)

        // Insert sorted by priority (higher priority first)
        let insertIndex =
            pendingQueue.firstIndex(where: { $0.request.priority < request.priority })
            ?? pendingQueue.endIndex
        pendingQueue.insert(job, at: insertIndex)

        drainQueue()
    }

    /// Cancels in-flight and pending work for a specific node identity.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: active worker is cancelled.
    public func cancel(nodeID: ElementID) {
        guard !isDisposed else { return }

        // Remove from pending
        let initialPendingCount = pendingQueue.count
        pendingQueue.removeAll { job in
            if job.request.nodeID == nodeID {
                job.completion(.failure(CancellationError()))
                return true
            }
            return false
        }
        let removedPending = initialPendingCount - pendingQueue.count

        // Cancel active worker
        var cancelledActive = 0
        if let task = activeWorkers.removeValue(forKey: nodeID) {
            task.cancel()
            cancelledActive = 1
        }

        cancelledCount += (removedPending + cancelledActive)
        checkQuiescence()
        drainQueue()
    }

    /// Cancels all pending and in-flight display jobs.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: all tasks are cancelled.
    public func cancelAll() {
        guard !isDisposed else { return }

        let pendingCount = pendingQueue.count
        let activeCount = activeWorkers.count

        for job in pendingQueue {
            job.completion(.failure(CancellationError()))
        }
        pendingQueue.removeAll()

        for (_, task) in activeWorkers {
            task.cancel()
        }
        activeWorkers.removeAll()

        cancelledCount += (pendingCount + activeCount)
        checkQuiescence()
    }

    /// Suspends worker scheduling, e.g. upon app backgrounding or memory pressure.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: active workers are cancelled.
    public func suspend() {
        guard !isDisposed, !isSuspended else { return }
        isSuspended = true
        for (_, task) in activeWorkers {
            task.cancel()
        }
        cancelledCount += activeWorkers.count
        activeWorkers.removeAll()
        checkQuiescence()
    }

    /// Resumes worker scheduling after suspension.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func resume() {
        guard !isDisposed, isSuspended else { return }
        isSuspended = false
        drainQueue()
    }

    /// Permanently disposes the scheduler, terminating all work.
    /// Ownership: all tasks and callbacks are released. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        cancelAll()
        for continuation in quiescenceContinuations {
            continuation.resume()
        }
        quiescenceContinuations.removeAll()
    }

    /// Asynchronously waits until all pending and active work has completed or been cancelled.
    /// Ownership: caller awaits quiescence. Isolation: MainActor. Errors: none. Cancellation: returns immediately if cancelled.
    public func quiescence() async {
        if pendingQueue.isEmpty && activeWorkers.isEmpty {
            return
        }
        await withCheckedContinuation { continuation in
            quiescenceContinuations.append(continuation)
        }
    }

    private func drainQueue() {
        guard !isSuspended, !isDisposed else { return }

        while activeWorkers.count < maxConcurrency && !pendingQueue.isEmpty {
            let job = pendingQueue.removeFirst()
            let nodeID = job.request.nodeID
            startedCount += 1

            let priority: TaskPriority
            switch job.request.priority {
            case .visible: priority = .userInitiated
            case .nearVisible: priority = .medium
            case .background: priority = .utility
            }

            let task = Task.detached(priority: priority) { [job] () -> Void in
                guard !Task.isCancelled else {
                    await MainActor.run {
                        job.completion(.failure(CancellationError()))
                    }
                    return
                }

                do {
                    let artifact = try await job.render()
                    guard !Task.isCancelled else {
                        await MainActor.run {
                            job.completion(.failure(CancellationError()))
                        }
                        return
                    }
                    await MainActor.run {
                        job.completion(.success(artifact))
                    }
                } catch {
                    await MainActor.run {
                        job.completion(.failure(error))
                    }
                }
            }

            activeWorkers[nodeID] = Task { @MainActor [weak self] in
                _ = await task.result
                self?.workerDidFinish(for: nodeID)
            }
        }

        checkQuiescence()
    }

    private func workerDidFinish(for nodeID: ElementID) {
        guard !isDisposed else { return }
        activeWorkers.removeValue(forKey: nodeID)
        completedCount += 1
        drainQueue()
        checkQuiescence()
    }

    private func checkQuiescence() {
        if pendingQueue.isEmpty && activeWorkers.isEmpty && !quiescenceContinuations.isEmpty {
            let continuations = quiescenceContinuations
            quiescenceContinuations.removeAll()
            for continuation in continuations {
                continuation.resume()
            }
        }
    }
}

/// Transaction orchestrating progressive MainActor display artifact commit for an update generation.
///
/// Ownership: the transaction is owned by the host render pipeline and borrows the DisplayScheduler.
/// Isolation: MainActor.
/// Errors: stale, mismatched or cancelled artifacts are discarded without mutating layer contents.
/// Cancellation: cancellation invalidates in-flight and pending transaction commits.
@MainActor
public final class DisplayTransaction {
    public let hostID: ElementID
    public let generation: UInt64
    public let geometryGeneration: UInt64
    public let scheduler: DisplayScheduler

    public private(set) var committedCount = 0
    public private(set) var staleCount = 0
    public private(set) var isCancelled = false
    public private(set) var isDisposed = false

    /// Closure invoked on MainActor when an artifact passes generation validation.
    /// Ownership: retained by the transaction. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onCommitArtifact: (@MainActor @Sendable (DisplayArtifact) -> Void)?

    /// Validator checking if a node's display revision is still current.
    /// Ownership: retained by transaction. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var nodeRevisionValidator: (@MainActor @Sendable (ElementID, UInt64) -> Bool)?

    private var inFlightNodeIDs: Set<ElementID> = []

    /// Creates a display transaction for a specific host generation.
    /// Ownership: the transaction retains its scheduler. Isolation: MainActor. Errors: none. Cancellation: no work starts during initialization.
    public init(
        hostID: ElementID,
        generation: UInt64,
        geometryGeneration: UInt64,
        scheduler: DisplayScheduler
    ) {
        self.hostID = hostID
        self.generation = generation
        self.geometryGeneration = geometryGeneration
        self.scheduler = scheduler
    }

    /// Submits a node display task to this transaction.
    /// Ownership: render closure is forwarded to the scheduler. Isolation: MainActor. Errors: none. Cancellation: transaction cancellation cancels work.
    public func schedule(
        request: DisplayRequest,
        render: @escaping @Sendable () async throws -> DisplayArtifact
    ) {
        guard !isDisposed, !isCancelled else { return }
        inFlightNodeIDs.insert(request.nodeID)

        scheduler.schedule(request: request, render: render) { [weak self] result in
            self?.handleResult(result, for: request.nodeID)
        }
    }

    /// Cancels this transaction and stops pending artifact commits.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: active jobs for this transaction are cancelled.
    public func cancel() {
        guard !isDisposed, !isCancelled else { return }
        isCancelled = true
        for nodeID in inFlightNodeIDs {
            scheduler.cancel(nodeID: nodeID)
        }
        inFlightNodeIDs.removeAll()
    }

    /// Permanently disposes the transaction.
    /// Ownership: all callbacks are released. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        cancel()
        onCommitArtifact = nil
        nodeRevisionValidator = nil
    }

    /// Waits until all jobs in the underlying scheduler reach quiescence.
    /// Ownership: caller awaits quiescence. Isolation: MainActor. Errors: none. Cancellation: returns immediately if cancelled.
    public func quiescence() async {
        await scheduler.quiescence()
    }

    private func handleResult(_ result: Result<DisplayArtifact, Error>, for nodeID: ElementID) {
        inFlightNodeIDs.remove(nodeID)
        guard !isDisposed, !isCancelled else {
            staleCount += 1
            return
        }

        switch result {
        case .success(let artifact):
            // Verify generation matches
            guard artifact.generation == generation,
                artifact.geometryGeneration == geometryGeneration
            else {
                staleCount += 1
                return
            }

            // Verify content revision matches node's current revision
            if let validator = nodeRevisionValidator,
                !validator(artifact.nodeID, artifact.contentRevision)
            {
                staleCount += 1
                return
            }

            // Valid artifact: apply progressively on MainActor
            committedCount += 1
            onCommitArtifact?(artifact)

        case .failure:
            staleCount += 1
        }
    }
}
