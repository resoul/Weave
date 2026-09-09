import Foundation

/// Interpolation curve for a transition.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AnimationCurve: Sendable, Hashable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case spring(damping: Double)
}

/// Immutable timing and curve description.
/// Ownership: value is copied by the transition owner. Isolation: none. Errors: invalid values are clamped. Cancellation: not applicable.
public struct Animation: Sendable, Hashable {
    public let duration: Duration
    public let curve: AnimationCurve
    public let delay: Duration

    /// Creates timing with non-negative duration and delay. Ownership: returned value is caller-owned. Isolation: none. Errors: negative values clamp to zero. Cancellation: none.
    public init(
        duration: Duration = .zero, curve: AnimationCurve = .easeInOut, delay: Duration = .zero
    ) {
        self.duration = max(.zero, duration)
        self.curve = curve
        self.delay = max(.zero, delay)
    }

    /// Returns functional zero-duration timing when reduce motion is enabled. Ownership: new value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public func resolved(reduceMotion: Bool) -> Animation {
        reduceMotion ? Animation(duration: .zero, curve: .linear, delay: .zero) : self
    }
}

extension Duration {
    /// Converts to seconds for APIs (like `CATransaction`) that take a `TimeInterval`.
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public var timeInterval: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// Ambient animation the render pipeline picks up for the *next* layout commit produced
/// synchronously inside `Transaction.animate`'s `changes` closure. Layout invalidation
/// (`Node.setNeedsLayout`) bubbles to the root and reaches the render coordinator synchronously,
/// so this value is still in scope by the time `RenderCoordinator.invalidate` captures it into
/// that request — even though the resulting native layer commit itself completes later.
/// Ownership: read once per invalidation. Isolation: MainActor. Errors: none. Cancellation: not
/// applicable.
@MainActor
public enum AnimationContext {
    public private(set) static var current: Animation?

    /// Makes `animation` visible to the render pipeline for the duration of `body`.
    /// Ownership: the previous ambient value is restored after `body` returns. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public static func withAnimation<T>(_ animation: Animation?, _ body: () -> T) -> T {
        let previous = current
        current = animation
        defer { current = previous }
        return body()
    }
}

/// Logical edge used by slide transitions.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum TransitionEdge: Sendable, Hashable {
    case leading
    case trailing
    case top
    case bottom

    /// Resolves logical edges to physical left/right according to layout direction. Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public func resolved(for direction: LayoutDirection) -> PhysicalTransitionEdge {
        switch (self, direction) {
        case (.leading, .leftToRight): return .left
        case (.leading, .rightToLeft): return .right
        case (.trailing, .leftToRight): return .right
        case (.trailing, .rightToLeft): return .left
        case (.top, _): return .top
        case (.bottom, _): return .bottom
        }
    }
}

/// Physical edge consumed by a rendering adapter.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PhysicalTransitionEdge: Sendable, Hashable { case left, right, top, bottom }

/// Platform-neutral transition description.
/// Ownership: transition owns its immutable description. Isolation: none. Errors: custom animator reports its own failures. Cancellation: session cancellation is owner-controlled.
public enum Transition: Sendable {
    case fade
    case slide(edge: TransitionEdge)
    case scale(from: Double)
    case custom(any TransitionAnimator)
}

/// Adapter extension point for custom rendering transitions.
/// Ownership: animator is retained by one transition session. Isolation: MainActor. Errors: implementation may throw. Cancellation: task cancellation is propagated.
@MainActor
public protocol TransitionAnimator: AnyObject, Sendable {
    func animate(progress: Double) async throws
}

/// Result delivered exactly once by a transition session.
/// Ownership: immutable result. Isolation: MainActor at delivery. Errors: failures are represented by cancellation policy. Cancellation: cancelled sessions never complete afterward.
@MainActor
public enum TransitionOutcome: Sendable, Hashable { case completed, cancelled }

/// MainActor boundary for synchronous transaction commits.
/// Ownership: changes execute in caller scope. Isolation: MainActor. Errors: closure errors cannot be thrown. Cancellation: not applicable.
@MainActor
public enum Transaction {
    /// Applies one coherent mutation at the transaction boundary.
    /// Ownership: closure is borrowed for the call. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public static func animate(
        _ animation: Animation,
        reduceMotion: Bool = false,
        _ changes: () -> Void
    ) {
        let resolved = animation.resolved(reduceMotion: reduceMotion)
        AnimationContext.withAnimation(resolved, changes)
    }
}

/// MainActor-owned cancellable transition session.
/// Ownership: session owns its task until completion. Isolation: MainActor. Errors: animator errors cancel the session. Cancellation: cancel and dispose deliver one cancelled outcome.
@MainActor
public final class TransitionSession {
    private var task: Task<Void, Never>?
    private var didFinish = false
    private var isDisposed = false
    private var completion: (@MainActor (TransitionOutcome) -> Void)?

    /// Creates an idle transition session. Ownership: session owns no task until start. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Starts one transition and commits completion exactly once. Ownership: session owns task and callback. Isolation: MainActor. Errors: animator errors produce cancellation. Cancellation: previous start is rejected.
    @discardableResult
    public func start(
        animation: Animation,
        transition: Transition = .fade,
        reduceMotion: Bool = false,
        direction: LayoutDirection = .leftToRight,
        apply: @escaping @MainActor () -> Void,
        completion: @escaping @MainActor (TransitionOutcome) -> Void
    ) -> Bool {
        guard !isDisposed, task == nil else { return false }
        let resolved = animation.resolved(reduceMotion: reduceMotion)
        _ = direction
        self.completion = completion
        apply()
        task = Task { @MainActor [weak self] in
            do {
                if resolved.delay > .zero { try await Task.sleep(for: resolved.delay) }
                if case let .custom(animator) = transition {
                    try await animator.animate(progress: 1)
                }
                if resolved.duration > .zero { try await Task.sleep(for: resolved.duration) }
                guard let self, !Task.isCancelled else { return }
                self.finish(.completed, completion: completion)
            } catch is CancellationError {
                guard let self else { return }
                self.finish(.cancelled, completion: completion)
            } catch {
                guard let self else { return }
                self.finish(.cancelled, completion: completion)
            }
        }
        return true
    }

    /// Cancels the active transition. Ownership: task is released. Isolation: MainActor. Errors: repeated cancellation is ignored. Cancellation: completion receives cancelled once.
    public func cancel(completion: (@MainActor (TransitionOutcome) -> Void)? = nil) {
        guard !didFinish else { return }
        task?.cancel()
        if let completion { self.completion = completion }
        if let callback = self.completion { finish(.cancelled, completion: callback) }
    }

    /// Disposes the session and cancels any active work. Ownership: task is released. Isolation: MainActor. Errors: repeated disposal is a no-op. Cancellation: active work is cancelled.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        task?.cancel()
        task = nil
    }

    private func finish(
        _ outcome: TransitionOutcome, completion: @escaping @MainActor (TransitionOutcome) -> Void
    ) {
        guard !didFinish else { return }
        didFinish = true
        task = nil
        self.completion = nil
        completion(outcome)
    }
}
