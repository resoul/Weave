# Render & Display Pipeline

## Architecture

```
MainActor (Node tree)                     WeaveAdapters (off-MainActor workers)
──────────────────────                    ────────────────────────────────────
RenderCoordinator
  │
  ├── Node.setNeedsDisplay()
  │     └── onInvalidate callback
  │           └── schedule display pass
  │
  ├── build DisplayRequest (Sendable)
  │     nodeID, generation, bounds, scale, priority
  │
  └── submit to DisplayPipeline ──────────────────────────►  DisplayWorker
                                                              ├── CoreTextRasterRenderer
                                                              ├── ImageRasterRenderer
                                                              ├── VisualStyleRenderer
                                                              └── VideoPipeline
                                                                    │
                                 ◄────────────────────────────────┘
                                      DisplayArtifact (Sendable)
                                      nodeID, generation, payload
                                              │
                                   RenderCoordinator.commit(artifact)
                                     └── generation check → stale drop
                                     └── CALayer contents = artifact.payload
```

## `DisplayRequest`

Immutable parameters captured on `@MainActor`:

```swift
struct DisplayRequest: Sendable, Hashable {
    let nodeID: ElementID
    let generation: UInt64          // stale-guard token
    let geometryGeneration: UInt64  // layout revision at capture time
    let contentRevision: UInt64     // node.displayRevision
    let bounds: LayoutFrame         // frame in logical points
    let scale: Double               // screen scale factor
    let priority: DisplayPriority   // .background / .nearVisible / .visible
}
```

## `DisplayPriority`

```swift
public enum DisplayPriority: Int, Comparable, CaseIterable {
    case background = 0    // prefetch, off-screen
    case nearVisible = 1   // about to enter viewport
    case visible = 2       // currently on screen
}
```

Workers process requests in priority order. On memory pressure, `.background` work  
is cancelled first (controlled by `EnvironmentResourceConfiguration`).

## `DisplayPayload` — Worker Output

```swift
public enum DisplayPayload: Sendable {
    case image(CGImage)                                       // rasterized content
    case color(ThemeColor)                                    // solid fill fast path
    case bytes(data: Data, width: Int, height: Int, bytesPerRow: Int)  // raw pixels
    case empty                                                // transparent / skip
}
```

## Worker Types

### `CoreTextRasterRenderer`
Renders `TextNode` content off-MainActor using `CoreText` and `CoreGraphics`.  
Receives an immutable `TextRenderRequest` (text, attributes, bounds, scale) and returns `CGImage`.

### `ImageRasterRenderer`
Decodes `ImageNode` content: network fetch → disk cache → decode → scale.  
Respects `EnvironmentResourceConfiguration.decodeConcurrency` and `memoryBudgetBytes`.

### `ImageMemoryCache`
LRU cache shared across all `ImageRasterRenderer` instances for the same window.  
Evicted on memory pressure or when the environment budget decreases.

### `VisualStyleRenderer`
Renders `VisualStyle` (background color, gradient, border, shadow, corner radius)  
as a `CGImage` or `DisplayPayload.color` on the fast path.

### `VideoPipeline`
Manages `AVPlayer` instances for `VideoNode`. Player lifecycle is adapter-owned;  
`VideoNode` provides an immutable `VideoRenderRequest` snapshot.

## `RenderCoordinator`

`@MainActor` owner of the Node–CALayer bridge:

```swift
@MainActor
final class RenderCoordinator {
    func mount(node: Node, in layer: CALayer)
    func unmount(node: Node)
    func commit(artifact: DisplayArtifact)
    func applyLayoutResult(_ result: LayoutResult)
}
```

- `mount` — installs `onInvalidate` callback, creates CALayer tree to match node tree
- `unmount` — removes callbacks and layer references
- `commit` — generation check; if valid, sets `CALayer.contents`
- `applyLayoutResult` — maps `LayoutFrame` → `CALayer.frame` (with pixel-rounding)

## Stale Artifact Rejection

```swift
// In commit(artifact:):
guard artifact.generation == currentDisplayGeneration else { return }  // drop stale
```

If a node's content changes while a worker is rendering the old content, the old  
`DisplayArtifact` arrives with a stale `generation` and is silently dropped.  
The new render request was already submitted.

## `VisualStyle` — Paint-Only Fast Path

Changes to `Node.appearance` (background fill, corner radius, border, shadow — see
`VisualStyle`/`Fill` in `Sources/WeaveUI/VisualStyle.swift`) go through `applyVisualStyle(_:to:theme:)`
in `Sources/WeaveAdapters/VisualStyleRenderer.swift`, called from each platform's
`update(node:...)` in `UIKitLayerRenderer.swift`/`AppKitLayerRenderer.swift`. **`VisualStyle` has
no `opacity` field** — opacity, `zIndex`, `overflow` and `transform` live in a *different* struct,
`LayoutVisualProperties`, under `node.style.visual` (part of the layout style, not the paint
style) — see the next section.

Only changes requiring rasterization (complex gradients, shadows) go through the display pipeline.

## `style.visual` (`LayoutVisualProperties`) — Verified Wiring Status (this session)

`LayoutStyle.visual: LayoutVisualProperties` carries `zIndex`, `overflow`, `opacity`, `transform`.
Before this session **only `HitTester` and `FlexSolver`-adjacent placement code read these
fields** — nothing in either platform renderer painted their effect, so setting them was a
silent no-op on screen even though hit-testing behaved as if they worked. Now wired in both
`UIKitLayerRenderer.update(...)` and `AppKitLayerRenderer.update(...)`:

