# Layout Pipeline

> **Naming drift warning**: the prose below predates several renames and does not match the
> current Swift API 1:1. Verified corrections, current as of this session:
> - `LayoutDimension` does not exist. The real type is `SizeValue`: `.points(Double)`,
>   `.fraction(Double)`, `.auto` (`Sources/WeaveUI/Layout.swift`).
> - `style.direction` is `style.flexDirection` (`.row`/`.column`/`.rowReverse`/`.columnReverse`).
> - `LayoutDirection` cases are `.leftToRight`/`.rightToLeft`, not `.leadingToTrailing`/
>   `.trailingToLeading`.
> - `FlexSolver.solve(_:)` does not exist. The real entry point is
>   `FlexSolver.measureContainer(input:constraint:)` (bottom-up intrinsic measurement) plus a
>   separate top-down placement pass in `LayoutResult.swift` (`layoutContainer`) that resolves
>   `positionType == .absolute` children against the parent's `offsets`.
> - Mutating `.style { $0.foo = ... }` goes through the `StyleBuildable`/`Draft` pattern in
>   `StyleBuilders.swift`, not a raw `didSet`-triggering property.
> When in doubt, read the source file named in a correction before trusting the prose beneath it.

## Overview

```
MainActor (Node tree)                   Worker (off-MainActor)
─────────────────────                   ──────────────────────
Node.makeLayoutInputSnapshot()
  └── LayoutInputSnapshot (Sendable)
        │
        └──────────────────────────────► FlexSolver.solve(snapshot)
                                              └── LayoutResult (Sendable)
                                                    │
◄─────────────────────────────────────────────────┘
Node.applyRecursively(result)
  └── each Node.apply(result)
        └── calculatedFrame = placement.frame
  └── Node.didApplyLayoutResult(result)
```

No platform objects are involved. Layout runs on immutable `Sendable` snapshots  
and produces an immutable `LayoutResult`. The apply step is strictly MainActor.

## `LayoutStyle`

Flex-based layout descriptor owned by each `Node`. Directional by default:

```swift
var style = LayoutStyle()
style.direction = .column
style.alignItems = .center
style.width = .fill
style.height = .fixed(200)
style.padding = DirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
```

Modifying `style` calls `setNeedsLayout()` automatically via `didSet`.

### `LayoutDimension`

```swift
enum LayoutDimension {
    case auto          // intrinsic / flex default
    case fixed(Double) // exact logical points
    case fill          // expand to fill container
    case percent(Double, of: PercentBase) // relative to parent
}
```

### `SizeConstraint`

Passed to `layoutContentMetrics(for:)` to enable constraint-sensitive measurement:

```swift
enum DimensionConstraint {
    case unspecified       // no parent constraint
    case atMost(Double)    // max width/height
    case exact(Double)     // fill
}
```

## `LayoutInputSnapshot` — Sendable Capture

`Node.makeLayoutInputSnapshot(constraint:)` captures the live tree into an immutable value:

```swift
struct LayoutInputSnapshot: Sendable, Hashable {
    let identity: ElementID
    let style: LayoutStyle
    let content: LayoutContentMetrics         // intrinsic size, baseline
    let children: [LayoutInputSnapshot]       // recursive
    let direction: LayoutDirection
    let environmentRevision: UInt64           // stale-result guard
    let contentRevision: UInt64               // max(layoutRevision, displayRevision)
}
```

Safe-area insets are baked into `style.padding` for root and safe-area boundary nodes  
**before** the snapshot is returned — the worker never touches `EnvironmentScope`.

## `FlexSolver`

`FlexSolver.solve(_:)` is a pure function operating on `LayoutInputSnapshot`:

```swift
// Called off-MainActor
let result: LayoutResult = FlexSolver.solve(snapshot)
```

Implements a directional flex algorithm:
- `direction: .row / .column`
- `justifyContent`, `alignItems`, `alignSelf`, `flexGrow`, `flexShrink`
- `wrap: .wrap / .noWrap`
- `gap`, `spacing`

