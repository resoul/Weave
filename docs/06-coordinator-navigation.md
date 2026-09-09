# Coordinator & Navigation

## Roles

| Type | Responsibility |
|---|---|
| `Coordinator<R>` | Owns a flow: starts/stops, handles typed routes, manages child flows |
| `NavigationController<R>` | Stack-based container of controllers |
| `ScreenRegistry` | Route → controller factory map |
| `Router` (protocol) | Scene-local route application to a specific container |
| `NavigationRouter<R>` | Connects a `Coordinator` to a `Router` slot |

## `Coordinator<R: Route>`

```swift
@MainActor
open class Coordinator<R: Route>: AnyCoordinator {
    public let navigation: NavigationController<R>
    public let registry: ScreenRegistry
    public var isRunning: Bool
    public let failures: ActionPipe<EffectFailure>

    func start() -> Bool       // idempotent, creates ConnectionScope
    func stop()                // cancels scope and all child flows
    open func started()        // override: push initial route
    open func stopped()        // override: cleanup

    open func handle(_ route: R, animated: Bool) async -> Bool
    // default: ScreenRegistry.make → navigation.push → bind child routes

    func wire(_ child: Coordinator<R>) -> Bool  // attach sub-flow
    func finish(_ child: Coordinator<R>)        // detach sub-flow
    func emit(_ route: R)                       // bubble route to parent
}
```

### Minimal coordinator

```swift
final class AppCoordinator: Coordinator<AppRoute> {
    init() {
        super.init(
            navigation: NavigationController<AppRoute>(),
            registry: Self.makeRegistry()
        )
    }

    override func started() {
        Task { await handle(.home) }
    }

    private static func makeRegistry() -> ScreenRegistry {
        let r = ScreenRegistry()
        r.register(HomeFactory(), for: AppRoute.Home.self)
        r.register(ProfileFactory(service: .shared), for: AppRoute.Profile.self)
        return r
    }
}
```

## Route Handling Flow

```
Controller.navigate(to: route)
  └── RoutePipe<R>.send(route)
        └── Coordinator receives via bindRoutes(to:handler:)
              └── scope.effect(id: requestID) {
                    await self.handle(route)
                  }

Coordinator.handle(route):
  1. navigationGeneration += 1           // stale-request guard
  2. ScreenRegistry.make(for: route)     // async factory, may throw
  3. generation check → drop if stale
  4. navigation.push(controller)
  5. bindRoutes(to: scope) — wire new controller's future routes
```

### Stale Request Guard

If the user navigates twice quickly, the second `handle` increments `navigationGeneration`.  
The first result checks `requestGeneration == navigationGeneration` before pushing —  
a stale result is silently dropped. No race, no double-push.

## `ScreenRegistry`

```swift
let registry = ScreenRegistry()

// Register a typed factory
registry.register(MyFactory(), for: MyRoute.self)

// Build a controller (async — factory may load resources)
let controller = try await registry.make(for: route, environment: env)
```

Factory errors (missing registration, construction failure) are published to  
`coordinator.failures` as `EffectFailure` values and **do not crash** the app.

## `NavigationController<R>`

Stack-based `ContainerController` subclass:

```swift
navigation.push(controller, animated: true)   // add to stack
navigation.pop(animated: true)                // remove top
navigation.dismiss(animated: true)            // same as pop at top level
```

The top-of-stack controller is activated; controllers below are deactivated but kept alive.

## Child Flows

```swift
override func started() {
    let authFlow = AuthCoordinator()
    wire(authFlow)                            // starts child, subscribes to its route events
    authFlow.routeEvents                      // child emits completion routes upward
}

// When child finishes:
finish(authFlow)                              // stops child, removes subscription
```

`wire(_:)` automatically forwards child route events to `self.handle(_:)`.

## `Router` Protocol & `NavigationRouter`

`Router` is the scene-local boundary where route strings or typed routes are applied  
to a specific container (e.g. push into a tab's navigation stack):

```swift
@MainActor
public protocol Router: AnyObject {
    func navigate(to route: any Route, animated: Bool)
    func present(_ route: any Route, animated: Bool)
    func dismiss(animated: Bool)
}
```

`NavigationRouter<R>` bridges a `Coordinator<R>` to this protocol:

```swift
let router = NavigationRouter(coordinator: appCoordinator)
let scene = WindowScene(id: "main", router: router)
```

## Deep Links

Deep links are routed through `DeepLink.swift` — parsed into typed `Route` values  
and forwarded to the appropriate `Coordinator` or `Router` via the `WindowScene`.

```swift
// In Application or SceneCoordinator:
func handle(url: URL) {
    if let route = AppRoute.parse(url) {
        scene.router.navigate(to: route, animated: false)
    }
}
```

## Navigation Restoration

`NavigationRestoration.swift` captures a `NavigationStackSnapshot`  
(array of `ObjectIdentifier`) and restores it by replaying routes through the registry.  
Restoration never bypasses the factory — it always constructs fresh controllers.

## Summary: Flow of a Navigation Action

```
User taps "Open Profile"
  └── ProfileNode dispatches Action.openProfile(id)
        └── ProfileController.dispatch(.openProfile(id))
              └── connections.actions.flux → viewModel.send(.openProfile(id))
                    └── viewModel.outputs → .profileRequested(id)
                          └── connections.handle { routes.send(.profile(id)) }
                                └── RoutePipe → Coordinator.handle(.profile(id))
                                      └── ScreenRegistry.make → ProfileController
                                            └── NavigationController.push(profileController)
                                                  └── Platform: slide animation
```
