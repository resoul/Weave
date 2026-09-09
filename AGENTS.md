# Weave agent rules

## Orientation — read this before scanning the tree

Weave lives at `newUI/Weave`, one of several sibling projects under `newUI/` that this repo is
developed alongside:
- `newUI/flux` — the reactive stream library Weave depends on (`Flux`, `ActionPipe`, `sinkOnMain`).
  Pulled as a remote SPM dependency (`Package.swift`), not a local path — it also exists as a
  sibling checkout for reference/co-development.
- `newUI/Texture` — a reference implementation, checked out for comparing approaches/performance,
  not a Weave dependency.
- `newUI/manual` — a throwaway Xcode app (`manual/manual/ManualApp.swift`) for manual on-device
  testing of a single scenario at a time via a local Swift package reference to `../Weave`. It
  gets rewritten per test, not accumulated — don't expect old scenarios to still be there.

Inside `Weave/`:
- `Sources/WeaveUI` — platform-neutral core: `Node`, layout (`Layout.swift`, `FlexSolver.swift`,
  `LayoutResult.swift`), events/hit-testing (`Events.swift`), controls (`Controls.swift`),
  scrolling (`Scroll.swift`, `ScrollContentView.swift`), collections (`Collections.swift` —
  `TableView`/`GridView`), animation (`Animation.swift`).
- `Sources/WeaveAdapters` — platform-neutral render-coordination shared by both platform
  adapters: `RenderCoordinator.swift` (async layout scheduling, `HostRenderRequest`),
  `VisualStyleRenderer.swift`, `AnimationTiming.swift`, `LayoutTransformNative.swift`.
- `Sources/UIKitAdapter` / `Sources/AppKitAdapter` — the actual CALayer bridge
  (`*LayerRenderer.swift`: `update()`, `applyCommitted`, `applyArtifact`) and native touch/mouse
  input (`*Adapter.swift`: `attach()`'s `inputHandler` closure). **These two are not
  symmetric** — verify a fix landed in both before assuming parity; several bugs fixed this
  session (tap-to-`ControlNode` dispatch in particular) were UIKit-only.
- `docs/` — a documentation index (`docs/README.md`) written early in the project and, in
  several places, describing an *aspirational* API that has since drifted from what's actually
  implemented (renamed types, methods that don't exist). Sections marked "Naming drift" or
  "Verified (this session)" inside `08-layout.md`, `09-events.md`, `10-render.md` are grounded
  in direct source reading and are more trustworthy than the surrounding prose — extend that
  pattern (verify against source, mark clearly) rather than trusting the docs at face value.
- `weave-public-api.json` (Weave package root, moved here this session from `API/` for
  discoverability — `API/` still holds ADRs) — the public-symbol baseline `Scripts/check_api.py`
  diffs against.

A recurring pattern found by testing on a real device this session, worth checking for
elsewhere: **the platform-neutral layout/hit-test model in `WeaveUI` is often ahead of what the
two adapters actually paint or wire to real input** — `style.visual.overflow/opacity/zIndex/
transform` were read by `HitTester`/`FlexSolver` but not painted by either renderer; taps were
never hit-tested against real touches in UIKit at all; `Transaction.animate` was a no-op stub.
When something "should" work per the `WeaveUI` model but doesn't visibly happen, suspect the
adapter layer first, not the model.

- Read `README.md`, `policy.json`, the current task card and its architecture sources before editing.
- Build public product `Weave`; public type names stay short (`Node`, `Window`, `Controller`,
  `Application`). Do not introduce a brand prefix or namespace.
- Use Swift 6 language mode and complete strict concurrency. Deployment minimums are macOS 14,
  iOS/iPadOS 16 and tvOS 16; macOS supports arm64 and x86_64.
- Keep UIKit/AppKit/Cocoa/SwiftUI/Metal and Cocoa lifecycle outside Core/shared sources. Platform code
  belongs only under the prefixes listed in `policy.json`.
- UI tree and native objects are `@MainActor`. Workers receive immutable `Sendable` snapshots.
  Do not add `@unchecked Sendable`, `nonisolated(unsafe)` or `@preconcurrency` as blanket fixes.
- Every Task and Flux subscription needs an owner, cancellation point and deterministic test.
- Public declarations need English documentation for semantics, ownership, actor isolation,
  cancellation and errors. Public API changes update `weave-public-api.json` through the review flow.
- Add a narrow exception to `policy.json` only with an exact path, rule IDs and concrete reason.
- Run `python3 Scripts/check_all.py` for normal work and `python3 Scripts/check_all.py --matrix` before
  handoff when Xcode destinations are relevant. Never claim a simulator build as a physical device run.
