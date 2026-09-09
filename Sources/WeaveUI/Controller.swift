import Foundation

public import Flux

/// Marker for typed controller actions.
/// Ownership: conforming values are immutable Sendable snapshots. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public protocol Action: Sendable {}

extension Never: Action {}

/// A typed navigation destination.
/// Ownership: routes are immutable Sendable values. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public protocol Route: Sendable, Hashable {
    var path: String { get }
}

extension Never: Route {
    public var path: String { "" }
}

/// Immutable activation context delivered by a controller lifecycle transition.
/// Ownership: the context is copied by the receiver. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct ActivationContext: Sendable, Hashable {
    /// Creates an empty activation context. Ownership: none. Isolation: none. Errors: none. Cancellation: none.
    public init() {}
}

/// Immutable deactivation context delivered by a controller lifecycle transition.
/// Ownership: the context is copied by the receiver. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct DeactivationContext: Sendable, Hashable {
    /// Creates an empty deactivation context. Ownership: none. Isolation: none. Errors: none. Cancellation: none.
    public init() {}
}

/// Immutable environment change summary for controller hooks.
/// Ownership: the summary is copied by the receiver. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentChanges: Sendable, Hashable {
    public let revision: UInt64

    /// Creates a revision summary. Ownership: the value is copied. Isolation: none. Errors: none. Cancellation: none.
    public init(revision: UInt64) { self.revision = revision }
}

/// Typed navigation output owned by one controller.
/// Ownership: the pipe owns bounded subscribers. Isolation: MainActor. Errors: overflow is
/// reported by the send result. Cancellation: finish closes all subscribers.
@MainActor
public final class RoutePipe<R: Route> {
    private let pipe: ActionPipe<R>

    /// Creates a bounded route output.
    /// Ownership: the pipe owns its source. Isolation: MainActor. Errors: capacity is clamped.
    /// Cancellation: finish closes the output.
    public init(capacity: Int = 64) { pipe = ActionPipe(capacity: capacity) }

    /// Sends one route output.
    /// Ownership: the route is copied into subscriber buffers. Isolation: MainActor. Errors:
    /// overflow is returned by the bounded pipe. Cancellation: not applicable.
    @discardableResult
    public func send(_ route: R) -> AsyncStream<R>.Continuation.YieldResult {
        pipe.send(route)
    }

    /// The route output stream.
    public var flux: Flux<R> { pipe.flux }

    /// Finishes the route output.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: subscribers complete.
    public func finish() { pipe.finish() }
}

/// Connections exposed while a controller is connected.
/// Ownership: the controller owns the connection scope and output pipes. Isolation: MainActor.
/// Errors: duplicate IDs replace prior bindings. Cancellation: scope disposal cancels bindings.
@MainActor
public struct ControllerConnections<A: Action, R: Route> {
    public let actions: ActionPipe<A>
    public let routes: RoutePipe<R>
    public let scope: ConnectionScope

    /// Creates controller connections for one lifecycle scope.
    /// Ownership: values are borrowed from the controller. Isolation: MainActor. Errors: none.
    /// Cancellation: the scope controls registered work.
    public init(actions: ActionPipe<A>, routes: RoutePipe<R>, scope: ConnectionScope) {
        self.actions = actions
        self.routes = routes
        self.scope = scope
    }

    /// Forwards a typed Flux of intents into an actor-compatible ViewModel.
    /// Ownership: the scope owns the forwarding task. Isolation: registration is MainActor and
    /// `send` executes on the ViewModel's isolation. Errors: thrown effect failures route to the
    /// optional handler. Cancellation: replacing the ID, deactivation policy or scope disposal
    /// cancels delivery.
    @discardableResult
    public func forward<VM: ViewModel>(
        _ source: Flux<VM.Intent>,
        to viewModel: VM,
        id: ControllerConnectionID = "viewModel.intents",
        onFailure: (@MainActor @Sendable (EffectFailure) -> Void)? = nil
    ) -> Bool {
        let stream = source.stream
        return scope.effect(
            id: id,
            cancelOnDeactivate: false,
            operation: {
                for await intent in stream {
                    try Task.checkCancellation()
                    await viewModel.send(intent)
                }
            }, onFailure: onFailure)
    }

