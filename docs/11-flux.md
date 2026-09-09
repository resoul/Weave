# Flux Integration & Reactive Runtime

## Role of Flux in Weave

Flux is the **sole reactive engine** for the Weave framework:
- Built natively with Swift concurrency primitives (`AsyncStream`, actors, locks, and task trees).
- Strictly conforms to Swift 6 language mode (`Sendable`, no data races).
- Fully platform-neutral: shared across iOS, macOS, and tvOS without platform `#if` guards.
- Replaces Combine and external reactive frameworks throughout Weave.

Weave Core, Controllers, ViewModels, and services communicate asynchronously through Flux streams and state holders.

---

## Core Primitives

### 1. `Flux<T>` — Cold Reactive Stream

`Flux<T>` is a cold stream backed by an `AsyncStream<T>` factory. Every subscription (`.sink` or `.stream`) executes a new producer closure independently.

```swift
public struct Flux<T: Sendable>: Sendable {
    // Creation
    public static func just(_ value: T) -> Flux<T>
    public static func from(_ values: some Sequence<T> & Sendable) -> Flux<T>
    public static func empty() -> Flux<T>
    public static func never() -> Flux<T>
    public static func timer(_ duration: Duration) -> Flux<T>

    // Custom producer
    public init(_ make: @Sendable @escaping () -> AsyncStream<T>)

    // Observation
    @discardableResult
    public func sink(
        next: @Sendable @escaping (T) -> Void,
        completed: @Sendable @escaping () -> Void = {}
    ) -> Subscription

    @discardableResult @MainActor
    public func sinkOnMain(
        _ handler: @MainActor @escaping (T) -> Void
    ) -> Subscription

    // Native Swift Async
    public var stream: AsyncStream<T> { get }
    public func first() async -> T?
    public func collect() async -> [T]
}
```

#### Key Operators
- **Transform**: `map`, `compactMap`, `flatMap`, `flatMapLatest` (switches to latest, cancelling prior task).
- **Filter**: `filter`, `skipRepeats` (when `T: Equatable`), `prefix`, `drop`.
- **Timing**: `debounce(for:)`, `throttle(for:latest:)`, `delay(for:)`.
- **Combine**: `merge`, `combineLatest`, `zip`.

---

### 2. `Pipe<T>` — Hot Multicast Event Bus

`Pipe<T>` broadcasts transient events immediately to all active subscribers. Values are not replayed to future subscribers.

```swift
public final class Pipe<T: Sendable>: @unchecked Sendable {
    public init(
        bufferingPolicy: AsyncStream<T>.Continuation.BufferingPolicy = .bufferingNewest(64)
    )

    /// Broadcast value to active subscribers
    public func send(_ value: T)

    /// Multicast push with yield results per subscriber (for backpressure / telemetry)
    @discardableResult
    public func sendObservingOverflow(_ value: T) -> [AsyncStream<T>.Continuation.YieldResult]

    /// Completes the stream and closes continuations
    public func finish()

    /// Stream projection for subscribers
    public var flux: Flux<T> { get }
}
```

> [!IMPORTANT]
> `Pipe` enforces a default bounded buffer (`.bufferingNewest(64)`) per subscriber to prevent memory leaks from slow consumers. Unbounded buffers are strictly forbidden in UI event paths.

---

### 3. `CurrentValue<T>` & `CurrentValueDistinct<T>` — Observable State Holders

Actor-isolated state holders that retain the current value and replay it immediately upon subscription (`replay = 1`).

```swift
public actor CurrentValue<T: Sendable> {
    public init(_ initial: T)

    // Actor-isolated read & write
    public var value: T { get async }
    public func set(_ newValue: T) async
    public func modify(_ transform: (T) -> T) async

    // Subscription
    public nonisolated var flux: Flux<T> { get }
    public nonisolated var stream: AsyncStream<T> { get }
}

public actor CurrentValueDistinct<T: Sendable & Equatable> {
    public init(_ initial: T)

    public var value: T { get async }
    
    /// Sets value; if identical to current, skips notifying subscribers
    public func set(_ newValue: T) async
    public func modify(_ transform: (T) -> T) async

    public nonisolated var flux: Flux<T> { get }
    public nonisolated var stream: AsyncStream<T> { get }
}
```

