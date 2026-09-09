# Weave

A cross-platform UI framework being built for iOS, macOS and tvOS.

```swift
import Weave
```

The package currently establishes the module, dependency resolution and build verification.
`Node`, `Window`, `Controller` and the native runtime are **not implemented yet**. Their names will
remain short; Weave is the package/module name, not a prefix for public types.

## Requirements

- Swift tools 6.0+, Swift 6 language mode (complete concurrency checking).
- macOS 14+, iOS/iPadOS 16+, tvOS 16+.
- Published Flux **1.2.0**, pinned exactly; `Package.resolved` records its Git revision.
- Verification toolchain: Xcode 26.6 (17F113), Swift 6.3.3, SDKs 26.5 and bundled swift-format 6.3.0.
  Exact verification pins live in `toolchain.json`; these are not a higher consumer deployment minimum.

The bootstrap has one library target, `Weave`, plus `WeaveBootstrapTests`. Flux is directly linked
at this stage to prove the remote dependency works. The final graph adds WeaveCore, platform adapters
and independent services in their implementation tasks. There are no empty feature targets,
probe types promoted to public API, unsafe manifest flags or test/tooling production dependencies.

## Build and verify

Run from this repository root:

```sh
xcrun --sdk macosx swift package resolve
xcrun --sdk macosx swift build --target Weave -Xswiftc -warnings-as-errors
xcrun --sdk macosx swift test -Xswiftc -warnings-as-errors
python3 Scripts/verify_bootstrap.py
python3 Scripts/verify_bootstrap.py --matrix
python3 Scripts/check_all.py
python3 Scripts/check_all.py --matrix
```

The Python verifier uses only the standard library, checks pinned tools, formatting, deployment
versions, resolved Flux revision, a narrow bootstrap boundary scan, tests and the separate consumer.
Logs and actual commands are saved to `.build/bootstrap-validation`. The matrix builds unsigned
code for macOS (arm64/x86_64), iOS device/simulator and tvOS device/simulator. It does not run apps
or claim device verification. First resolution requires access to GitHub.

Equivalent Xcode builds (run from the package root):

```sh
xcodebuild -scheme Weave -destination 'generic/platform=macOS' 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Weave -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Weave -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Weave -destination 'generic/platform=tvOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme Weave -destination 'generic/platform=tvOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Swift 6 mode enables complete concurrency checking without `unsafeFlags` in the manifest;
CLI warnings-as-errors is a local verification policy, not imposed on downstream consumers.
The pinned `.swift-format` currently performs formatting only, with semantic rewrite rules disabled.
`check_all.py` is the canonical quality gate. It adds the repository policy linter, negative guard
fixtures and a reviewed public symbol-graph baseline to the bootstrap checks. The CI workflow runs
the full matrix. Policy/linter version `1.0.0` and its narrow exception list live in `policy.json`.

## Documentation

Package documentation and developer guides are located in [`docs/`](docs/README.md):

| Guide | Description |
|---|---|
| [Architecture Overview](docs/01-architecture.md) | Layer diagram, module boundaries, ownership graph |
| [Application Startup](docs/02-startup.md) | `Application` → `WindowScene` → `Window` bootstrap |
| [Node & Composition](docs/03-nodes.md) | `Node`, `compose()`, `NodeContent`, reconciliation |
| [Lifecycle](docs/04-lifecycle.md) | `LifecycleState` state machine, `ConnectionScope` |
| [Controller & ViewModel](docs/05-controller-viewmodel.md) | `Controller`, `ViewModel`, `ControllerConnections` |
| [Coordinator & Navigation](docs/06-coordinator-navigation.md) | `Coordinator`, `ScreenRegistry`, `NavigationController` |
| [Environment](docs/07-environment.md) | `EnvironmentScope`, `EnvironmentKey`, propagation rules |
| [Layout Pipeline](docs/08-layout.md) | `LayoutStyle`, `FlexSolver`, snapshot → result → apply |
| [Events & Gestures](docs/09-events.md) | Capture/target/bubble, `Event`, gesture state machines |
| [Render & Display](docs/10-render.md) | `DisplayPipeline`, `RenderCoordinator`, CALayer backend |
| [Flux Integration](docs/11-flux.md) | `Flux`, `Pipe`, `Subscription`, concurrency rules |
| [Optional Integrations](docs/12-integrations.md) | `Logging`, `Networking`, `Storage`, `Analytics` |

See [docs/README.md](docs/README.md) for the complete guide index.
