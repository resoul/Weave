# Events & Gestures

> **Naming drift + verified fixes (this session)**:
> - `handleCapture`/`handleEvent`/`handleBubble` are `open` methods on `Node` itself
>   (`Sources/WeaveUI/Node.swift`), not on a separate `InteractiveNode` base class. The real
>   `InteractiveNode` is an unrelated protocol (`Sources/WeaveUI/Controls.swift`) for exposing a
>   typed `ActionPipe<Interaction>` (`var events: ActionPipe<Interaction>`) — used by `ButtonNode`
>   and `ControlNode<Interaction>`, nothing to do with capture/target/bubble.
> - `HitTester.hitTest` (`Sources/WeaveUI/Events.swift`) did **not** account for a `ScrollNode`
>   ancestor's current scroll offset until this session — any tap inside content that had been
>   scrolled away from the top hit-tested against the *pre-scroll* layout position and missed.
>   Fixed: when descending into a `ScrollNode`'s children, the point is now offset by
>   `scrollNode.state.offset`, and the clip rect is intersected with the scroll's own frame (it
>   always visually clips via `masksToBounds` regardless of `style.visual.overflow`).
> - `UIKitAdapter`'s real touch pipeline (`touchesBegan/Moved/Ended` → the `inputHandler` closure
>   in `attach()`) drove scrolling and swipe-reveal only — it never hit-tested a tap against the
>   node tree or called `ControlNode.handle(_:)` at all, so **no `ButtonNode` anywhere responded
>   to a real touch on a device**, regardless of what unit tests calling `.handle(.pointerDown)`
>   directly might suggest. Fixed by adding `ControlInputTarget` (a type-erased
>   `@MainActor protocol { func handle(_ input: ControlInput) -> Bool }`, conformed by
>   `ControlNode<Interaction>`) and a `findControlTarget(in:at:)` hit-test walk in
>   `UIKitAdapter.swift`, dispatching `.pointerDown` on touch-down and `.pointerUp(inside:)` on
>   touch-up (`inside` re-hit-tests at the release point and compares identity). **AppKit has no
>   equivalent wiring yet** — this was fixed for UIKit only; verify before assuming macOS/Catalyst
>   button taps work.
> - `HitTester` already respected `style.visual.zIndex` (sorts children by it for hit priority)
>   and `style.visual.transform` (`inverseApplying` on the touch point) *before this session* —
>   but neither was painted by either renderer until the fixes noted in `10-render.md`. Before
>   that fix, a node with a higher `zIndex` could be hit-tested as "on top" while rendering
>   visually underneath a sibling.

## Event Dispatch Model

Weave uses a **three-phase synchronous dispatch** identical to DOM events:

```
capture phase  → root → … → parent → target
at-target      →                     target
bubble phase   → target → parent → … → root
```

All phases run synchronously on `@MainActor`. Phases are mutable during dispatch —  
calling `event.stopPropagation()` prevents later callbacks in the same pass.

## `Event`

```swift
// Mutable during synchronous dispatch; immutable snapshot is published to Flux
public final class Event {
    public let type: EventType
    public let payload: EventPayload
    public let targetID: ElementID
    public private(set) var phase: EventPhase
    public private(set) var isPropagationStopped: Bool
    public private(set) var isDefaultPrevented: Bool

    public func stopPropagation()
    public func preventDefault()
}
```

`stopPropagation()` — stops future callbacks in the current and remaining phases.  
`preventDefault()` — tells the framework to suppress the default platform action (e.g. scroll).  
Neither is an error to call multiple times.

## `EventType`

```swift
public enum EventType: Sendable, Hashable {
    case pointerDown, pointerUp, pointerMove, pointerCancel
    case pressSelect                  // Apple TV remote center button, keyboard Space/Return
    case keyDown, keyUp
    case scroll
    case focusIn, focusOut
    case custom(String)
}
```

## `EventPayload`

```swift
public enum EventPayload: Sendable, Hashable {
    case pointer(PointerData)         // point, pointerID, windowID
    case key(KeyData)                 // keyCode, characters
    case scroll(ScrollData)           // delta, velocity
    case none
}
```

## Handling Events in a Node

```swift
// Override the relevant phase(s)
open class InteractiveNode: Node {
    override func handleCapture(_ event: Event) {
        // Runs before target and bubble phases
        if event.type == .pointerDown {
            highlightState = .pressed
        }
    }

    override func handleEvent(_ event: Event) {
        // Runs at-target
        if event.type == .pointerUp {
            dispatch(.tapped)
            event.stopPropagation()   // don't bubble taps to parent scroll
        }
    }

    override func handleBubble(_ event: Event) {
        // Runs during bubble phase if not stopped
    }
}
```

**Rule**: `stopPropagation()` and `preventDefault()` are valid **only** inside a synchronous  
dispatch callback. They have no meaning outside `handle*` methods.

## Pointer Capture

Pointer capture belongs to a session (`pointerID`) + `ElementID` + `Window`.  
Platform adapters assign `pointerID` from the native touch/cursor session.

Capture is cancelled automatically when:
- The node is removed from the tree
- The node is disposed or deactivated
- A modal covers the captured node
- Pointer session ends (`pointerCancel` or `pointerUp`)

## Gesture State Machines

`Gestures.swift` defines self-contained gesture recognizers as `@MainActor` classes  
that observe pointer events and emit typed outputs:

| Gesture | Output |
|---|---|
| `TapGesture` | `.recognized(location:)` |
| `LongPressGesture` | `.began(location:)`, `.cancelled` |
| `PanGesture` | `.began`, `.changed(translation:velocity:)`, `.ended`, `.cancelled` |
| `PinchGesture` | `.changed(scale:velocity:)`, `.ended`, `.cancelled` |

Attach a gesture to a node:
```swift
let tap = TapGesture()
tap.recognized.sinkOnMain { [weak self] location in
    self?.handleTap(at: location)
}.store(in: subscriptions)
node.addGestureRecognizer(tap)
```

Gesture recognizers participate in arbitration — only one recognizer wins a session.  
Losing arbitration sends `.cancelled` immediately.

## Modal Scope & Input

When a modal controller is active, keyboard/remote traversal and pointer dispatch  
to background nodes are suppressed. The modal scope is managed by `WindowScene` /  
the platform adapter — nodes in the background receive no events and are excluded  
from the `FocusTree` and accessibility exposure.

## Keyboard & Remote (tvOS)

`pressSelect` fires for:
- tvOS: remote center button
- macOS/iOS keyboard: `Space` or `Return` when a node is focused

`keyDown` / `keyUp` carry `KeyData.keyCode` and optionally `characters`.

Arrow key navigation on tvOS triggers focus traversal via `FocusTree`, not direct node events.

## Focus Events

`focusIn` / `focusOut` are dispatched by the `FocusTree` adapter when focus moves.  
`Node.focusEligibility` and `Node.focusable` control whether a node participates:

```swift
// Opt in explicitly
override var focusEligibility: FocusEligibility { .eligible }

// Provide directional metadata
override var focusable: FocusableSpec? {
    FocusableSpec(preferredFocusEnvironments: [])
}
```

## Scroll Events

`ScrollNode` emits `scroll` events during content offset changes.  
`Event.preventDefault()` inside a capture handler can block the scroll from propagating  
to a parent scrollable container.

Viewport enter/exit callbacks (`enteredViewport` / `leftViewport`) are separate from  
scroll events — they fire when the committed scroll position places the node's frame  
inside or outside the visible window.
