import Foundation

/// States owned by a framework object lifecycle.
///
/// Ownership: the machine owns the current state value. Isolation: MainActor through its owner.
/// Errors: invalid transitions are rejected by the machine. Cancellation: dispose is terminal.
public enum LifecycleState: Sendable, Hashable {
    case created
    case composed
    case connected
    case mounted
    case active
    case inactive
    case unmounted
    case disposed
}

/// Explicit lifecycle requests translated by adapters and containers.
///
/// Ownership: events are immutable values owned by their sender. Isolation: MainActor when applied.
/// Errors: invalid events are rejected. Cancellation: dispose cancels the owned scope.
public enum LifecycleEvent: Sendable, Hashable {
    case compose
    case connect
    case reconnect
    case mount
    case activate
    case deactivate
    case unmount
    case dispose
}

/// A serializable description of an effect failure.
///
/// Ownership: the failure is an immutable value owned by its receiver. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EffectFailure: Sendable, Hashable {
    /// Stable effect identity supplied by the owner.
    public let effectID: String
    /// Diagnostic text suitable for typed state or output handling.
    public let message: String

    /// Creates a failure description without retaining a non-Sendable error.
    ///
    /// Ownership: the value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(effectID: String, message: String) {
        self.effectID = effectID
        self.message = message
    }
}

/// Optional MainActor callbacks for observing committed lifecycle transitions.
///
/// Ownership: the machine owns its callback copy. Isolation: MainActor when callbacks run. Errors: none.
/// Cancellation: callbacks do not outlive the owning machine.
public struct LifecycleHooks: Sendable {
    /// Called once when composition commits.
    public var composed: (@MainActor @Sendable () -> Void)?
    /// Called once when connections commit.
    public var connected: (@MainActor @Sendable () -> Void)?
    /// Called once when mounting commits.
    public var mounted: (@MainActor @Sendable () -> Void)?
    /// Called once when activation commits.
    public var activated: (@MainActor @Sendable () -> Void)?
    /// Called once when deactivation commits.
    public var deactivated: (@MainActor @Sendable () -> Void)?
    /// Called once when unmounting commits.
    public var unmounted: (@MainActor @Sendable () -> Void)?
    /// Called once when disposal commits.
    public var disposed: (@MainActor @Sendable () -> Void)?

    /// Creates hooks with no callbacks.
    ///
    /// Ownership: the hooks retain their callback closures. Isolation: MainActor when invoked.
    /// Errors: none. Cancellation: callbacks are synchronous and not cancellable.
    public init() {}
}

@MainActor
private struct BindingRecord {
    let cancel: @MainActor @Sendable () -> Void
}

@MainActor
private struct EffectRecord {
    let task: Task<Void, Never>
    let cancelOnDeactivate: Bool
}

/// MainActor-owned cancellation scope for bindings and keyed async effects.
///
/// Ownership: the scope owns registered handles and tasks. Isolation: MainActor. Errors: typed failures.
/// Cancellation: reconnect, unmount, dispose, and explicit cancellation terminate owned work.
@MainActor
public final class ConnectionScope {
    private var bindings: [AnyHashable: BindingRecord] = [:]
    private var effects: [AnyHashable: EffectRecord] = [:]
    public private(set) var isCancelled = false

    /// Creates an active empty scope.
    ///
    /// Ownership: the scope owns all registered cancellation handles. Isolation: MainActor.
    /// Errors: none. Cancellation: dispose or cancelAll terminates the scope.
    public init() {}

    /// Registers a replaceable binding cancellation handle.
    ///
    /// Ownership: the scope owns `cancel`; replacing an ID invokes its prior handle once.
    /// Isolation: MainActor. Errors: none. Cancellation: explicit through this scope.
    public func bind<ID: Hashable>(id: ID, cancel: @escaping @MainActor @Sendable () -> Void) {
        guard !isCancelled else {
            cancel()
            return
        }
        let key = AnyHashable(id)
        bindings.removeValue(forKey: key)?.cancel()
        bindings[key] = BindingRecord(cancel: cancel)
    }

    /// Starts a keyed async effect and cancels a previous effect with the same ID.
    ///
    /// Ownership: the scope owns the task. Isolation: registration is MainActor; operation may suspend
    /// across actors. Errors: failures are delivered as `EffectFailure`; cancellation is silent.
    /// Cancellation: replacement, scope cancellation, unmount, and dispose cancel the task.
    @discardableResult
    public func effect<ID: Hashable>(
        id: ID,
        cancelOnDeactivate: Bool = true,
        operation: @escaping @Sendable () async throws -> Void,
        onFailure: (@MainActor @Sendable (EffectFailure) -> Void)? = nil
    ) -> Bool {
        guard !isCancelled else { return false }
        let key = AnyHashable(id)
        effects.removeValue(forKey: key)?.task.cancel()
        let effectName = String(describing: id)
        let task = Task.detached { [weak self] in
            do {
                try await operation()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let failure = EffectFailure(
                    effectID: effectName,
                    message: String(describing: error)
                )
                await self?.deliver(failure, onFailure: onFailure)
            }
        }
        effects[key] = EffectRecord(task: task, cancelOnDeactivate: cancelOnDeactivate)
        return true
    }

