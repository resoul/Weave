import Foundation

public import Flux

/// Stable identity for one independently restored scene.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct SceneID: Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Creates an identity from a stable application string. Ownership: value is copied. Isolation: none. Errors: empty values are allowed. Cancellation: none.
    public init(_ rawValue: String) { self.rawValue = rawValue }
    /// Creates an identity from a string literal. Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(stringLiteral value: String) { self.init(value) }
}

/// Lifecycle state published by a window.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum WindowActivationState: Sendable, Hashable {
    case inactive
    case active
    case background
    case closed
}

/// Scene-local route application boundary.
/// Ownership: conforming router owns its route state. Isolation: MainActor. Errors: implementations report invalid routes through their own policy. Cancellation: caller-owned.
@MainActor
public protocol Router: AnyObject {
    func navigate(to route: any Route, animated: Bool)
    func present(_ route: any Route, animated: Bool)
    func dismiss(animated: Bool)
}

/// Deterministic scene-local router slot used when no product router is installed.
/// Ownership: the scene owns this router. Isolation: MainActor. Errors: calls are recorded as bounded route events. Cancellation: disposal is owned by the scene.
@MainActor
public final class SceneRouter: Router {
    private let routePipe = Pipe<String>(bufferingPolicy: .bufferingNewest(32))

    /// Creates an empty router. Ownership: router owns its bounded pipe. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {}

    /// Bounded route event stream for adapters and restoration. Ownership: values are copied. Isolation: MainActor. Errors: overflow is coalesced by policy. Cancellation: subscription cancellation.
    public var routeEvents: Flux<String> { routePipe.flux }

    /// Applies a route event. Ownership: route is borrowed for the call. Isolation: MainActor. Errors: bounded overflow is coalesced. Cancellation: none.
    public func navigate(to route: any Route, animated: Bool) {
        _ = animated
        _ = routePipe.sendObservingOverflow(route.path)
    }

    /// Presents a route through the same scene-local event stream. Ownership: route is borrowed. Isolation: MainActor. Errors: bounded overflow is coalesced. Cancellation: none.
    public func present(_ route: any Route, animated: Bool) {
        navigate(to: route, animated: animated)
    }

    /// Dismisses the current route. Ownership: none. Isolation: MainActor. Errors: no-op when empty. Cancellation: none.
    public func dismiss(animated: Bool) { _ = animated }
}

/// MainActor-owned native-independent window lifecycle owner.
/// Ownership: the window owns its environment scope and root controller. Isolation: MainActor.
/// Errors: invalid transitions return false. Cancellation: close disposes the root and its effects.
@MainActor
public final class Window {
    private static var nextID: ElementID = 0

    /// Stable runtime identity for this window.
    public let id: ElementID
    public let environment: EnvironmentScope
    /// Window-owned theme source used by platform appearance bridges.
    public let themeStore: ThemeStore
    public private(set) var rootController: (any AnyController)?
    public private(set) var activationState: WindowActivationState = .inactive
    private let activationPipe = Pipe<WindowActivationState>(bufferingPolicy: .bufferingNewest(16))
    private var isClosed = false

    /// Creates an isolated window scope. Ownership: window owns a fresh environment unless supplied. Isolation: MainActor. Errors: none. Cancellation: no effects start.
    public init(
        environment: EnvironmentScope = EnvironmentScope(),
        rootController: (any AnyController)? = nil,
        themeStore: ThemeStore = ThemeStore(palette: .standard)
    ) {
        Self.nextID &+= 1
        id = Self.nextID
        self.environment = environment
        self.themeStore = themeStore
        self.rootController = rootController
        if let rootController { rootController.anyNode.inheritEnvironment(from: environment) }
    }

    /// Activation state stream. Ownership: stream is borrowed from the window. Isolation: subscription is Sendable. Errors: none. Cancellation: subscription cancellation.
    public var activation: Flux<WindowActivationState> { activationPipe.flux }

    /// Replaces the root and disposes the previous root once. Ownership: window takes ownership of the new root. Isolation: MainActor. Errors: closed windows reject replacement. Cancellation: old root is disposed.
    @discardableResult
    public func setRootController(_ controller: (any AnyController)?) -> Bool {
        guard !isClosed else { return false }
        guard controller !== rootController else { return true }
        let old = rootController
        rootController = controller
        old?.dispose()
        if let controller {
            controller.anyNode.inheritEnvironment(from: environment)
            _ = controller.connectForContainer()
            if activationState == .active { _ = controller.activateForContainer() }
        }
        return true
    }

    /// Presents the window and activates its root. Ownership: no ownership changes. Isolation: MainActor. Errors: closed windows return false. Cancellation: none.
    @discardableResult
    public func present() -> Bool {
        guard !isClosed else { return false }
        guard activationState != .active else { return true }
        activationState = .active
        _ = rootController?.connectForContainer()
        _ = rootController?.activateForContainer()
        _ = activationPipe.sendObservingOverflow(.active)
        return true
    }

    /// Hides the window without disposing its root. Ownership: root remains window-owned. Isolation: MainActor. Errors: closed windows return false. Cancellation: active root effects are deactivated.
    @discardableResult
    public func dismiss() -> Bool {
        guard !isClosed, activationState == .active else { return false }
        _ = rootController?.deactivateForContainer()
        activationState = .inactive
        _ = activationPipe.sendObservingOverflow(.inactive)
        return true
    }

    /// Closes the window exactly once. Ownership: root is disposed and released. Isolation: MainActor. Errors: repeated close is a no-op. Cancellation: all window-owned effects terminate.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        _ = rootController?.deactivateForContainer()
        rootController?.dispose()
        rootController = nil
        activationState = .closed
        _ = activationPipe.sendObservingOverflow(.closed)
        activationPipe.finish()
    }
}

/// MainActor-owned scene containing isolated windows, environment and router state.
/// Ownership: scene owns windows and its router/environment. Isolation: MainActor. Errors: duplicate window identities are rejected. Cancellation: closing a scene closes every window.
@MainActor
public final class WindowScene {
    public let id: SceneID
    public let environment: EnvironmentScope
    public let router: any Router
    public let coordinator: (any AnyCoordinator)?
    public private(set) var windows: [Window] = []
    private var isClosed = false

    /// Creates an isolated scene. Ownership: scene owns its environment and router. Isolation: MainActor. Errors: none. Cancellation: no effects start.
    public init(
        id: SceneID,
        environment: EnvironmentScope = EnvironmentScope(),
        router: (any Router)? = nil,
        coordinator: (any AnyCoordinator)? = nil
    ) {
        self.id = id
        self.environment = environment
        self.router = router ?? SceneRouter()
        self.coordinator = coordinator
    }

    /// Adds a window to the scene. Ownership: scene retains the window. Isolation: MainActor. Errors: closed scenes and duplicate instances return false. Cancellation: none.
    @discardableResult
    public func add(_ window: Window) -> Bool {
        guard !isClosed, !windows.contains(where: { $0 === window }) else { return false }
        windows.append(window)
        return true
    }

    /// Removes and closes a window. Ownership: scene releases the window. Isolation: MainActor. Errors: unknown window returns false. Cancellation: removed window is closed.
    @discardableResult
    public func close(_ window: Window) -> Bool {
        guard let index = windows.firstIndex(where: { $0 === window }) else { return false }
        windows.remove(at: index)
        window.close()
        return true
    }

    /// Closes the scene and all windows exactly once. Ownership: all scene-owned references are released. Isolation: MainActor. Errors: repeated close is a no-op. Cancellation: window effects terminate.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        coordinator?.stop()
        windows.forEach { $0.close() }
        windows.removeAll()
    }
}
