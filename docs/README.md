# Weave — Documentation Index

> Platform-neutral UI framework for iOS 16+, macOS 14+, tvOS 16+.  
> Swift 6 language mode, strict concurrency.

## Guides

| Document | Scope |
|---|---|
| [Architecture Overview](01-architecture.md) | Layer diagram, module boundaries, ownership graph |
| [Application Startup](02-startup.md) | `Application` → `WindowScene` → `Window` bootstrap |
| [Node & Composition](03-nodes.md) | `Node`, `compose()`, `NodeContent`, reconciliation |
| [Lifecycle](04-lifecycle.md) | `LifecycleState` state machine, `ConnectionScope` |
| [Controller & ViewModel](05-controller-viewmodel.md) | `Controller`, `ViewModel`, `ControllerConnections` |
| [Coordinator & Navigation](06-coordinator-navigation.md) | `Coordinator`, `ScreenRegistry`, `NavigationController` |
| [Environment](07-environment.md) | `EnvironmentScope`, `EnvironmentKey`, propagation rules |
| [Layout Pipeline](08-layout.md) | `LayoutStyle`, `FlexSolver`, snapshot → result → apply |
| [Events & Gestures](09-events.md) | Capture/target/bubble, `Event`, gesture state machines |
| [Render & Display](10-render.md) | `DisplayPipeline`, `RenderCoordinator`, CALayer backend |
| [Flux Integration](11-flux.md) | `Flux`, `Pipe`, `Subscription`, concurrency rules |
| [Optional Integrations](12-integrations.md) | `Logging`, `Networking`, `Storage`, `Analytics` |