    /// Cancels one binding or effect ID without terminating the scope.
    ///
    /// Ownership: the scope releases the selected handle. Isolation: MainActor. Errors: none.
    /// Cancellation: the selected operation receives cancellation exactly once.
    public func cancel<ID: Hashable>(id: ID) {
        let key = AnyHashable(id)
        bindings.removeValue(forKey: key)?.cancel()
        effects.removeValue(forKey: key)?.task.cancel()
    }

    /// Cancels effects marked for deactivation while preserving bindings and opted-out effects.
    ///
    /// Ownership: the scope retains non-suspended records. Isolation: MainActor. Errors: none.
    /// Cancellation: selected effects are cancelled and never report a late failure.
    public func cancelEffectsOnDeactivate() {
        for (key, record) in effects where record.cancelOnDeactivate {
            record.task.cancel()
            effects.removeValue(forKey: key)
        }
    }

    /// Cancels every binding and effect and permanently closes the scope.
    ///
    /// Ownership: all registered handles are released. Isolation: MainActor. Errors: none.
    /// Cancellation: terminal; later registrations are cancelled immediately.
    public func cancelAll() {
        guard !isCancelled else { return }
        isCancelled = true
        bindings.values.forEach { $0.cancel() }
        effects.values.forEach { $0.task.cancel() }
        bindings.removeAll()
        effects.removeAll()
    }

    private func deliver(
        _ failure: EffectFailure,
        onFailure: (@MainActor @Sendable (EffectFailure) -> Void)?
    ) {
        guard !isCancelled else { return }
        onFailure?(failure)
    }
}

/// MainActor state machine coordinating lifecycle transitions and connection ownership.
///
/// Ownership: the machine owns its state, hooks, and current scope. Isolation: MainActor.
/// Errors: invalid transitions return false. Cancellation: dispose is terminal and cancels its scope.
@MainActor
public final class LifecycleMachine {
    /// Current committed lifecycle state.
    public private(set) var state: LifecycleState = .created
    /// Current connection scope, when the object is connected or later.
    public private(set) var connectionScope: ConnectionScope?

    private var hooks: LifecycleHooks

    /// Creates a machine with optional transition callbacks.
    ///
    /// Ownership: the machine owns hooks and its connection scope. Isolation: MainActor.
    /// Errors: none. Cancellation: dispose cancels the owned scope.
    public init(hooks: LifecycleHooks = LifecycleHooks()) {
        self.hooks = hooks
    }

    /// Applies an event once when it is valid for the current state.
    ///
    /// Ownership: the machine owns the resulting state transition. Isolation: MainActor.
    /// Errors: invalid or duplicate events return `false`; no hook runs. Cancellation: dispose is terminal.
    @discardableResult
    public func transition(_ event: LifecycleEvent) -> Bool {
        switch event {
        case .compose where state == .created:
            state = .composed
            hooks.composed?()
        case .connect where state == .composed:
            connectionScope = ConnectionScope()
            state = .connected
            hooks.connected?()
        case .reconnect where state.isConnected:
            connectionScope?.cancelAll()
            connectionScope = ConnectionScope()
        case .mount where state == .connected:
            state = .mounted
            hooks.mounted?()
        case .activate where state == .mounted || state == .inactive:
            state = .active
            hooks.activated?()
        case .deactivate where state == .active:
            connectionScope?.cancelEffectsOnDeactivate()
            state = .inactive
            hooks.deactivated?()
        case .unmount where state == .mounted || state == .inactive:
            connectionScope?.cancelAll()
            state = .unmounted
            hooks.unmounted?()
        case .unmount where state == .active:
            connectionScope?.cancelEffectsOnDeactivate()
            connectionScope?.cancelAll()
            state = .unmounted
            hooks.deactivated?()
            hooks.unmounted?()
        case .dispose where state != .disposed:
            connectionScope?.cancelAll()
            state = .disposed
            hooks.disposed?()
        default:
            return false
        }
        return true
    }
}

private extension LifecycleState {
    var isConnected: Bool {
        switch self {
        case .connected, .mounted, .active, .inactive:
            true
        case .created, .composed, .unmounted, .disposed:
            false
        }
    }
}
