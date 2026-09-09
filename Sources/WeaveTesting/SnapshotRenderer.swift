import Foundation
import WeaveUI

/// Capture mode for a headless render.
/// Ownership: immutable value. Isolation: none. Errors: bitmap capture may throw backend errors. Cancellation: caller-owned.
public enum RenderMode: Sendable, Hashable {
    case layoutOnly
    case semantic
    case bitmap
}

/// Immutable request for one headless capture.
/// Ownership: values are copied. Isolation: none. Errors: invalid scale/timeout normalize. Cancellation: caller-owned.
public struct RenderRequest: Sendable {
    public let size: SizeConstraint
    public let scale: Double
    public let environment: EnvironmentValues
    public let mode: RenderMode
    public let timeout: Duration

    /// Creates a capture request without allocating a Window.
    /// Ownership: arguments are copied. Isolation: none. Errors: invalid scale/timeout normalize. Cancellation: no work starts during init.
    public init(
        size: SizeConstraint,
        scale: Double = 1,
        environment: EnvironmentValues = EnvironmentValues(),
        mode: RenderMode = .layoutOnly,
        timeout: Duration = .seconds(2)
    ) {
        self.size = size
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.environment = environment
        self.mode = mode
        self.timeout = timeout < .zero ? .zero : timeout
    }
}

/// Immutable layout artifact produced by a headless capture.
/// Ownership: artifact owns copied placements. Isolation: none. Errors: none. Cancellation: caller-owned.
public struct LayoutSnapshot: Sendable, Hashable {
    public let placements: [LayoutPlacement]
    public let treeIdentity: UInt64
    public let environmentRevision: UInt64
    public let contentRevision: UInt64

    init(_ result: LayoutResult) {
        placements = result.placements
        treeIdentity = result.treeIdentity
        environmentRevision = result.environmentRevision
        contentRevision = result.contentRevision
    }
}

/// Deterministic platform-neutral bitmap artifact.
/// Ownership: artifact owns RGBA bytes. Isolation: none. Errors: dimensions are normalized. Cancellation: caller-owned.
public struct BitmapSnapshot: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let scale: Double
    public let rgba: Data
    public let generation: UInt64

    /// Creates an immutable RGBA artifact.
    /// Ownership: bytes are copied into the artifact. Isolation: none. Errors: dimensions and scale normalize. Cancellation: not applicable.
    public init(width: Int, height: Int, scale: Double, rgba: Data, generation: UInt64) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.rgba = rgba
        self.generation = generation
    }
}

/// Timing and revision metadata for one capture.
/// Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
public struct RenderMetrics: Sendable, Hashable {
    public let generation: UInt64
    public let nodeCount: Int
    public let duration: Duration

    init(generation: UInt64, nodeCount: Int, duration: Duration) {
        self.generation = generation
        self.nodeCount = nodeCount
        self.duration = duration
    }
}

/// Result containing only artifacts requested by the capture mode.
/// Ownership: artifact owns immutable snapshots. Isolation: none. Errors: typed renderer failures. Cancellation: caller-owned.
public struct RenderArtifact: Sendable, Hashable {
    public let layoutTree: LayoutSnapshot
    public let accessibilityTree: AccessibilitySnapshot?
    public let image: BitmapSnapshot?
    public let metrics: RenderMetrics
}

/// Typed failures from headless capture.
/// Ownership: error owns its diagnostic. Isolation: none. Errors: this is the renderer error surface. Cancellation: task cancellation remains CancellationError.
public enum SnapshotRenderError: Error, Sendable, Hashable {
    case quiescenceTimeout(generation: UInt64, mode: RenderMode)
    case invalidBitmapSize
}

/// Injectable offscreen bitmap backend. It never creates a Window or native view.
/// Ownership: renderer retains the backend. Isolation: async Sendable boundary. Errors: backend failures propagate. Cancellation: implementation must observe cancellation.
public protocol OffscreenBitmapBackend: Sendable {
    /// Captures a layout without creating a Window or platform view.
    /// Ownership: returned bytes are owned by the caller. Isolation: async Sendable boundary. Errors: backend failures throw. Cancellation: implementation observes cancellation.
    func capture(layout: LayoutSnapshot, scale: Double, generation: UInt64) async throws
        -> BitmapSnapshot
}

/// Stable RGBA backend for deterministic tests and golden generation.
/// Ownership: stateless value. Isolation: async Sendable boundary. Errors: oversized dimensions are rejected. Cancellation: cancellation propagates.
public struct DeterministicBitmapBackend: OffscreenBitmapBackend, Sendable {
    /// Creates the stable zero-filled RGBA backend.
    /// Ownership: stateless value. Isolation: none. Errors: none. Cancellation: none during init.
    public init() {}

    /// Captures deterministic pixels from the root layout dimensions.
    /// Ownership: returned artifact owns bytes. Isolation: async Sendable boundary. Errors: oversized dimensions throw. Cancellation: cancellation propagates.
    public func capture(layout: LayoutSnapshot, scale: Double, generation: UInt64) async throws
        -> BitmapSnapshot
    {
        guard let root = layout.placements.first?.frame else {
            throw SnapshotRenderError.invalidBitmapSize
        }
        let width = Int((root.width * scale).rounded())
        let height = Int((root.height * scale).rounded())
        guard width >= 0, height >= 0, width <= 4096, height <= 4096 else {
            throw SnapshotRenderError.invalidBitmapSize
        }
        try Task.checkCancellation()
        return BitmapSnapshot(
            width: width, height: height, scale: scale,
            rgba: Data(repeating: 0, count: width * height * 4), generation: generation)
    }
}