    /// Forwards this controller's actions into a ViewModel whose Intent matches its Action.
    /// Ownership: the scope owns the forwarding task. Isolation: MainActor registration and
    /// actor-isolated intent handling. Errors: failures route to the optional handler.
    /// Cancellation: the connection scope cancels delivery.
    @discardableResult
    public func forward<VM: ViewModel>(
        _ source: ActionPipe<A>,
        to viewModel: VM,
        id: ControllerConnectionID = "viewModel.intents",
        onFailure: (@MainActor @Sendable (EffectFailure) -> Void)? = nil
    ) -> Bool where VM.Intent == A {
        forward(source.flux, to: viewModel, id: id, onFailure: onFailure)
    }

    /// Renders ViewModel state on MainActor and stores the subscription in this scope.
    /// Ownership: the scope owns the subscription. Isolation: MainActor delivery. Errors: none;
    /// renderer receives only committed state snapshots. Cancellation: matching ID or disposal
    /// stops rendering.
    @discardableResult
    public func render<State: Sendable & Equatable>(
        _ state: CurrentValueDistinct<State>,
        id: ControllerConnectionID = "viewModel.state",
        on renderer: @escaping @MainActor @Sendable (State) -> Void
    ) -> Subscription {
        let subscription = state.flux.sinkOnMain(renderer)
        scope.bind(id: id) { subscription.cancel() }
        return subscription
    }

    /// Handles ViewModel outputs at the screen boundary.
    /// Ownership: the scope owns the subscription. Isolation: MainActor delivery. Errors: output
    /// overflow remains observable at its producing pipe. Cancellation: matching ID or disposal
    /// stops handling.
    @discardableResult
    public func handle<Output: Sendable>(
        _ outputs: Flux<Output>,
        id: ControllerConnectionID = "viewModel.outputs",
        with handler: @escaping @MainActor @Sendable (Output) -> Void
    ) -> Subscription {
        let subscription = outputs.sinkOnMain(handler)
        scope.bind(id: id) { subscription.cancel() }
        return subscription
    }
}

/// Type-erased controller boundary used by containers.
/// Ownership: the container owns the controller reference. Isolation: MainActor. Errors: none.
/// Cancellation: dispose releases node and bindings.
@MainActor
public protocol AnyController: AnyObject {
    var anyNode: Node { get }
    var isDisposed: Bool { get }
    func connectForContainer() -> Bool
    func dispose()
    func activateForContainer() -> Bool
    func deactivateForContainer() -> Bool
}

@MainActor
protocol ControllerRouteSource: AnyObject {
    func bindRoutes(
        to scope: ConnectionScope,
        handler: @MainActor @escaping @Sendable (any Route) -> Void
    )
}

/// MainActor screen controller with typed node, action and route contracts.
/// Ownership: the controller owns its node, action/route pipes and lifecycle scope. Isolation:
/// MainActor. Errors: invalid duplicate lifecycle transitions are ignored. Cancellation: dispose
/// is terminal and cancels all controller-owned bindings.
@MainActor
open class Controller<N: Node, A: Action, R: Route>: AnyController {
    public let node: N
    public let actions: ActionPipe<A>
    public let router: RoutePipe<R>
    public private(set) var isDisposed = false

    private let lifecycle = LifecycleMachine()
    private var didCompose = false
    private var didConnect = false

    /// Creates a controller from an already constructed node.
    /// Ownership: the controller takes ownership of the node. Isolation: MainActor. Errors: none.
    /// Cancellation: no work starts during initialization.
    public init(node: N, environment: EnvironmentScope? = nil) {
        self.node = node
        actions = ActionPipe()
        router = RoutePipe()
        if let environment { node.inheritEnvironment(from: environment) }
    }

    public var anyNode: Node { node }

    /// Connects composition and bindings for a container. Ownership: controller retains its scope.
    /// Isolation: MainActor. Errors: invalid state returns false. Cancellation: none until disposal.
    public func connectForContainer() -> Bool { connect() }

    /// Describes controller composition without starting effects.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func compose() {}

    /// Registers bindings in the controller connection scope.
    /// Ownership: connections are borrowed. Isolation: MainActor. Errors: typed failures stay in
    /// the owning scope. Cancellation: scope cancellation ends registered work.
    open func connect(_ connections: ControllerConnections<A, R>) {}

    /// Called once when the controller becomes active.
    /// Ownership: context is borrowed. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func activated(_ context: ActivationContext) {}

