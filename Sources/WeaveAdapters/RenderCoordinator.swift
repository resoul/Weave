import Foundation
import WeaveUI

/// Immutable description of one native host render/layout request.
/// Ownership: the request is copied across boundaries by value. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public struct HostRenderRequest: Sendable, Hashable {
    public let hostID: ElementID
    public let generation: UInt64
    public let treeRevision: UInt64
    public let contentRevision: UInt64
    public let environmentRevision: UInt64
    public let bounds: LayoutFrame
    public let scale: Double
    public let direction: LayoutDirection
    /// Set when this request was raised synchronously inside `Transaction.animate`; the native
    /// renderer uses it to animate the resulting layer changes instead of applying them instantly.
    public let animation: Animation?

    /// Creates a host render request snapshot.
    /// Ownership: values are copied. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public init(
        hostID: ElementID,
        generation: UInt64,
        treeRevision: UInt64,
        contentRevision: UInt64,
        environmentRevision: UInt64,
        bounds: LayoutFrame,
        scale: Double,
        direction: LayoutDirection,
        animation: Animation? = nil
    ) {
        self.hostID = hostID
        self.generation = generation
        self.treeRevision = treeRevision
        self.contentRevision = contentRevision
        self.environmentRevision = environmentRevision
        self.bounds = bounds
        self.scale = scale
        self.direction = direction
        self.animation = animation
    }
}

/// Host-owned coordinator orchestrating asynchronous measure/layout and coherent MainActor commit.
///
/// Ownership: the coordinator owns one LayoutEngine and borrows the logical root Node.
/// Isolation: MainActor for all lifecycle, scheduling, validation, and commit operations.
/// Errors: invalid or stale results are discarded without partial mutation.
/// Cancellation: unmount, suspension, or newer requests cooperatively cancel in-flight work.
@MainActor
public final class RenderCoordinator {
    public let hostID: ElementID
    public let layoutEngine: LayoutEngine
    public let displayScheduler: DisplayScheduler

    public private(set) var requestedCount = 0
    public private(set) var coalescedCount = 0
    public private(set) var cancelledCount = 0
    public private(set) var staleCount = 0
    public private(set) var committedCount = 0

    public private(set) var isMounted = false
    public private(set) var isSuspended = false
    public private(set) var isDisposed = false

    public private(set) var lastCommittedRequest: HostRenderRequest?
    public private(set) var lastCommittedResult: LayoutResult?
    public private(set) var currentRequest: HostRenderRequest?
    public private(set) var currentTransaction: DisplayTransaction?

    /// Called synchronously on MainActor during commit to apply native layer geometry.
    /// Ownership: the closure is retained by the coordinator. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onCommitGeometry: (@MainActor @Sendable (LayoutResult, HostRenderRequest) -> Void)?

    /// Called synchronously on MainActor when an asynchronous display artifact is committed.
    /// Ownership: the closure is retained by the coordinator. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onCommitDisplayArtifact: (@MainActor @Sendable (DisplayArtifact) -> Void)?

    /// Called synchronously on MainActor immediately following geometry commit for observers.
    /// Ownership: the closure is retained by the coordinator. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var onPostCommit: (@MainActor @Sendable (HostRenderRequest) -> Void)?

    private weak var currentRoot: Node?
    private var generation: UInt64 = 0

    /// Creates a render coordinator for a native window host.
    /// Ownership: the coordinator creates or retains its LayoutEngine and DisplayScheduler. Isolation: MainActor. Errors: none. Cancellation: no work starts during initialization.
    public init(
        hostID: ElementID = ElementID(),
        layoutEngine: LayoutEngine? = nil,
        displayScheduler: DisplayScheduler? = nil
    ) {
        self.hostID = hostID
        let engine = layoutEngine ?? LayoutEngine()
        self.layoutEngine = engine
        self.displayScheduler = displayScheduler ?? DisplayScheduler()
        engine.onApply = { [weak self] result in
            self?.handleLayoutResult(result)
        }
    }

    /// Mounts the logical root into this host coordinator.
    /// Ownership: the coordinator weakly holds the root. Isolation: MainActor. Errors: none. Cancellation: repeated mount is idempotent.
    public func mount(root: Node) {
        guard !isDisposed else { return }
        isMounted = true
        currentRoot = root
    }

    /// Unmounts the host and cancels active layout worker.
    /// Ownership: the root reference is released. Isolation: MainActor. Errors: none. Cancellation: active worker is cancelled.
    public func unmount() {
        guard !isDisposed else { return }
        isMounted = false
        if currentRequest != nil {
            cancelledCount += 1
            layoutEngine.cancel()
            currentRequest = nil
        }
        displayScheduler.cancelAll()
        currentTransaction?.cancel()
        currentTransaction = nil
        currentRoot = nil
    }

