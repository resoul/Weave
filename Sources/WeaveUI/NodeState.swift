public import Flux

/// Actor-owned latest state with distinct updates and replay for new subscribers.
///
/// Ownership: the actor owns the current value. Isolation: actor isolation; writes are serialized.
/// Errors: none. Cancellation: subscriptions cancel through Flux `Subscription`.
public actor NodeState<Value: Sendable & Equatable> {
    private let storage: CurrentValueDistinct<Value>
    private var revision: UInt64 = 0

    /// Creates state with an initial value.
    ///
    /// Ownership: the state actor owns the initial value. Isolation: actor isolation. Errors: none.
    /// Cancellation: not applicable.
    public init(_ initial: Value) {
        storage = CurrentValueDistinct(initial)
    }

    /// Reads the latest committed value.
    public var value: Value { get async { await storage.value } }
    /// Monotonically increases only when a distinct value is committed.
    public var revisionValue: UInt64 { revision }
    /// Flux stream that replays current state and emits distinct updates.
    public nonisolated var flux: Flux<Value> { storage.flux }

    /// Commits a value in actor order; returns false when equal to current state.
    ///
    /// Ownership: the actor copies the value. Isolation: actor isolation. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func set(_ value: Value) async -> Bool {
        let current = await storage.value
        guard current != value else { return false }
        await storage.set(value)
        revision &+= 1
        return true
    }

    /// Applies a synchronous transform in actor order.
    ///
    /// Ownership: the actor owns the transformed value. Isolation: actor isolation. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func modify(_ transform: (Value) -> Value) async -> Bool {
        await set(transform(await storage.value))
    }
}

/// Bounded latest-buffer action stream; it never replays an action to new subscribers.
///
/// Ownership: the pipe owns its subscriber continuations. Isolation: MainActor for sending.
/// Errors: overflow is reported as a yield result. Cancellation: subscriptions cancel independently.
@MainActor
public final class ActionPipe<Action: Sendable> {
    private let pipe: Pipe<Action>

    /// Creates an action pipe with an explicit bounded capacity.
    ///
    /// Ownership: the pipe owns the Flux source. Isolation: MainActor. Errors: non-positive capacity
    /// normalizes to one. Cancellation: `finish` ends all subscriptions.
    public init(capacity: Int = 64) {
        pipe = Pipe(bufferingPolicy: .bufferingNewest(max(1, capacity)))
    }

    /// Sends an action and reports whether the bounded buffer accepted it.
    ///
    /// Ownership: the pipe copies the action into subscriber buffers. Isolation: MainActor. Errors:
    /// overflow is returned as a yield result. Cancellation: not applicable.
    @discardableResult
    public func send(_ action: Action) -> AsyncStream<Action>.Continuation.YieldResult {
        pipe.sendObservingOverflow(action).first ?? .dropped(action)
    }

    /// Stream of actions without replay of earlier commands.
    public var flux: Flux<Action> { pipe.flux }

    /// Finishes the action stream.
    ///
    /// Ownership: the pipe closes its continuations. Isolation: MainActor. Errors: none.
    /// Cancellation: subscribers observe completion.
    public func finish() { pipe.finish() }
}