```swift
layer.masksToBounds = node.style.visual.overflow == .hidden   // fixed
layer.opacity = Float(node.style.visual.opacity)              // fixed
layer.zPosition = CGFloat(node.style.visual.zIndex)           // fixed
layer.setAffineTransform(node.style.visual.transform.affineTransform)  // fixed
```

`LayoutTransform.affineTransform` (translate → rotate → scale composition) lives in
`Sources/WeaveAdapters/LayoutTransformNative.swift`. `zPosition` was chosen over reordering
`addSublayer` calls specifically because sibling paint order previously followed *insertion*
order only, disagreeing with `HitTester`'s `zIndex`-based hit priority — `zPosition` is the
native CALayer property that actually reorders paint among siblings independent of insertion
order, so the two now agree again.

`ScrollNode` always forces `masksToBounds = true` regardless of its own `overflow` value — it
visually clips unconditionally, which is why `HitTester` treats any `ScrollNode` as an implicit
clip boundary too (see `09-events.md`).

## Layout-Commit Animation (`Transaction.animate`) — Verified (this session)

Every layout commit (`applyCommitted` in either `*LayerRenderer.swift`) used to wrap all layer
property changes in `CATransaction.setDisableActions(true)` unconditionally — so **any** layout
change (a resize from `setNeedsLayout`, a scroll-driven relayout, anything) applied instantly,
by design, to avoid unwanted implicit-animation flicker. The public `Transaction.animate(_:_:)`
API (`Sources/WeaveUI/Animation.swift`) existed but was a no-op stub — it resolved reduce-motion
and then just called `changes()` synchronously, never touching any transaction.

Now real, end to end:
- `AnimationContext` (`Animation.swift`, `@MainActor public enum`) holds the ambient animation
  `Transaction.animate` pushes for the duration of its `changes` closure.
- `Node.setNeedsLayout()` bubbles to the root and calls `onInvalidate` **synchronously**, which
  calls `RenderCoordinator.invalidate(root:bounds:scale:)` — still inside `changes()` — which
  captures `AnimationContext.current` into the new `HostRenderRequest.animation` field. The
  actual native commit happens *later*, asynchronously, once the layout worker returns; the
  animation intent survives because it travels as data on the request, not as a live ambient
  read at commit time.
- If a request needs one retry due to a staleness mismatch (`RenderCoordinator.handleLayoutResult`),
  the retry now explicitly re-wraps itself in `AnimationContext.withAnimation(request.animation)`
  — the ambient value would otherwise have already been restored to its previous state by
  `Transaction.animate`'s `defer`, silently dropping the animation on any request needing a retry.
- `*LayerRenderer.applyCommitted(result:on:scale:animation:)` uses the request's animation to set
  `CATransaction.setAnimationDuration`/`setAnimationTimingFunction` instead of disabling actions,
  when `animation.duration > .zero`. `AnimationCurve → CAMediaTimingFunction` mapping is in
  `Sources/WeaveAdapters/AnimationTiming.swift` (`.spring` has no fixed-timing-function
  equivalent and is approximated as `.easeOut` — a real spring needs `CASpringAnimation`, a
  different mechanism this does not implement).

**Raster content is deliberately exempted from the animated transaction.** `TextNode`/
`ImageNode`/`VideoNode` layers get their `bounds`/`position`/`transform` set inside a *nested*
`CATransaction` with actions force-disabled, even when the outer commit is animated. Reasoning:
these layers hold a bitmap (`layer.contents`), not vector geometry — animating `bounds` just
stretches the *existing* bitmap to intermediate sizes (CALayer's default
`contentsGravity == .resize`) until a new bitmap lands later via the separate async
`applyArtifact` display pipeline, which reads as smeared/stretched glyphs snapping correct at
the end. Additionally, `update(...)` now clears `layer.contents = nil` the instant a raster
node's *own* size actually changes (comparing against the previous cached `baseFrames[id]`) —
without this, the stale bitmap still stretches to fill the already-resized bounds for the gap
before the new one arrives, animated transaction or not. The visible tradeoff is a brief blank
gap on resize instead of stretched content, which reads far better.

**Practical implication for a growing/shrinking container with a text/image child**: the
container's own box can animate smoothly, but its raster children snap to final geometry
instantly. If the child's final size is reached before the container's animated box catches up,
the child will visibly overflow the container mid-animation unless the container also sets
`style.visual.overflow = .hidden` to clip children to its *current* (not final) animated bounds.

## `WindowHost`

`WindowHost` is the minimal adapter contract between `Window` and the platform:

```swift
protocol WindowHost: AnyObject {
    func mount(_ window: Window)
    func updateFrame(_ frame: CGRect)
}
```

On iOS: wraps a `UIWindow` + `UIViewController`.  
On macOS: wraps an `NSWindow` + `NSViewController`.  
The host installs `RenderCoordinator` and handles `Window.activation` events.

## Resource Policy

`EnvironmentResourceConfiguration` (propagated via environment) controls:

| Property | Effect |
|---|---|
| `memoryBudgetBytes` | `ImageMemoryCache` eviction threshold |
| `decodeConcurrency` | Max parallel `ImageRasterRenderer` tasks |
| `prefetchEnabled` | Whether `.background` priority requests are submitted |

When a `WindowScene` closes, its image decode tasks are cancelled.  
Tasks owned by other scenes are not affected (no cross-scene resource ownership).
