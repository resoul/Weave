# Architecture Overview

## Layer Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Consumer App  (import Weave)                                            │
│  Application · WindowScene · Window · Coordinator · Controller · Node   │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ public API
┌────────────────────────────────▼─────────────────────────────────────────┐
│  Sources/Weave  (facade)                                                 │
│  @_exported: WeaveUI · WeaveAdapters · Flux                              │
│  Platform/: ApplicationEntryPoint — platform selector only here         │
└────────────┬───────────────────┬──────────────────────────────────────────┘
             │                   │
┌────────────▼──────┐  ┌─────────▼─────────────────────────────────────────┐
│  Sources/WeaveUI  │  │  Sources/WeaveAdapters                            │
│  Core contracts:  │  │  Render & display pipeline:                       │
│  Node, Window,    │  │  DisplayPipeline, RenderCoordinator,              │
│  Controller,      │  │  CoreTextRasterRenderer, ImageRasterRenderer,      │
│  ViewModel,       │  │  VideoPipeline, VisualStyleRenderer               │
│  Coordinator,     │  └─────────────────────────────────────────┬─────────┘
│  Environment,     │                                            │
│  Layout, Events,  │                 ┌──────────────────────────▼──────────┐
│  Navigation,      │                 │  UIKitAdapter / AppKitAdapter       │
│  Lifecycle, …     │                 │  Native bridging (hidden from Core) │
└────────────┬──────┘                 └─────────────────────────────────────┘
             │
┌────────────▼──────────────────────────────────────────────────────────────┐
│  Flux (external dependency — resoul/flux 1.2.0)                          │
│  Flux<Value>, Pipe, Store, Subscription, CurrentValueDistinct            │
└───────────────────────────────────────────────────────────────────────────┘

Optional integrations (never in Core graph):
  Logging · Networking · Storage · Analytics · NetworkingLogging

Tooling / Testing (never in production graph):
  WeaveTesting · Syntax
```

## Module Responsibilities

### `WeaveUI` — Core contracts
The platform-neutral heart of the framework. Contains:
- **Tree primitives**: `Node`, `ElementID`, `NodeContent`, `NodeDescriptor`
- **Lifecycle**: `LifecycleMachine`, `LifecycleState`, `ConnectionScope`
- **Controller layer**: `Controller<N,A,R>`, `ViewModel`, `Coordinator`
- **Environment**: `EnvironmentScope`, `EnvironmentKey`, `EnvironmentValues`
- **Layout**: `LayoutStyle`, `FlexSolver`, `LayoutEngine`, `LayoutResult`
- **Events**: `Event`, capture/target/bubble dispatch, `Gestures`
- **Navigation**: `NavigationController`, `ContainerController`, `WindowScene`, `Window`
- **Media**: `Image`, `Text`, `Video`, `Scroll`, `Collections`
- **Accessibility / Focus**: `AccessibilityTree`, `FocusTree` (separate from render tree)

**Rule**: `WeaveUI` has zero `#if os(...)` blocks, zero UIKit/AppKit imports.

### `WeaveAdapters` — Render backend
CALayer-based display pipeline sitting behind `WeaveUI` contracts.  
Produces `DisplayArtifact` from immutable `DisplayRequest` snapshots off MainActor.  
`RenderCoordinator` owns the connection between the node tree and native layers.

**Rule**: Depends on `WeaveUI`; never imported by `WeaveUI`.

### `UIKitAdapter` / `AppKitAdapter` — Native bridges
Platform-specific host objects (`UIViewController` / `NSViewController` wrapping),  
system delegate hooks, input forwarding, system appearance observation.  
Linked conditionally by the `Weave` facade target only.

**Rule**: Never exported to consumer namespace; bootstrap only.

### `Weave` — Facade
Re-exports `WeaveUI + WeaveAdapters + Flux` via `@_exported import`.  
`Sources/Weave/Platform/` contains the single allowed `#if os(...)` selector
that boots the correct native adapter. Consumer always writes `import Weave`.

## Ownership Graph (simplified)

```
Application
  └── WindowScene
        ├── EnvironmentScope (scene-level)
        ├── Router / Coordinator
        └── Window
              ├── EnvironmentScope (window-level, child of scene)
              ├── ThemeStore
              └── rootController: AnyController
                    └── Node (subtree)
                          ├── EnvironmentScope (node-level, child of parent node scope)
                          ├── LifecycleMachine
                          ├── ConnectionScope (created at .connect)
                          └── [children: Node]
```

## Concurrency Boundary

| Domain | Isolation |
|---|---|
| Node tree, layout apply, event dispatch | `@MainActor` |
| Layout solve, text measure, image decode | Sendable snapshot on a worker |
| ViewModel state, `send(_:)` | Actor-isolated (often `@MainActor`, may be any actor) |
| Flux delivery to UI | `.sinkOnMain` — always `@MainActor` |
| Store read/write | `async throws`, never blocks MainActor |
