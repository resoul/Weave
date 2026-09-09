# Environment

## Purpose

`Environment` is the **only** propagation path for cross-cutting concerns:
- Theme / color scheme
- Locale / text direction (RTL/LTR)
- Safe area insets
- Resource policy (memory budget, decode concurrency)
- App-level services (injected via custom keys)

**Not for**: mutable domain state, per-screen business data, controller references.

## `EnvironmentKey`

Define a key to add a new environment value:

```swift
// Key definition
enum AppLocaleKey: EnvironmentKey {
    typealias Value = Locale
    static let defaultValue: Locale = .autoupdatingCurrent
    static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
    // .none / .display / .layout / .accessibility / .layoutAndDisplay
}

// EnvironmentValues extension for ergonomic access
extension EnvironmentValues {
    var appLocale: Locale {
        get { self[AppLocaleKey.self] }
        set { self[AppLocaleKey.self] = newValue }
    }
}
```

`invalidation` tells the framework which committed work must be re-run when this key changes.

## `EnvironmentScope` — Tree Propagation

`EnvironmentScope` is a MainActor reference type. Each `Node` owns one scope.  
Child scopes inherit from parent via a weak reference:

```
WindowScene.environment (root scope)
  └── Window.environment (child of scene scope)
        └── Node.scope (child of parent node's scope)
              └── Node.scope (deeper child)
```

Setting a value on a scope **shadows** the parent's value for that key only:

```swift
// At window level — applies to all nodes in this window
window.environment.set(ThemeKey.self, darkTheme)

// At a subtree node — overrides only for that subtree
specialNode.scope.set(FontScaleKey.self, 1.5)
```

`addSubnode` automatically calls `child.scope.reparent(to: parent.scope)`.

## `EnvironmentSnapshot` — Crossing Actor Boundaries

`EnvironmentValues` is mutable (MainActor). To pass env values to off-MainActor layout/display workers,
capture an immutable `EnvironmentSnapshot`:

```swift
// On MainActor:
let snapshot: EnvironmentSnapshot = node.environmentSnapshot
// snapshot.values: EnvironmentValues (immutable copy)
// snapshot.revision: UInt64

// Off-MainActor layout worker:
let direction = snapshot.values.layoutDirection
```

`LayoutInputSnapshot` (fed to `FlexSolver`) carries a `EnvironmentSnapshot` inside —  
it is safe to send across actor boundaries.

## `EnvironmentChangeSet` — Invalidation Tracking

`scope.set(_:_:)` returns an `EnvironmentChangeSet` describing what changed:

```swift
let changes = window.environment.set(SafeAreaInsetsKey.self, newInsets)
// changes.revision: the new monotonic revision
// changes.invalidation: .layoutAndDisplay (from SafeAreaInsetsKey.invalidation)
```

The framework uses `EnvironmentChangeSet.affects(_:EnvironmentDependencies)` to skip  
re-layout or re-render for nodes that didn't read the changed key:

```swift
// Layout worker records which keys it used:
var deps = EnvironmentDependencies()
let direction = snapshot.read(LayoutDirectionKey.self, recording: &deps)

// Later, on commit:
if !changeSet.affects(deps) {
    // Skip re-layout — this node doesn't care about the change
}
```

## `commitTheme(colorScheme:theme:)` — Batch Commits

Theme changes always affect two keys at once. `commitTheme` commits them atomically  
under a single revision to avoid double-invalidation:

```swift
let changes = scope.commitTheme(colorScheme: .dark, theme: .nightMode)
// changes.changes.count == 2 (ColorSchemeKey + ThemeKey)
// changes.revision is the same for both
```

## Scope Reparenting

When a node is moved in the tree (reconciliation move or `addSubnode`/`removeFromSupernode`),  
`scope.reparent(to:)` is called. The scope retains its own overrides but now inherits  
from the new parent:

```swift
// Internally in addSubnode:
node.scope.reparent(to: self.scope)
```

## Accessing Environment in a Node

```swift
// Read current effective values
let values: EnvironmentValues = node.environment

// Read within a layout pass (records dependency)
var deps = EnvironmentDependencies()
let insets = node.environmentSnapshot.read(SafeAreaInsetsKey.self, recording: &deps)
```

## Built-in Environment Keys

| Key | Value Type | Invalidation | Set by |
|---|---|---|---|
| `SafeAreaInsetsKey` | `SafeAreaInsets` | `.layoutAndDisplay` | Platform adapter |
| `LayoutDirectionKey` | `LayoutDirection` | `.layoutAndDisplay` | Platform adapter |
| `ColorSchemeKey` | `ColorScheme` | `.layoutAndDisplay` | Platform adapter / app |
| `ThemeKey` | `Theme` | `.layoutAndDisplay` | `Window.themeStore` |
| `ResourceConfigurationKey` | `EnvironmentResourceConfiguration` | `.none` | App startup |
