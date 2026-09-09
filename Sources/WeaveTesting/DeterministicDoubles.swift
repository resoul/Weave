import Foundation

/// MainActor-owned in-memory store for deterministic contract tests.
/// Ownership: the store owns its copied Sendable value. Isolation: MainActor. Errors: no persistence errors are synthesized. Cancellation: no work starts.
@MainActor
public final class TestStore<Value: Sendable> {
    public private(set) var value: Value
    public private(set) var writeCount = 0

    /// Creates a store with an explicit initial value.
    /// Ownership: the store copies the value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(_ initialValue: Value) { value = initialValue }

    /// Reads the current deterministic value.
    /// Ownership: returned value is copied. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func load() -> Value { value }

    /// Writes a value synchronously and records the write count.
    /// Ownership: the store retains the copied value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func write(_ newValue: Value) { value = newValue; writeCount += 1 }
}

/// Manual, sleep-free readiness gate for async tests.
/// Ownership: the gate owns one bounded waiter stream. Isolation: MainActor. Errors: none. Cancellation: cancelled waiters are discarded by AsyncStream.
@MainActor
public final class TestReadiness {
    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>

    /// Creates a gate initially not ready.
    /// Ownership: the gate owns its continuation. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {
        let pair = AsyncStream<Void>.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    /// Signals readiness, coalescing repeated signals.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: finished gates ignore signals. Cancellation: not applicable.
    public func signal() { continuation.yield(()) }

    /// Waits for the next readiness signal without sleeping.
    /// Ownership: caller owns the await. Isolation: MainActor entry. Errors: none. Cancellation: task cancellation ends the wait.
    public func wait() async { for await _ in stream { return } }

    /// Completes the gate and releases waiters.
    /// Ownership: continuation is finished. Isolation: MainActor. Errors: none. Cancellation: waiting tasks resume.
    public func finish() { continuation.finish() }
}
