# Application Startup

## Entry Point

The consumer defines exactly one entry point using the `Application` type from `Sources/Weave`:

```swift
import Weave

@main
struct MyApp: Application {
    func makeScene() -> WindowScene {
        let scene = WindowScene(id: "main")
        let coordinator = AppCoordinator()
        coordinator.start()

        let window = Window(rootController: coordinator.navigation.top)
        scene.add(window)
        _ = window.present()
        return scene
    }
}
```

`Application` is the single consumer entry point for iOS/macOS/tvOS.  
The platform selector in `Sources/Weave/Platform/ApplicationEntryPoint.swift` translates this  
to `UIApplicationDelegate` (iOS/tvOS) or `NSApplicationDelegate` (macOS) internally.  
**The consumer never touches platform delegates.**

## Bootstrap Sequence

```
1. OS launches app binary
       │
2. ApplicationEntryPoint (platform adapter) is installed
       │
3. Application.makeScene() called on @MainActor
       │
4. WindowScene created
   ├── EnvironmentScope (root, owns theme/locale/safeArea)
   ├── Router / Coordinator constructed
   └── Coordinator.start() → isRunning = true, ConnectionScope created
       │
5. Coordinator.started() hook → push initial route
   └── ScreenRegistry.make(for:) → Controller constructed
         └── Controller.node set up, Controller.connect() called
               └── compose() → connect(_:) → bindings registered
       │
6. Window created with rootController
   └── rootController.anyNode.inheritEnvironment(from: window.environment)
       │
7. window.present()
   └── rootController.connectForContainer()
       rootController.activateForContainer()
   └── Platform adapter receives Window ref → native window shown
```

## Lifecycle at Each Layer

### `WindowScene`
- Created once per scene session.
- Owns scene-level `EnvironmentScope`; platform traits (safe area, locale, color scheme)
  are injected here by the adapter.
- `close()` terminates coordinator and all windows.

### `Window`
- Owns a child `EnvironmentScope` (parent = scene scope).
- Owns `ThemeStore` — watch via `ThemeStore.currentTheme` Flux.
- `present()` → activation propagates to `rootController`.
- `dismiss()` → deactivation; root is kept alive.
- `close()` → root disposed; window is terminal.
- `setRootController(_:)` — swaps root mid-session; old root is disposed.

### `Controller`
Lifecycle driven by `Window`/`ContainerController` via `AnyController` protocol:

| Call | Controller transition |
|---|---|
| `connectForContainer()` | `compose()` → `connect(_:)` |
| `activateForContainer()` | `activated(_:)` |
| `deactivateForContainer()` | `deactivated(_:)` |
| `dispose()` | all bindings cancelled, node disposed |

## Environment Injection at Startup

The platform adapter pushes initial values into the root `EnvironmentScope` before  
`makeScene()` returns to the consumer:

```
EnvironmentScope.set(SafeAreaInsetsKey.self, platformSafeArea)
EnvironmentScope.set(LayoutDirectionKey.self, .leadingToTrailing / .trailingToLeading)
EnvironmentScope.commitTheme(colorScheme:, theme:)
```

Any subsequent trait change (rotate, dark mode toggle) re-sets the relevant keys.  
The change set propagates via `EnvironmentChangeSet` to `Controller.environmentChanged(_:)`.