    /// Called once when the controller becomes inactive.
    /// Ownership: context is borrowed. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func deactivated(_ context: DeactivationContext) {}

    /// Called after an environment revision is committed.
    /// Ownership: changes are borrowed. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    open func environmentChanged(_ changes: EnvironmentChanges) {}

    /// Called once after terminal disposal.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: all owned work is cancelled.
    open func disposed() {}

    /// Connects composition and bindings exactly once.
    /// Ownership: the controller retains its scope. Isolation: MainActor. Errors: invalid transitions return false.
    /// Cancellation: dispose cancels the scope.
    @discardableResult
    public func connect() -> Bool {
        guard !didConnect, !isDisposed else { return false }
        if !didCompose {
            compose()
            didCompose = lifecycle.transition(.compose)
        }
        guard didCompose, node.connect() else { return false }
        guard lifecycle.transition(.connect),
            let scope = lifecycle.connectionScope
        else { return false }
        didConnect = true
        connect(ControllerConnections(actions: actions, routes: router, scope: scope))
        return true
    }

    /// Activates the controller once after connection.
    /// Ownership: context is copied. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: deactivation follows lifecycle policy.
    @discardableResult
    public func activate() -> Bool {
        let mounted: Bool
        if lifecycle.state == .inactive {
            mounted = true
        } else {
            mounted = lifecycle.transition(.mount)
        }
        guard mounted, lifecycle.transition(.activate) else { return false }
        activated(ActivationContext())
        return true
    }

    /// Activates this controller for a container transition.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: lifecycle policy applies.
    public func activateForContainer() -> Bool { activate() }

    /// Deactivates the controller once.
    /// Ownership: context is copied. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: policy-controlled effects are suspended.
    @discardableResult
    public func deactivate() -> Bool {
        guard lifecycle.transition(.deactivate) else { return false }
        deactivated(DeactivationContext())
        return true
    }

    /// Deactivates this controller for a container transition.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: lifecycle policy applies.
    public func deactivateForContainer() -> Bool { deactivate() }

    /// Dispatches a typed action to the bounded action output.
    /// Ownership: the action is copied. Isolation: MainActor. Errors: overflow is returned.
    /// Cancellation: disposed controllers reject further dispatch.
    @discardableResult
    public func dispatch(_ action: A) -> AsyncStream<A>.Continuation.YieldResult {
        guard !isDisposed else { return .dropped(action) }
        return actions.send(action)
    }

    /// Emits a typed navigation route.
    /// Ownership: the route is copied. Isolation: MainActor. Errors: overflow is returned.
    /// Cancellation: disposed controllers reject navigation output.
    @discardableResult
    public func navigate(
        to route: R,
        animated: Bool = true
    ) -> AsyncStream<R>.Continuation.YieldResult {
        _ = animated
        guard !isDisposed else { return .dropped(route) }
        return router.send(route)
    }

    /// Returns the current effective environment from the owned node.
    public var environment: EnvironmentValues { node.environment }

    /// Disposes node, bindings and outputs exactly once.
    /// Ownership: the controller releases all owned resources. Isolation: MainActor. Errors: none.
    /// Cancellation: every connection and output is terminated.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        _ = lifecycle.transition(.dispose)
        actions.finish()
        router.finish()
        node.dispose()
        disposed()
    }
}

extension Controller: ControllerRouteSource {
    func bindRoutes(
        to scope: ConnectionScope,
        handler: @MainActor @escaping @Sendable (any Route) -> Void
    ) {
        let subscription = router.flux.sinkOnMain(handler)
        scope.bind(id: ObjectIdentifier(self)) { subscription.cancel() }
    }
}

/// Controller with neither actions nor routes.
/// Ownership: inherited controller ownership. Isolation: MainActor. Errors: none. Cancellation: inherited.
public typealias Screen<N: Node> = Controller<N, Never, Never>

/// Controller with typed routes and no actions.
/// Ownership: inherited controller ownership. Isolation: MainActor. Errors: none. Cancellation: inherited.
public typealias FlowController<N: Node, R: Route> = Controller<N, Never, R>

/// Controller with typed actions and no routes.
/// Ownership: inherited controller ownership. Isolation: MainActor. Errors: none. Cancellation: inherited.
public typealias ActionController<N: Node, A: Action> = Controller<N, A, Never>