---

### 4. `Subscription` & `SubscriptionBag` — Ownership & Cancellation

```swift
public final class Subscription: @unchecked Sendable {
    public let id: UUID
    public func cancel()
}

public final class SubscriptionBag: @unchecked Sendable {
    public init()
    public var count: Int { get }
    public func add(_ subscription: Subscription)
    public func cancelAll()
    deinit { cancelAll() }
}
```

Calling `.cancel()` stops delivery immediately and cancels the underlying async task. Completed streams automatically prune themselves from `SubscriptionBag`.

---

## Integration with Weave Architecture

### ViewModel State & Outputs

ViewModels expose state as `CurrentValueDistinct` and actions/outputs as `Flux`:

```swift
public protocol ViewModel: Sendable {
    associatedtype State: Sendable & Equatable
    associatedtype Intent: Sendable
    associatedtype Output: Sendable

    nonisolated var state: CurrentValueDistinct<State> { get }
    nonisolated var outputs: Flux<Output> { get }
    func send(_ intent: Intent) async
}
```

### Controller Bindings via `ConnectionScope`

`Controller` hooks up the `ViewModel` to the `Node` tree inside `connect(_:)`. All subscriptions are registered within `ConnectionScope`:

```swift
open class FeedController: Controller<FeedNode, FeedAction, FeedRoute> {
    private let viewModel: FeedViewModel

    override func connect(_ connections: ControllerConnections<FeedAction, FeedRoute>) {
        // State -> Node: update node when state changes
        viewModel.state.flux
            .sinkOnMain { [weak self] state in
                self?.rootNode.apply(state: state)
            }
            .store(in: connections.scope)

        // Node Actions -> ViewModel Intents
        connections.actions
            .sinkOnMain { [weak self] action in
                Task { [weak self] in
                    await self?.viewModel.send(action.asIntent)
                }
            }
            .store(in: connections.scope)

        // ViewModel Outputs -> Coordinator Routes
        viewModel.outputs
            .sinkOnMain { [weak self] output in
                switch output {
                case .openDetail(let id):
                    self?.route(.detail(id))
                }
            }
            .store(in: connections.scope)
    }
}
```

### Lifecycle Scopes

| Scope Holder | Duration | Cancellation Point |
|---|---|---|
| `connections.scope` | Controller connection lifetime | Cleared when controller is disconnected or disposed |
| `cancelOnDeactivate` | Visible / active screen period | Cancelled on `deactivated()`, re-established on `activated()` |
| `Node.connectionScope` | Mounted node lifetime | Cleared on unmount / recycling |

---

## Concurrency & Safety Rules

> [!CAUTION]
> **Strict Concurrency Compliance Rules** (must be observed across all Weave code):
>
> 1. **No Synchronous `CurrentValue` Setter**:
>    `CurrentValue` is an `actor`. Never invent or use a synchronous setter (`state.value = x`). Always `await state.set(newValue)` or `await state.modify { ... }`.
> 2. **Strict `Sendable` Payloads**:
>    Every value emitted through `Flux`, `Pipe`, or stored in `CurrentValue` must strictly conform to `Sendable`. Never send live `Node`, `Controller`, or platform references (`UIView`, `NSView`, `CALayer`).
> 3. **MainActor Bridging**:
>    UI trees and nodes belong exclusively to `@MainActor`. Always use `.sinkOnMain` when bindings mutate nodes or controllers.
> 4. **Bounded Buffers**:
>    All pipes and event streams must specify explicit bounded buffers (e.g. `.bufferingNewest(64)`). Unbounded streams in user event paths cause catastrophic memory expansion under load.
> 5. **Idempotent Reconnect**:
>    Re-running `connect()` must always dispose of the previous `ConnectionScope` first to prevent duplicate bindings and ghost event handlers.
