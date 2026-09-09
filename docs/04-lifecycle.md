# Lifecycle

## State Machine

Every `Node` and `Controller` owns a `LifecycleMachine` internally.  
The machine enforces legal transitions and issues a `ConnectionScope` at `.connect`.

```
  created
     │ .compose
  composed
     │ .connect  ──────── ConnectionScope created
  connected
     │ .mount
  mounted ◄────────────────────────────┐
     │ .activate          .unmount     │ (.reconnect resets scope)
  active ──────── .deactivate ──► inactive
     │                                 │
     └────────── .unmount ─────────────┘
                    │
                unmounted
                    │  (or from any state)
                 .dispose ──► disposed  (terminal)
```

### `LifecycleState` values

| State | Description |
|---|---|
| `.created` | Object constructed, no composition |
| `.composed` | `compose()` called, no effects |
| `.connected` | `ConnectionScope` created, bindings registered |
| `.mounted` | Embedded in a live container |
| `.active` | Visible to user, all effects running |
| `.inactive` | Hidden but mounted; `cancelOnDeactivate` effects suspended |
| `.unmounted` | Removed from container; scope cancelled |
| `.disposed` | Terminal; all owned resources released |

### Invalid transitions
`LifecycleMachine.transition(_:)` returns `false` for any event that does not match  
the current state — the caller should not retry. Double-dispose is a no-op (`false`).

## `ConnectionScope`

Created at `.connect`, cancelled at `.unmount` or `.dispose`.  
Owns two registries keyed by `AnyHashable`:

### Bindings
```swift
scope.bind(id: "subscription") {
    subscription.cancel()
}
```
Replacing the same ID cancels the prior handle synchronously.

### Effects (keyed async tasks)
```swift
scope.effect(
    id: "loadFeed",
    cancelOnDeactivate: true          // default
) {
    for await item in feedService.stream { … }
}
```
- `cancelOnDeactivate: true` — task cancelled on `.deactivate`; restarted on next `.activate`
- `cancelOnDeactivate: false` — task survives deactivation (e.g. upload, save)
- Replacing the same ID cancels the prior task

### `cancelEffectsOnDeactivate()`
Called automatically by `LifecycleMachine` on `.deactivate`.  
Cancels only effects flagged `cancelOnDeactivate: true`.  
Bindings are preserved.

### `cancelAll()`
Terminal. Called on `.unmount` and `.dispose`.  
All bindings and effects cancelled. Later registrations are cancelled immediately.

## `EffectFailure`

Thrown errors from effect operations are caught by the scope and delivered as `EffectFailure`  
to the optional `onFailure` callback **on MainActor**, avoiding unhandled task failures:

```swift
scope.effect(id: "save", onFailure: { failure in
    self.showErrorBanner(failure.message)
}) {
    try await storage.save(document)
}
```

`CancellationError` is silently swallowed — it is not an application error.

## Controller Lifecycle Integration

`Controller<N,A,R>` drives its own `LifecycleMachine` and delegates to the node's machine:

```
Controller.connect()
  └── compose()                          // describe structure
      lifecycle.transition(.compose)
      node.connect()                     // node gets its scope
      lifecycle.transition(.connect)
      connectionScope = lifecycle.connectionScope
      connect(ControllerConnections(…))  // register bindings/effects
```

```
Controller.activate()
  └── lifecycle.transition(.mount)       // if not already mounted
      lifecycle.transition(.activate)
      activated(ActivationContext())     // user hook
```

```
Controller.dispose()
  └── isDisposed = true
      lifecycle.transition(.dispose)    // scope cancelled
      actions.finish()                  // action pipe closed
      router.finish()                   // route pipe closed
      node.dispose()                    // recursive child disposal
      disposed()                        // user hook
```

## Node `bind` vs Scope `bind`

| API | Owner | Cancellation |
|---|---|---|
| `node.bind(id:_:update:)` | Node's `SubscriptionBag` + connectionScope | Cancelled when node disposes or ID replaced |
| `scope.bind(id:cancel:)` | ConnectionScope directly | Cancelled when scope terminates or ID replaced |

Prefer `scope.bind` inside `Controller.connect(_:)`.  
Prefer `node.bind` when the subscription is logically part of the node itself.
