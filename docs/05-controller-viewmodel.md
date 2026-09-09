# Controller & ViewModel

## Roles

| Type | Responsibility |
|---|---|
| `ViewModel` | Intents → immutable state + typed outputs. Actor-compatible, no Node/Controller imports |
| `Controller<N,A,R>` | Lifecycle bindings, wires ViewModel ↔ Node, emits typed routes |
| `Factory` (user-defined) | Assembles Controller + ViewModel + dependencies |
| `Coordinator` | Owns the flow, handles route outputs from controllers |

## `ViewModel` Protocol

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

- `state` — `CurrentValueDistinct<State>`: latest-wins, skips equal values, bridgeable to `Flux`
- `outputs` — bounded `Flux<Output>` for events that escape the screen (e.g. "user logged in")
- `send(_:)` — handles one intent in actor order; may be `@MainActor` or any custom actor

### Minimal ViewModel

```swift
@MainActor
final class ProfileViewModel: ViewModel {
    enum Intent: Sendable { case refresh, tapFollow }
    enum Output: Sendable { case followRequested(userID: String) }

    let state = CurrentValueDistinct(ScreenState<ProfileContent>.loading)
    let outputs = ActionPipe<Output>(capacity: 32)

    var outputsFlux: Flux<Output> { outputs.flux }

    func send(_ intent: Intent) async {
        switch intent {
        case .refresh:
            state.value = .loading
            do {
                let profile = try await profileService.fetch()
                state.value = .content(profile)
            } catch {
                state.value = .error(error.localizedDescription)
            }
        case .tapFollow:
            _ = outputs.send(.followRequested(userID: currentUserID))
        }
    }
}
```

## `Controller<N, A, R>`

Generic over:
- `N: Node` — the owned root node
- `A: Action` — typed actions dispatched by the node tree
- `R: Route` — typed navigation outputs

Common typealiases:
```swift
typealias Screen<N: Node>               = Controller<N, Never, Never>
typealias FlowController<N: Node, R: Route> = Controller<N, Never, R>
typealias ActionController<N: Node, A: Action> = Controller<N, A, Never>
```

### Controller lifecycle hooks

```swift
open class MyController: Screen<MyNode> {
    override func compose() {
        // describe node tree structure (no effects)
    }

    override func connect(_ connections: ControllerConnections<Never, Never>) {
        // register all bindings and effects here
    }

    override func activated(_ context: ActivationContext) {
        // user sees the screen
    }

    override func deactivated(_ context: DeactivationContext) {
        // screen hidden; cancelOnDeactivate effects suspended
    }

    override func environmentChanged(_ changes: EnvironmentChanges) {
        // theme, locale, or layout direction changed
    }

    override func disposed() {
        // terminal cleanup
    }
}
```

## `ControllerConnections<A, R>`

Passed to `connect(_:)` once, provides:

| Property | Type | Use |
|---|---|---|
| `actions` | `ActionPipe<A>` | Receive typed actions from the node tree |
| `routes` | `RoutePipe<R>` | Emit navigation routes |
| `scope` | `ConnectionScope` | Register bindings and async effects |

### Wiring ViewModel

```swift
override func connect(_ connections: ControllerConnections<MyAction, MyRoute>) {
    let vm = viewModel   // injected via factory

    // 1. Forward actions → ViewModel intents (when Action == Intent)
    connections.forward(connections.actions, to: vm)

    // 2. Render state on MainActor
    connections.render(vm.state) { [weak self] state in
        self?.node.apply(state)
    }

    // 3. Handle outputs at screen boundary
    connections.handle(vm.outputs) { [weak self] output in
        switch output {
        case .followRequested(let id):
            _ = self?.connections.routes.send(.userProfile(id))
        }
    }
}
```

### Starting an async effect

```swift
connections.scope.effect(id: "periodicRefresh", cancelOnDeactivate: true) {
    while !Task.isCancelled {
        try await Task.sleep(nanoseconds: 30_000_000_000)
        await vm.send(.refresh)
    }
}
```

## Factory Pattern

Factories are `Sendable` types conforming to `ScreenFactory`:

```swift
struct ProfileFactory: ScreenFactory {
    typealias RouteType = AppRoute.Profile

    let profileService: ProfileService   // Sendable dependency

    @MainActor
    func make(route: AppRoute.Profile, environment: EnvironmentValues) async throws -> any AnyController {
        let vm = ProfileViewModel(service: profileService, userID: route.userID)
        let node = ProfileNode()
        let controller = ProfileController(node: node, viewModel: vm)
        return controller
    }
}
```

Register with `ScreenRegistry`:
```swift
registry.register(ProfileFactory(service: …), for: AppRoute.Profile.self)
```

## Data Flow Summary

```
User interaction
  └── Node dispatches Action (via Controller.dispatch(_:) or ActionPipe)
        └── ControllerConnections.actions.flux
              └── connections.forward(…, to: viewModel)
                    └── viewModel.send(intent)   // actor-isolated
                          └── viewModel.state.value = newState
                                └── Flux<State> delivered on @MainActor
                                      └── connections.render { node.apply(state) }
                                            └── node.setNeedsDisplay() / setNeedsLayout()

Output path:
  viewModel.outputs  →  connections.handle  →  router.send(route)
    └── Coordinator.handle(route)  →  ScreenRegistry.make  →  navigation.push(controller)
```