/// MainActor-owned headless renderer. Layout and semantic captures do not create a Window.
/// Ownership: renderer retains only the injected backend and quiescence callback. Isolation: MainActor. Errors: typed timeout/backend failures. Cancellation: owned capture task is cancellable.
@MainActor
public final class SnapshotRenderer {
    private let bitmapBackend: any OffscreenBitmapBackend
    private let quiescence: @MainActor @Sendable () async -> Bool
    private var generation: UInt64 = 0

    /// Creates a renderer with a deterministic offscreen backend.
    /// Ownership: dependencies are retained. Isolation: MainActor. Errors: none. Cancellation: no work starts during init.
    public init(
        bitmapBackend: any OffscreenBitmapBackend = DeterministicBitmapBackend(),
        quiescence: @escaping @MainActor @Sendable () async -> Bool = { true }
    ) {
        self.bitmapBackend = bitmapBackend
        self.quiescence = quiescence
    }

    /// Captures one committed generation from a live MainActor node without creating a Window.
    /// Ownership: returned artifact is caller-owned. Isolation: MainActor entry; pure layout/backend work is Sendable. Errors: timeout and backend failures. Cancellation: task cancellation propagates.
    public func render(_ node: Node, request: RenderRequest) async throws -> RenderArtifact {
        generation &+= 1
        let currentGeneration = generation
        let clock = ContinuousClock()
        let start = clock.now
        let input = makeInput(node, environment: request.environment)
        let frame = LayoutFrame(
            origin: LayoutPoint(x: 0, y: 0),
            width: exactOrZero(request.size.width),
            height: exactOrZero(request.size.height))
        let result = FlexSolver.layoutContainer(
            input: input, frame: frame, roundingPolicy: PixelRoundingPolicy(scale: request.scale))
        apply(result, to: node)
        guard
            try await waitForQuiescence(
                timeout: request.timeout, generation: currentGeneration, mode: request.mode)
        else {
            throw SnapshotRenderError.quiescenceTimeout(
                generation: currentGeneration, mode: request.mode)
        }
        let layout = LayoutSnapshot(result)
        let accessibility: AccessibilitySnapshot?
        switch request.mode {
        case .layoutOnly, .bitmap: accessibility = nil
        case .semantic:
            accessibility = AccessibilityTree().rebuild(root: node, revision: currentGeneration)
        }
        let image: BitmapSnapshot?
        if request.mode == .bitmap {
            image = try await bitmapBackend.capture(
                layout: layout, scale: request.scale, generation: currentGeneration)
        } else {
            image = nil
        }
        let duration = clock.now - start
        return RenderArtifact(
            layoutTree: layout, accessibilityTree: accessibility, image: image,
            metrics: RenderMetrics(
                generation: currentGeneration, nodeCount: result.placements.count,
                duration: duration))
    }

    private func waitForQuiescence(timeout: Duration, generation: UInt64, mode: RenderMode)
        async throws -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await quiescence() { return true }
            if timeout == .zero || clock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func makeInput(_ node: Node, environment: EnvironmentValues) -> LayoutInputSnapshot {
        LayoutInputSnapshot(
            identity: node.id,
            style: node.style,
            children: node.subnodes.map { makeInput($0, environment: environment) },
            environmentRevision: 0,
            contentRevision: node.layoutRevision &+ node.displayRevision
                &+ node.accessibilityRevision)
    }

    private func apply(_ result: LayoutResult, to node: Node) {
        node.apply(result)
        for child in node.subnodes { apply(result, to: child) }
    }

    private func exactOrZero(_ axis: SizeConstraintAxis) -> Double {
        if case let .exact(value) = axis { return value }
        if case let .atMost(value) = axis { return value }
        return 0
    }
}

/// Exact and tolerance-aware snapshot comparisons.
/// Ownership: comparisons borrow immutable snapshots. Isolation: none. Errors: mismatch returns a diagnostic string. Cancellation: not applicable.
public enum SnapshotComparator {
    public static func compareLayout(
        _ lhs: LayoutSnapshot, _ rhs: LayoutSnapshot, tolerance: Double = 0
    ) -> String? {
        guard lhs.placements.count == rhs.placements.count else { return "placement count differs" }
        for (a, b) in zip(lhs.placements, rhs.placements) {
            guard a.identity == b.identity else { return "identity differs" }
            let values = [a.frame.origin.x, a.frame.origin.y, a.frame.width, a.frame.height]
            let other = [b.frame.origin.x, b.frame.origin.y, b.frame.width, b.frame.height]
            if zip(values, other).contains(where: { abs($0 - $1) > max(0, tolerance) }) {
                return "frame differs for \(a.identity)"
            }
        }
        return nil
    }

    public static func compareSemantic(_ lhs: AccessibilitySnapshot, _ rhs: AccessibilitySnapshot)
        -> String?
    {
        lhs == rhs ? nil : "semantic snapshot differs"
    }

    public static func compareBitmap(_ lhs: BitmapSnapshot, _ rhs: BitmapSnapshot) -> String? {
        lhs == rhs ? nil : "bitmap differs (exact comparison required)"
    }
}