    /// Suspends scheduling, e.g. when the host window is backgrounded.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: in-flight worker is cancelled.
    public func suspend() {
        guard !isDisposed, !isSuspended else { return }
        isSuspended = true
        if currentRequest != nil {
            cancelledCount += 1
            layoutEngine.cancel()
            currentRequest = nil
        }
        displayScheduler.suspend()
        currentTransaction?.cancel()
    }

    /// Resumes scheduling after suspension.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func resume() {
        guard !isDisposed, isSuspended else { return }
        isSuspended = false
        displayScheduler.resume()
    }

    /// Replaces the active root node, cancelling previous work.
    /// Ownership: the coordinator weakly references the replacement. Isolation: MainActor. Errors: none. Cancellation: active worker is cancelled.
    public func replaceRoot(newRoot: Node) {
        guard !isDisposed else { return }
        if currentRequest != nil {
            cancelledCount += 1
            layoutEngine.cancel()
            currentRequest = nil
        }
        displayScheduler.cancelAll()
        currentTransaction?.cancel()
        currentTransaction = nil
        lastCommittedRequest = nil
        lastCommittedResult = nil
        currentRoot = newRoot
    }

    /// Requests an asynchronous layout pass for the current root.
    /// Ownership: immutable snapshots are copied to the worker. Isolation: MainActor. Errors: invalid inputs are ignored. Cancellation: coalesces with or supersedes previous request.
    public func invalidate(
        root: Node,
        bounds: LayoutFrame,
        scale: Double
    ) {
        guard !isDisposed, isMounted, !isSuspended else { return }
        guard bounds.width >= 0, bounds.height >= 0, scale > 0 else { return }

        let envSnapshot = root.environmentSnapshot
        let direction = envSnapshot.values.layoutDirection
        let nextGeneration = generation &+ 1

        let candidate = HostRenderRequest(
            hostID: hostID,
            generation: nextGeneration,
            treeRevision: root.layoutRevision,
            contentRevision: max(root.layoutRevision, root.displayRevision),
            environmentRevision: envSnapshot.revision,
            bounds: bounds,
            scale: scale,
            direction: direction,
            animation: AnimationContext.current
        )

        // Coalesce duplicate requests when nothing has changed since last commit
        if let last = lastCommittedRequest, currentRequest == nil {
            if isIdentical(last, candidate), currentRoot === root {
                coalescedCount += 1
                return
            }
        }

        // Coalesce if current active request matches exactly
        if let current = currentRequest {
            if isIdentical(current, candidate), currentRoot === root {
                coalescedCount += 1
                return
            }
            cancelledCount += 1
            layoutEngine.cancel()
        }

        generation = nextGeneration
        currentRequest = candidate
        currentRoot = root
        requestedCount += 1

        let snapshot = root.makeLayoutInputSnapshot()
        layoutEngine.request(
            input: snapshot,
            frame: bounds,
            roundingPolicy: PixelRoundingPolicy(scale: scale)
        )
    }

    /// Cancels in-flight layout work without disposing the coordinator.
    /// Ownership: no state escapes. Isolation: MainActor. Errors: none. Cancellation: active worker is cancelled.
    public func cancel() {
        guard !isDisposed else { return }
        if currentRequest != nil {
            cancelledCount += 1
            layoutEngine.cancel()
            currentRequest = nil
        }
    }

    /// Permanently disposes the coordinator and releases callbacks.
    /// Ownership: all resources and callbacks are released. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func dispose() {
        guard !isDisposed else { return }
        unmount()
        isDisposed = true
        layoutEngine.dispose()
        displayScheduler.dispose()
        currentTransaction?.dispose()
        currentTransaction = nil
        onCommitGeometry = nil
        onCommitDisplayArtifact = nil
        onPostCommit = nil
    }

    private func isIdentical(_ a: HostRenderRequest, _ b: HostRenderRequest) -> Bool {
        a.hostID == b.hostID
            && a.treeRevision == b.treeRevision
            && a.contentRevision == b.contentRevision
            && a.environmentRevision == b.environmentRevision
            && a.bounds == b.bounds
            && a.scale == b.scale
            && a.direction == b.direction
    }

    private func handleLayoutResult(_ result: LayoutResult) {
        guard !isDisposed, isMounted, !isSuspended else {
            staleCount += 1
            currentRequest = nil
            return
        }
        guard let request = currentRequest, let root = currentRoot else {
            staleCount += 1
            return
        }

        let currentTreeRevision = root.layoutRevision
        let currentContentRevision = max(root.layoutRevision, root.displayRevision)
        let currentEnvSnapshot = root.environmentSnapshot

        guard result.treeIdentity == root.id,
            result.contentRevision == request.contentRevision,
            result.environmentRevision == request.environmentRevision,
            currentTreeRevision == request.treeRevision,
            currentContentRevision == request.contentRevision,
            currentEnvSnapshot.revision == request.environmentRevision,
            currentEnvSnapshot.values.layoutDirection == request.direction
        else {
            staleCount += 1
            currentRequest = nil
            // Re-raise with the stale request's own animation, not whatever is ambient right
            // now: `Transaction.animate` restores `AnimationContext.current` synchronously once
            // its `changes` closure returns, well before this retry (a later async callback)
            // runs — reading the ambient value here would silently drop the animation on any
            // request that needed even one retry.
            AnimationContext.withAnimation(request.animation) {
                invalidate(root: root, bounds: request.bounds, scale: request.scale)
            }
            return
        }

        // Synchronous coherent commit on MainActor without await
        root.applyRecursively(result)
        onCommitGeometry?(result, request)
        lastCommittedRequest = request
        lastCommittedResult = result
        currentRequest = nil
        committedCount += 1

        let transaction = DisplayTransaction(
            hostID: hostID,
            generation: request.generation,
            geometryGeneration: request.generation,
            scheduler: displayScheduler
        )
        transaction.onCommitArtifact = { [weak self] artifact in
            self?.onCommitDisplayArtifact?(artifact)
        }
        transaction.nodeRevisionValidator = { [weak root] nodeID, revision in
            guard let root else { return false }
            return root.findNode(id: nodeID)?.displayRevision == revision
        }
        currentTransaction = transaction

        scheduleDisplayPasses(for: root, transaction: transaction, request: request)

        onPostCommit?(request)
    }

    /// Schedules an asynchronous display pass for a content node without re-running layout.
    /// Ownership: snapshot is copied to worker. Isolation: MainActor. Errors: none. Cancellation: supersedes previous display for this node.
    public func invalidateDisplay(for node: Node) {
        guard !isDisposed, isMounted, !isSuspended else { return }
        guard let transaction = currentTransaction, let lastRequest = lastCommittedRequest else {
            return
        }
        scheduleDisplayPass(for: node, transaction: transaction, request: lastRequest)
    }

    private func scheduleDisplayPasses(
        for node: Node,
        transaction: DisplayTransaction,
        request: HostRenderRequest
    ) {
        scheduleDisplayPass(for: node, transaction: transaction, request: request)
        for child in node.subnodes {
            scheduleDisplayPasses(for: child, transaction: transaction, request: request)
        }
    }

    private func scheduleDisplayPass(
        for node: Node,
        transaction: DisplayTransaction,
        request: HostRenderRequest
    ) {
        if let textNode = node as? TextNode, let frame = textNode.calculatedFrame {
            let textColor =
                textNode.textStyle.color
                ?? textNode.environmentSnapshot.values[ThemeKey.self].colors.text
            let textRequest = TextRenderRequest(
                nodeID: textNode.id,
                text: textNode.text,
                style: textNode.textStyle,
                color: textColor,
                bounds: frame,
                scale: request.scale,
                direction: textNode.environmentSnapshot.values.layoutDirection,
                localeIdentifier: textNode.environmentSnapshot.values.locale.identifier,
                maxLines: textNode.maxLines,
                truncation: textNode.truncation,
                generation: transaction.generation,
                geometryGeneration: transaction.geometryGeneration,
                contentRevision: textNode.displayRevision
            )
            let displayRequest = DisplayRequest(
                nodeID: textNode.id,
                generation: transaction.generation,
                geometryGeneration: transaction.geometryGeneration,
                contentRevision: textNode.displayRevision,
                bounds: frame,
                scale: request.scale,
                priority: .visible
            )
            transaction.schedule(request: displayRequest) {
                try CoreTextRasterRenderer.render(request: textRequest)
            }
        } else if let imageNode = node as? ImageNode, let frame = imageNode.calculatedFrame {
            let imageRevision = imageNode.displayRevision
            let imageRequest = ImageRenderRequest(
                nodeID: imageNode.id,
                data: imageNode.image?.data,
                contentMode: imageNode.contentMode,
                bounds: frame,
                scale: request.scale,
                loadingState: imageNode.loadingState,
                generation: transaction.generation,
                geometryGeneration: transaction.geometryGeneration,
                contentRevision: imageRevision
            )
            let displayRequest = DisplayRequest(
                nodeID: imageNode.id,
                generation: transaction.generation,
                geometryGeneration: transaction.geometryGeneration,
                contentRevision: imageRevision,
                bounds: frame,
                scale: request.scale,
                priority: .visible
            )
            transaction.schedule(request: displayRequest) {
                try ImageRasterRenderer.render(request: imageRequest)
            }
        }
    }
}
