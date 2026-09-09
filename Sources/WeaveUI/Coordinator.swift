import Foundation

public import Flux

/// Errors raised while resolving a route through `ScreenRegistry`.
/// Ownership: immutable error value. Isolation: none. Errors: describes missing or invalid registration. Cancellation: factory cancellation is propagated separately.
public enum ScreenRegistryError: Error, Sendable, Hashable {
    case missingFactory(routeType: String)
    case routeTypeMismatch(routeType: String)
}

/// Typed screen composition contract.
/// Ownership: factory is Sendable and returns a newly owned controller. Isolation: MainActor for UI construction. Errors: construction may throw. Cancellation: async construction observes caller cancellation.
public protocol ScreenFactory: Sendable {
    associatedtype RouteType: Route

    @MainActor
    func make(route: RouteType, environment: EnvironmentValues) async throws -> any AnyController
}

/// MainActor-owned route-to-screen factory registry.
/// Ownership: registry owns type-erased factory closures. Isolation: MainActor. Errors: missing or mismatched routes throw. Cancellation: in-flight factory tasks are caller-owned.
@MainActor
public final class ScreenRegistry {
    private typealias ErasedFactory =
        @MainActor @Sendable (any Route, EnvironmentValues) async throws -> any AnyController
    private var factories: [ObjectIdentifier: ErasedFactory] = [:]

    /// Creates an empty registry. Ownership: registry owns its registrations. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {}

    /// Registers or replaces a factory for its route type. Ownership: registry retains the Sendable closure. Isolation: MainActor. Errors: duplicate type replaces prior registration. Cancellation: none.
    public func register<F: ScreenFactory>(_ factory: F, for route: F.RouteType.Type) {
        factories[ObjectIdentifier(route)] = { value, environment in
            guard let typed = value as? F.RouteType else {
                throw ScreenRegistryError.routeTypeMismatch(
                    routeType: String(reflecting: F.RouteType.self))
            }
            return try await factory.make(route: typed, environment: environment)
        }
    }

    /// Builds a controller for a typed route. Ownership: returned controller is owned by the caller. Isolation: MainActor. Errors: missing/mismatched registrations and factory failures propagate. Cancellation: caller cancellation propagates to the factory.
    public func make(
        for route: any Route,
        environment: EnvironmentValues = EnvironmentValues()
    ) async throws -> any AnyController {
        guard let factory = factories[ObjectIdentifier(type(of: route))] else {
            throw ScreenRegistryError.missingFactory(routeType: String(reflecting: type(of: route)))
        }
        return try await factory(route, environment)
    }
}

/// Scene-scoped router that resolves typed routes through one coordinator.
/// Ownership: router borrows the coordinator and owns no controller. Isolation: MainActor. Errors: foreign route types are ignored. Cancellation: navigation tasks follow coordinator policy.
@MainActor
public final class NavigationRouter<R: Route>: Router {
    public weak var coordinator: Coordinator<R>?

    /// Creates a router for a coordinator. Ownership: router does not retain the coordinator. Isolation: MainActor. Errors: none. Cancellation: coordinator owns navigation work.
    public init(coordinator: Coordinator<R>? = nil) { self.coordinator = coordinator }

    /// Resolves and navigates to a matching route. Ownership: route is borrowed. Isolation: MainActor. Errors: foreign routes are ignored and factory failures are reported by coordinator. Cancellation: stale requests are dropped.
    public func navigate(to route: any Route, animated: Bool) {
        guard let typed = route as? R, let coordinator else { return }
        Task { @MainActor in _ = await coordinator.handle(typed, animated: animated) }
    }

    /// Presents a matching route through the coordinator policy. Ownership: route is borrowed. Isolation: MainActor. Errors: foreign routes are ignored. Cancellation: stale requests are dropped.
    public func present(_ route: any Route, animated: Bool) {
        navigate(to: route, animated: animated)
    }

    /// Dismisses the top route when the coordinator is available. Ownership: no value escapes. Isolation: MainActor. Errors: empty stack is ignored. Cancellation: none.
    public func dismiss(animated: Bool) {
        _ = coordinator?.navigation.dismiss(animated: animated)
    }
}

/// Type-erased coordinator lifecycle boundary used by a parent flow.
/// Ownership: parent owns the child reference. Isolation: MainActor. Errors: invalid lifecycle calls return false. Cancellation: stop cancels child routing work.
@MainActor
public protocol AnyCoordinator: AnyObject {
    var isRunning: Bool { get }
    func start() -> Bool
    func stop()
}

/// MainActor-owned typed flow coordinator.
/// Ownership: coordinator owns its navigation container, route output, child flows and connection scope.
/// Isolation: MainActor. Errors: factory/construction errors are exposed through `failures`. Cancellation: stop cancels route wiring and child flows.
@MainActor
open class Coordinator<R: Route>: AnyCoordinator {
    private struct RouteRequestID: Hashable {
        let controller: ObjectIdentifier
    }

    public let navigation: NavigationController<R>
    public let registry: ScreenRegistry
    public private(set) var isRunning = false
    public let failures = ActionPipe<EffectFailure>(capacity: 32)

