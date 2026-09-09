# Node & Composition

## What is a Node?

`Node` is the fundamental building block of the Weave UI tree. It is:

- A **MainActor-owned** class (`@MainActor open class Node`)
- **Passive**: holds layout style, visual appearance, accessibility, children
- **No platform objects** during `init` or `compose()`; adapters allocate backing lazily
- Identified by a stable `ElementID` (`UInt64`) for the duration of its life

```swift
// Minimal custom node
final class AvatarNode: Node {
    var imageURL: URL? {
        didSet { setNeedsDisplay() }
    }

    override var layoutContentMetrics: LayoutContentMetrics {
        LayoutContentMetrics(intrinsicSize: LayoutSize(width: 44, height: 44))
    }
}
```

## Node Properties

| Property | Type | Description |
|---|---|---|
| `id` | `ElementID` | Stable runtime identity |
| `style` | `LayoutStyle` | Flex layout properties; `didSet` calls `setNeedsLayout()` |
| `appearance` | `VisualStyle` | Paint-only (background, border, shadow, opacity); `didSet` calls `setNeedsVisualStyleUpdate()` |
| `semantics` | `NodeSemantics` | Label, hidden flag — separate from render tree |
| `accessibility` | `AccessibilityProperties` | A11y tree properties; `didSet` calls `setNeedsAccessibilityUpdate()` |
| `focusEligibility` | `FocusEligibility` | `.automatic / .eligible / .excluded` |
| `calculatedFrame` | `LayoutFrame?` | Set after layout result applied |
| `isLoaded` | `Bool` | True once a platform backing object is materialized |

## Revision Counters

The framework uses monotonically increasing counters to detect stale work:

| Counter | Incremented by | Consumed by |
|---|---|---|
| `layoutRevision` | `setNeedsLayout()` | Layout engine — stale result rejected if revision changed |
| `displayRevision` | `setNeedsDisplay()` | Display pipeline — stale artifact rejected |
| `appearanceRevision` | `setNeedsVisualStyleUpdate()` | Render coordinator — paint-only fast path |
| `accessibilityRevision` | `setNeedsAccessibilityUpdate()` | Accessibility tree rebuilder |

## `compose()` — Declarative Description

Override `compose()` to describe children **without side effects**:

```swift
override func compose() -> NodeContent {
    .children([
        NodeDescriptor(typeName: "HeaderNode"),
        NodeDescriptor(typeName: "BodyNode", key: "body"),
        NodeDescriptor(typeName: "FooterNode"),
    ])
}
```

**Rules for `compose()`**:
- Returns an immutable `NodeContent` value — no mutations, subscriptions or tasks here
- `init` assigns dependencies; `connect()` owns side effects
- The framework calls `compose()` during reconciliation, not continuously

## Tree Mutations

All tree operations are MainActor-only and synchronous:

```swift
// Add a child (atomically reparents, rejects cycles)
parentNode.addSubnode(childNode)

// Remove from parent (does not dispose)
childNode.removeFromSupernode()

// Find by ElementID
if let found = rootNode.findNode(id: someID) { … }
```

`addSubnode` also:
- Calls `childNode.scope.reparent(to: parentScope)` — environment inheritance
- Calls `setNeedsLayout()` on the parent

## Reconciliation

The `Reconciler` differs two `[NodeDescriptor]` arrays and emits typed patches:

```
ReconciliationPatch:
  .insert(descriptor:atIndex:)
  .remove(identity:fromIndex:)
  .update(atIndex:descriptor:)
  .move(identity:fromIndex:toIndex:)
  .replace(atIndex:descriptor:)
```

Key matching rules:
- If `descriptor.key != nil` and unique → keyed match (stable node survives reorder)
- Otherwise → positional match by sibling index
- Type mismatch at same position → `.replace` (old node disposed, new node created)

The reconciler applies patches via `insertReconciledChild`, `removeReconciledChild`,
`moveReconciledChild` (internal API, called by `NodeReconciliation`).

## Layout Content Metrics

Override to provide intrinsic size to the layout engine:

```swift
// Fixed intrinsic size
override var layoutContentMetrics: LayoutContentMetrics {
    LayoutContentMetrics(intrinsicSize: LayoutSize(width: 44, height: 44))
}

// Constraint-dependent (e.g. text wrapping)
override func layoutContentMetrics(for constraint: SizeConstraint) -> LayoutContentMetrics {
    let measured = textMeasurer.measure(text, width: constraint.width.value)
    return LayoutContentMetrics(intrinsicSize: measured)
}
```

These are called on MainActor and their results are **copied** into an immutable
`LayoutInputSnapshot` before being handed to the off-MainActor layout solver.

## Lifecycle Hooks on Node

| Method | When called |
|---|---|
| `connect() -> Bool` | Node enters connected state; idempotent |
| `handleCapture(_ event:)` | Capture phase — before target |
| `handleEvent(_ event:)` | At-target phase |
| `handleBubble(_ event:)` | Bubble phase — after target |
| `enteredViewport(_:)` | Node scrolls into a committed viewport |
| `leftViewport(_:)` | Node scrolls out of viewport |
| `didApplyLayoutResult(_:)` | After frame is placed |
| `dispose()` | Terminal; cancels children recursively |

## Binding Flux on a Node

```swift
// Inside Controller.connect(_:)
connections.scope.effect(id: "loadData") {
    for await item in dataService.stream {
        await node.update(item)
    }
}

// Inside Node.connect() for node-owned subscriptions
bind(id: "theme", themeStore.currentTheme) { [weak self] theme in
    self?.appearance.backgroundColor = theme.surface
}
```

`bind(id:_:update:)` stores the subscription in `SubscriptionBag` and registers a  
cancellation handle in `lifecycle.connectionScope` — replacement by ID cancels the prior binding.