> **Fixed bug (this session)**: `intrinsicSize(fallback:constraint:explicit:)` used to clamp an
> `.auto`-sized child to its parent's `.atMost` constraint even when the child's own
> `flexShrink == 0` — i.e. an explicitly non-shrinking auto-sized item could never actually
> report a size larger than its parent, so it could never overflow. This broke every
> hand-built scrollable container (a `ScrollNode` whose single content child has `flexShrink =
> 0` on purpose, so it can be taller than the viewport): the content silently got clamped to
> exactly the viewport height, `maxOffset` came out to `0`, and the scroll simply did nothing.
> Fixed by treating `.atMost` the same as `.unspecified` for the auto-size fallback — clamping
> now happens only in the grow/shrink resolution pass in `resolveLines`, where it belongs.
> **Practical rule**: any node meant to overflow its parent (typically the content child of a
> `ScrollNode`/`ScrollContentView`) must set `flexShrink = 0`, or the flex algorithm will
> shrink it to fit and there will be nothing to scroll.
- `padding`, `margin`
- Directional coordinates (`leading/trailing`) resolved to physical `x/y` per `LayoutDirection`

## `LayoutResult`

Immutable, Sendable. Maps `ElementID → LayoutPlacement`:

```swift
struct LayoutResult: Sendable {
    func placement(for id: ElementID) -> LayoutPlacement?
}

struct LayoutPlacement: Sendable {
    let frame: LayoutFrame           // x, y, width, height in logical points
    let baseline: Double?
}
```

`Node.apply(_:)` reads its own placement by `id`:

```swift
public func apply(_ result: LayoutResult) {
    guard let placement = result.placement(for: id) else { return }
    calculatedFrame = placement.frame
}
```

If a node's `id` is absent from the result, it is a no-op — late or stale results are safe.

## Stale Result Rejection

The host (adapter or `RenderCoordinator`) owns the current `layoutGeneration`.  
Before calling `applyRecursively`, it compares the result's generation to the current:

```swift
// Pseudo-code in host:
let generation = currentLayoutGeneration
Task.detached {
    let result = FlexSolver.solve(snapshot)
    await MainActor.run {
        guard self.currentLayoutGeneration == generation else { return }  // stale → drop
        self.rootNode.applyRecursively(result)
    }
}
```

## Invalidation Chain

```
node.style.width = .fill
  └── Node.setNeedsLayout()
        └── layoutRevision += 1
        └── parent.setNeedsLayout()  (recursive up)
              └── root.onInvalidate?(self)   ← host schedules layout pass
```

`onInvalidate` is set by the platform adapter when a node is mounted.

## `LayoutContentMetrics`

```swift
struct LayoutContentMetrics: Sendable, Hashable {
    var intrinsicSize: LayoutSize?    // nil = flex-determined
    var baseline: Double?             // for text alignment
    var minimumSize: LayoutSize?      // lower bound even with flex shrink
}
```

## `LayoutEngine` — High-Level Coordinator

`LayoutEngine` wraps the snapshot → solve → apply cycle with generation tracking.  
Used by `RenderCoordinator` to schedule layout passes without duplicating the stale-guard logic.

## Scrolling arbitrary (non-item) content — `ScrollContentView` (added this session)

`ScrollNode` (`Sources/WeaveUI/Scroll.swift`) is a low-level primitive: it owns offset,
clamping, momentum and edge-pull state, and physically clips/shifts its `CALayer` (`bounds.origin`
+ `masksToBounds`) — but it has **no idea how big its own content is** until something calls
`updateViewport(viewportSize:contentSize:)`. `TableView`/`GridView` (`VirtualizedView` in
`Collections.swift`) compute `contentSize` analytically from item count × row length and call
this themselves. For a hand-composed, non-item layout (a settings screen, a form, any one-off
flex-wrap block), nothing did this automatically — a bare `ScrollNode` around custom content
never scrolled (see the `flexShrink` bug above for why the content also has to opt out of
shrinking).

`ScrollContentView` (`Sources/WeaveUI/ScrollContentView.swift`) is the fix: it wraps a
caller-built `content` node, forces `content.style.flexShrink = 0`, and on every
`didApplyLayoutResult` recomputes `updateViewport` from the content's actual `calculatedFrame`.
Prefer it over a bare `ScrollNode` for anything that isn't a `TableView`/`GridView`.

Edge-pull (`startEdgePull`/`endEdgePull: EdgePullConfiguration?`, elastic/action behavior) used
to live only on `VirtualizedView`, duplicated nowhere else. It has been moved onto `ScrollNode`
itself (`EdgePullContainer` conformance + state machine), so `ScrollContentView` — and any
future `ScrollNode` subclass — gets it for free instead of needing its own copy.
`ScrollContentView`'s initializer exposes `startEdgePull`/`endEdgePull` directly.

## Coordinate System

All coordinates are **logical points** (density-independent).  
`LayoutDirection` (`.leadingToTrailing` / `.trailingToLeading`) controls whether  
`leading` maps to left or right. Physical `x/y` are only used by the adapter  
when translating frames to `CALayer.frame`.