    private let routePipe = Pipe<R>(bufferingPolicy: .bufferingNewest(64))
    private var scope: ConnectionScope?
    private var children: [Coordinator<R>] = []
    private var wiredChildren: Set<ObjectIdentifier> = []
    private var navigationGeneration: UInt64 = 0

    /// Creates a coordinator with an owned navigation container and registry. Ownership: coordinator retains both. Isolation: MainActor. Errors: none. Cancellation: no effects start.
    public init(
        navigation: NavigationController<R> = NavigationController<R>(),
        registry: ScreenRegistry = ScreenRegistry()
    ) {
        self.navigation = navigation
        self.registry = registry
    }

    /// Routes emitted by this flow. Ownership: bounded stream owns subscriber buffers. Isolation: subscription is Sendable. Errors: overflow is reported by the stream policy. Cancellation: stop finishes the current scope but keeps the pipe reusable.
    public var routeEvents: Flux<R> { routePipe.flux }

    /// Starts the flow once and prepares a new owned connection scope. Ownership: coordinator owns scope. Isolation: MainActor. Errors: repeated start returns false. Cancellation: stop cancels the scope.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        scope = ConnectionScope()
        started()
        return true
    }

    /// Hook invoked after start commits. Ownership: no value escapes. Isolation: MainActor. Errors: subclasses should report typed failures. Cancellation: scope owns registered work.
    open func started() {}

    /// Stops the flow and all child flows. Ownership: child references are released. Isolation: MainActor. Errors: repeated stop is a no-op. Cancellation: route wiring and effects are cancelled.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        navigationGeneration &+= 1
        scope?.cancelAll()
        scope = nil
        children.forEach { $0.stop() }
        children.removeAll()
        wiredChildren.removeAll()
        stopped()
    }

    /// Hook invoked after stop commits. Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: child work is already cancelled.
    open func stopped() {}

    /// Wires a child flow exactly once while running. Ownership: parent retains child and subscription. Isolation: MainActor. Errors: stopped parent or duplicate child returns false. Cancellation: stop cancels the subscription and child.
    @discardableResult
    public func wire(_ child: Coordinator<R>) -> Bool {
        guard isRunning, !child.isRunning else { return false }
        let identity = ObjectIdentifier(child)
        guard wiredChildren.insert(identity).inserted else { return false }
        children.append(child)
        _ = child.start()
        guard let scope else { return false }
        let task = Task { @MainActor [weak self, weak child] in
            guard let child else { return }
            for await route in child.routeEvents.stream {
                guard !Task.isCancelled, let self, self.isRunning else { break }
                await self.handle(route)
            }
        }
        scope.bind(id: identity) { task.cancel() }
        return true
    }

    /// Removes a child flow after completion. Ownership: parent releases and stops child. Isolation: MainActor. Errors: unknown child is ignored. Cancellation: child route wiring is cancelled.
    public func finish(_ child: Coordinator<R>) {
        guard let index = children.firstIndex(where: { $0 === child }) else { return }
        children.remove(at: index)
        wiredChildren.remove(ObjectIdentifier(child))
        scope?.cancel(id: ObjectIdentifier(child))
        child.stop()
    }

    /// Emits a typed route while running. Ownership: route is copied into a bounded buffer. Isolation: MainActor. Errors: stopped flows drop routes. Cancellation: none.
    @discardableResult
    public func emit(_ route: R) -> AsyncStream<R>.Continuation.YieldResult {
        guard isRunning else { return .dropped(route) }
        return routePipe.sendObservingOverflow(route).first ?? .dropped(route)
    }

    /// Resolves a route through the registry and pushes the resulting controller. Ownership: navigation owns the controller after success. Isolation: MainActor. Errors: factory failures are published and return false. Cancellation: cancelled construction does not mutate navigation.
    @discardableResult
    open func handle(_ route: R, animated: Bool = true) async -> Bool {
        guard isRunning else { return false }
        navigationGeneration &+= 1
        let requestGeneration = navigationGeneration
        do {
            let controller = try await registry.make(
                for: route, environment: navigation.containerNode.environment)
            guard isRunning, requestGeneration == navigationGeneration else { return false }
            guard navigation.push(controller, animated: animated) else { return false }
            if let source = controller as? any ControllerRouteSource, let scope {
                let requestID = RouteRequestID(controller: ObjectIdentifier(source))
                source.bindRoutes(to: scope) { [weak self, weak scope] route in
                    guard let self, let scope, let typed = route as? R, self.isRunning else {
                        return
                    }
                    scope.effect(id: requestID) { [weak self] in
                        guard let self else { return }
                        _ = await self.handle(typed)
                    }
                }
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            _ = failures.send(
                EffectFailure(
                    effectID: String(describing: route), message: String(describing: error)))
            return false
        }
    }
}

/// Navigation-specialized coordinator name for consumers that want an explicit flow role.
/// Ownership: inherits Coordinator ownership. Isolation: MainActor. Errors: inherits route handling policy. Cancellation: inherits stop policy.
@MainActor
public final class NavigationCoordinator<R: Route>: Coordinator<R> {}
