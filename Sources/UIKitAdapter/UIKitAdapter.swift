#if canImport(UIKit)
    import UIKit
    import AVFoundation
    import CoreText
    import ImageIO
    import UniformTypeIdentifiers
    import WeaveUI
    import WeaveAdapters
    #if os(iOS)
        import AudioToolbox
    #endif

    /// Raw UIKit input copied into a platform-neutral value.
    /// Ownership: values own copied coordinates. Isolation: MainActor delivery. Errors: native
    /// details not represented here are omitted. Cancellation: interrupted sessions emit cancelled.
    public enum UIKitInput: Sendable, Hashable {
        case touchDown(point: CGPoint)
        case touchMoved(point: CGPoint)
        case touchUp(point: CGPoint)
        case pressDown
        case pressUp
        case cancelled
    }

    /// UIKit lifecycle and environment changes exposed without UIKit types.
    /// Ownership: values own immutable snapshots. Isolation: MainActor delivery. Errors: none.
    /// Cancellation: input interruption is explicit.
    public enum UIKitPlatformSignal: Sendable, Hashable {
        case becameActive
        case resignedActive
        case safeAreaChanged(PhysicalEdgeInsets)
        case traitsChanged(interfaceStyle: Int, horizontalSizeClass: Int, verticalSizeClass: Int)
        case inputInterrupted
    }

    /// MainActor UIKit host that owns only the native view boundary for a Weave node.
    /// Ownership: the host retains its node weakly and owns its UIView layer. Isolation: MainActor.
    /// Errors: repeated mount/unmount calls are idempotent. Cancellation: unmount releases host state.
    @MainActor
    public final class UIKitHostView: UIView {
        private weak var node: Node?
        public private(set) var coordinator: RenderCoordinator?
        private var ownsCoordinator = false
        private var layerRenderer: UIKitLayerRenderer?
        private var inputHandler: (@MainActor @Sendable (UIKitInput) -> Void)?
        private var signalHandler: (@MainActor @Sendable (UIKitPlatformSignal) -> Void)?
        private var lifecycleObservers: [NSObjectProtocol] = []
        private var swipeContainer: (any SwipeRevealContainer)?
        private var swipeStartPoint: CGPoint?
        private var swipeIsActive = false

        /// Creates an empty native host without starting lifecycle work.
        /// Ownership: the host owns its UIView storage. Isolation: MainActor. Errors: none.
        /// Cancellation: no work starts during initialization.
        public override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
        }

        /// Creates a host from a storyboard archive.
        /// Ownership: UIKit owns the decoded view. Isolation: MainActor. Errors: decoding follows UIKit.
        /// Cancellation: not applicable.
        public required init?(coder: NSCoder) { super.init(coder: coder) }

        #if os(tvOS)
            /// Allows the host to become the tvOS focus target for remote presses.
            /// Ownership: focus remains owned by UIKit's focus engine. Isolation: MainActor.
            /// Errors: unavailable focus is ignored by UIKit. Cancellation: focus changes cancel the current press session.
            public override var canBecomeFocused: Bool { true }
        #endif

        func attach(
            node: Node,
            coordinator: RenderCoordinator? = nil,
            inputHandler: (@MainActor @Sendable (UIKitInput) -> Void)? = nil,
            signalHandler: (@MainActor @Sendable (UIKitPlatformSignal) -> Void)? = nil
        ) {
            self.node = node
            let coord: RenderCoordinator
            if let coordinator {
                coord = coordinator
                ownsCoordinator = false
            } else {
                coord = RenderCoordinator(hostID: node.id)
                ownsCoordinator = true
            }
            self.coordinator = coord
            let renderer = UIKitLayerRenderer(root: node)
            self.layerRenderer = renderer
            coord.mount(root: node)
            coord.onCommitGeometry = { [weak self] result, request in
                guard let self else { return }
                self.layerRenderer?.applyCommitted(
                    result: result,
                    on: self.layer,
                    scale: CGFloat(request.scale),
                    animation: request.animation
                )
            }
            coord.onCommitDisplayArtifact = { [weak self] artifact in
                self?.layerRenderer?.applyArtifact(artifact)
            }
            self.inputHandler = inputHandler
            self.signalHandler = signalHandler
            self.swipeContainer = Self.findSwipeContainer(in: node)
            node.onInvalidate = { [weak self] target in
                guard let self else { return }
                guard let root = self.node, self.bounds.width > 0, self.bounds.height > 0 else {
                    self.setNeedsLayout()
                    return
                }
                if target !== root, self.coordinator?.currentTransaction != nil {
                    self.coordinator?.invalidateDisplay(for: target)
                } else {
                    let scale = Double(self.window?.screen.scale ?? UIScreen.main.scale)
                    self.coordinator?.invalidate(
                        root: root,
                        bounds: LayoutFrame(width: self.bounds.width, height: self.bounds.height),
                        scale: scale
                    )
                }
            }
            node.onInvalidateVisualStyle = { [weak self] target in
                self?.layerRenderer?.applyVisualOnly(
                    nodeID: target.id,
                    appearance: target.appearance
                )
            }
            node.onScrollStateChanged = { [weak self] scrollNode in
                self?.layerRenderer?.applyScrollOffset(node: scrollNode)
            }
            node.onEdgePullChanged = { [weak self] scrollNode in
                self?.layerRenderer?.applyEdgePull(node: scrollNode)
            }
            installLifecycleObservers()
        }
        func connectNode() { _ = node?.connect() }
        func detach() {
            node?.onInvalidate = nil
            node?.onInvalidateVisualStyle = nil
            node?.onScrollStateChanged = nil
            node?.onEdgePullChanged = nil
            node = nil
            if ownsCoordinator {
                coordinator?.dispose()
            }
            coordinator = nil
            layerRenderer?.unmount()
            layerRenderer = nil
            inputHandler = nil
            signalHandler = nil
            swipeContainer?.cancelSwipeReveal()
            swipeContainer = nil
            swipeStartPoint = nil
            swipeIsActive = false
            lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
            lifecycleObservers.removeAll()
        }

        private func installLifecycleObservers() {
            let center = NotificationCenter.default
            lifecycleObservers = [
                center.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.emit(.becameActive) }
                },
                center.addObserver(
                    forName: UIApplication.willResignActiveNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.inputHandler?(.cancelled)
                        self?.emit(.resignedActive)
                    }
                },
            ]
        }

        /// Emits a typed platform signal from the host boundary.
        /// Ownership: the signal is immutable. Isolation: MainActor. Errors: none. Cancellation: none.
        public func emit(_ signal: UIKitPlatformSignal) { signalHandler?(signal) }

        #if DEBUG
            /// Test-only raw input injection used by the adapter contract harness.
            /// Ownership: the value is copied into the callback. Isolation: MainActor. Errors: none.
            /// Cancellation: callers may inject `cancelled` explicitly.
            internal func emitInputForTesting(_ input: UIKitInput) {
                inputHandler?(input)
            }
        #endif

        public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first.map({ convert($0.location(in: self), from: self) })
            else { return }
            swipeStartPoint = point
            swipeIsActive = false
            inputHandler?(.touchDown(point: point))
        }

        public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first.map({ convert($0.location(in: self), from: self) })
            else { return }
            if let start = swipeStartPoint {
                let dx = point.x - start.x
                let dy = point.y - start.y
                if !swipeIsActive, abs(dx) > 6, abs(dx) > abs(dy) * 1.5 {
                    if isSwipeOpen { closeSwipePresentation() }
                    let edge: SwipeEdge = dx >= 0 ? .leading : .trailing
                    swipeIsActive =
                        swipeContainer?.beginSwipeReveal(
                            at: LayoutPoint(x: start.x, y: start.y), edge: edge
                        ) ?? false
                }
                if swipeIsActive {
                    swipeContainer?.updateSwipeReveal(translation: Double(dx))
                    renderSwipeReveal()
                    return
                }
            }
            inputHandler?(.touchMoved(point: point))
        }

        public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let point = touches.first.map({ convert($0.location(in: self), from: self) })
            else { return }
            if swipeIsActive {
                if !invokeSwipeAction(at: point) { finishSwipePresentation(velocity: 0) }
                swipeIsActive = false
                swipeStartPoint = nil
                return
            }
            if isSwipeOpen {
                if !invokeSwipeAction(at: point) { closeSwipePresentation() }
                swipeIsActive = false
                swipeStartPoint = nil
                return
            }
            swipeStartPoint = nil
            inputHandler?(.touchUp(point: point))
        }

        public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            cancelSwipePresentation()
            swipeStartPoint = nil
            swipeIsActive = false
            inputHandler?(.cancelled)
        }

        private func cancelSwipePresentation() {
            guard let container = swipeContainer, let row = container.activeSwipeNode else {
                swipeContainer?.cancelSwipeReveal()
                return
            }
            container.cancelSwipeReveal()
            layerRenderer?.applySwipeReveal(
                node: row,
                state: .closed,
                configuration: nil,
                theme: row.environmentSnapshot.values[ThemeKey.self]
            )
        }

        private func closeSwipePresentation() {
            guard let container = swipeContainer, let row = container.activeSwipeNode else {
                swipeContainer?.closeSwipeReveal()
                return
            }
            container.closeSwipeReveal()
            layerRenderer?.applySwipeReveal(
                node: row, state: .closed, configuration: nil,
                theme: row.environmentSnapshot.values[ThemeKey.self]
            )
        }

        private func finishSwipePresentation(velocity: Double) {
            guard let container = swipeContainer, let row = container.activeSwipeNode else {
                return
            }
            container.finishSwipeReveal(velocity: velocity)
            if container.activeSwipeNode != nil {
                renderSwipeReveal()
            } else {
                layerRenderer?.applySwipeReveal(
                    node: row, state: .closed, configuration: nil,
                    theme: row.environmentSnapshot.values[ThemeKey.self]
                )
            }
        }

        private static func findSwipeContainer(in node: Node) -> (any SwipeRevealContainer)? {
            if let container = node as? any SwipeRevealContainer { return container }
            for child in node.subnodes {
                if let container = findSwipeContainer(in: child) { return container }
            }
            return nil
        }

        private func renderSwipeReveal() {
            guard let container = swipeContainer, let row = container.activeSwipeNode else {
                return
            }
            layerRenderer?.applySwipeReveal(
                node: row,
                state: container.activeSwipeState,
                configuration: container.activeSwipeConfiguration,
                theme: row.environmentSnapshot.values[ThemeKey.self]
            )
        }

        private var isSwipeOpen: Bool {
            guard let container = swipeContainer else { return false }
            if case .open = container.activeSwipeState { return true }
            return false
        }

        private func invokeSwipeAction(at point: CGPoint) -> Bool {
            guard let container = swipeContainer, let row = container.activeSwipeNode,
                let configuration = container.activeSwipeConfiguration
            else { return false }
            let edge: SwipeEdge
            let offset: Double
            switch container.activeSwipeState {
            case let .revealing(value, current), let .open(value, current),
                let .settling(value, current):
                edge = value; offset = current
            case .closed, .cancelled:
                return false
            }
            guard let frame = row.calculatedFrame, abs(offset) >= 36 else { return false }
            let localX = point.x - CGFloat(frame.origin.x)
            let actionWidth = CGFloat(72)
            let totalWidth = CGFloat(configuration.actions.count) * actionWidth
            let index: Int
            switch edge {
            case .leading:
                guard localX >= 0, localX < totalWidth else { return false }
                let slot = Int(localX / actionWidth)
                index = slot == configuration.actions.count - 1 ? 0 : slot + 1
            case .trailing:
                guard localX >= CGFloat(frame.width) - totalWidth, localX < CGFloat(frame.width)
                else { return false }
                index = Int((localX - (CGFloat(frame.width) - totalWidth)) / actionWidth)
            }
            guard configuration.actions.indices.contains(index) else { return false }
            let accepted = container.invokeSwipeAction(
                actionID: configuration.actions[index].id, complete: { _ in })
            if accepted {
                layerRenderer?.applySwipeReveal(
                    node: row, state: .closed, configuration: nil,
                    theme: row.environmentSnapshot.values[ThemeKey.self])
            }
            return accepted
        }

        public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            inputHandler?(.pressDown)
        }

        public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            inputHandler?(.pressUp)
        }

        public override func pressesCancelled(
            _ presses: Set<UIPress>,
            with event: UIPressesEvent?
        ) {
            inputHandler?(.cancelled)
        }

        public override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            let insets = safeAreaInsets
            emit(
                .safeAreaChanged(
                    PhysicalEdgeInsets(
                        top: Double(insets.top),
                        left: Double(insets.left),
                        bottom: Double(insets.bottom),
                        right: Double(insets.right)
                    )
                )
            )
        }

        public override func traitCollectionDidChange(
            _ previousTraitCollection: UITraitCollection?
        ) {
            super.traitCollectionDidChange(previousTraitCollection)
            emit(
                .traitsChanged(
                    interfaceStyle: traitCollection.userInterfaceStyle.rawValue,
                    horizontalSizeClass: traitCollection.horizontalSizeClass.rawValue,
                    verticalSizeClass: traitCollection.verticalSizeClass.rawValue
                )
            )
        }

        public override func willMove(toWindow newWindow: UIWindow?) {
            if newWindow == nil { emit(.inputInterrupted) }
            super.willMove(toWindow: newWindow)
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            guard let node, bounds.width >= 0, bounds.height >= 0 else { return }
            let scale = Double(window?.screen.scale ?? UIScreen.main.scale)
            coordinator?.invalidate(
                root: node,
                bounds: LayoutFrame(width: bounds.width, height: bounds.height),
                scale: scale
            )
        }
    }

    /// Thin UIKit adapter translating native host lifecycle into Weave lifecycle operations.
    /// Ownership: the adapter owns no application graph; hosts own their native views. Isolation:
    /// MainActor. Errors: repeated operations are idempotent. Cancellation: unmount releases host state.
    @MainActor
    public final class UIKitAdapter {
        /// Creates an adapter and installs CoreText as the default text layout backend.
        /// Ownership: the adapter owns no external resources. Isolation: MainActor. Errors: none.
        /// Cancellation: no work starts during initialization.
        public init() {
            TextLayoutBackendRegistry.makeDefault = { CoreTextLayoutBackend() }
        }

        /// Creates a lazy host for a node.
        /// Ownership: the returned view is caller-owned. Isolation: MainActor. Errors: none.
        /// Cancellation: no asynchronous work is started.
        public func makeHost(
            for node: Node,
            coordinator: RenderCoordinator? = nil,
            frame: CGRect = .zero,
            inputHandler: (@MainActor @Sendable (UIKitInput) -> Void)? = nil,
            signalHandler: (@MainActor @Sendable (UIKitPlatformSignal) -> Void)? = nil
        ) -> UIKitHostView {
            let host = UIKitHostView(frame: frame)
            host.attach(
                node: node,
                coordinator: coordinator,
                inputHandler: inputHandler,
                signalHandler: signalHandler
            )
            return host
        }

        /// Mounts a host into a parent view and connects the node once.
        /// Ownership: parent view retains the host after insertion. Isolation: MainActor. Errors: UIKit
        /// hierarchy errors are avoided by idempotent insertion. Cancellation: none.
        public func mount(_ host: UIKitHostView, in parent: UIView) {
            guard host.superview !== parent else { return }
            host.removeFromSuperview()
            parent.addSubview(host)
            host.connectNode()
        }

        /// Unmounts a host without disposing the logical node.
        /// Ownership: parent releases the host. Isolation: MainActor. Errors: none.
        /// Cancellation: host-local work is released with the view.
        public func unmount(_ host: UIKitHostView) { host.removeFromSuperview(); host.detach() }
    }

    /// Adapter-owned native host for one logical Weave window.
    /// Ownership: the host owns the native window/controller and borrows the logical window.
    /// Isolation: MainActor. Errors: mounting an empty logical window returns `false`; repeated
    /// mount/unmount operations are idempotent. Cancellation: unmount detaches the host callbacks.
    @MainActor
    public final class UIKitWindowHost: WindowHost {
        public let logicalWindow: Window
        public let nativeWindow: UIWindow
        public let coordinator: RenderCoordinator
        private let adapter: UIKitAdapter
        private var hostView: UIKitHostView?
        private var rootViewController: UIViewController?
        private var themeTask: Task<Void, Never>?
        private var scrollDecelerationTask: Task<Void, Never>?
        private var scrollVelocityY: Double = 0
        private var lastScrollTimestamp: CFTimeInterval?

        /// Creates an idle native host. No native hierarchy is mounted until `mount()`.
        /// Ownership: the host retains the native window and borrows the logical window.
        /// Isolation: MainActor. Errors: none. Cancellation: no work starts during initialization.
        public init(
            window: Window,
            nativeWindow: UIWindow,
            adapter: UIKitAdapter = UIKitAdapter(),
            coordinator: RenderCoordinator? = nil
        ) {
            logicalWindow = window
            self.nativeWindow = nativeWindow
            self.adapter = adapter
            self.coordinator = coordinator ?? RenderCoordinator(hostID: window.id)
        }

        /// Mounts the logical root into the native window.
        /// Ownership: the host retains the native controller/view; the logical window retains the
        /// controller/node. Isolation: MainActor. Errors: empty roots return `false`. Cancellation:
        /// caller-owned until `unmount()`.
        @discardableResult
        public func mount() -> Bool {
            guard let node = logicalWindow.rootController?.anyNode else { return false }
            guard hostView == nil else { return true }

            coordinator.mount(root: node)
            var lastTouchPoint: CGPoint?
            var edgePullActive = false
            var pressedControl: (any ControlInputTarget)?
            // Owns nested-scroll arbitration for this touch sequence: which ScrollNode ancestor
            // of the touch-down point (innermost first) claims the drag, sticky for the rest of
            // the gesture. Edge-pull keeps using the pre-existing single-node `findScrollNode`
            // lookup below — nested-claim interaction with edge-pull is explicitly out of scope
            // for card 03 (see Tasks/03-nested-scroll-arbitration.md).
            let scrollTracker = NestedScrollGestureTracker()
            let host = adapter.makeHost(
                for: node,
                coordinator: coordinator,
                inputHandler: { [weak self, weak node] input in
                    guard let self, let node else { return }
                    switch input {
                    case let .touchDown(point):
                        self.scrollDecelerationTask?.cancel()
                        self.scrollDecelerationTask = nil
                        self.scrollVelocityY = 0
                        self.lastScrollTimestamp = CACurrentMediaTime()
                        edgePullActive = false
                        lastTouchPoint = point
                        let layoutPoint = LayoutPoint(x: Double(point.x), y: Double(point.y))
                        pressedControl = Self.findControlTarget(in: node, at: layoutPoint)
                        _ = pressedControl?.handle(.pointerDown)
                        scrollTracker.begin(
                            candidates: Self.scrollCandidates(
                                in: node, at: layoutPoint),
                            targetsControl: pressedControl != nil
                        )
                    case let .touchMoved(point):
                        if let last = lastTouchPoint {
                            let dx = Double(last.x - point.x)
                            let dy = Double(last.y - point.y)
                            if let edgePull = Self.findScrollNode(in: node) {
                                if edgePullActive {
                                    edgePull.updateEdgePull(delta: dy)
                                    lastTouchPoint = point
                                    return
                                }
                                if edgePull.beginEdgePull(for: dy) {
                                    edgePullActive = true
                                    edgePull.updateEdgePull(delta: dy)
                                    lastTouchPoint = point
                                    return
                                }
                            }
                            let wasClaimed = scrollTracker.claimedScrollNode != nil
                            let claimed = scrollTracker.move(dx: dx, dy: dy)
                            if claimed != nil, !wasClaimed, pressedControl != nil {
                                // Scrolling just claimed this gesture — the pending press can
                                // never activate on release.
                                _ = pressedControl?.handle(.cancelled)
                                pressedControl = nil
                            }
                            let now = CACurrentMediaTime()
                            if let previous = self.lastScrollTimestamp {
                                let elapsed = max(1.0 / 240.0, now - previous)
                                let instantaneous = dy / elapsed
                                self.scrollVelocityY =
                                    self.scrollVelocityY * 0.75 + instantaneous * 0.25
                            }
                            self.lastScrollTimestamp = now
                        }
                        lastTouchPoint = point
                    case let .touchUp(point):
                        let control = pressedControl
                        pressedControl = nil
                        if edgePullActive,
                            let edgePull = Self.findScrollNode(in: node)
                        {
                            edgePull.finishEdgePull()
                            edgePullActive = false
                            self.lastScrollTimestamp = nil
                            lastTouchPoint = nil
                            scrollTracker.end()
                            _ = control?.handle(.cancelled)
                            return
                        }
                        if let control {
                            let hitAtRelease = Self.findControlTarget(
                                in: node, at: LayoutPoint(x: Double(point.x), y: Double(point.y)))
                            let inside = (hitAtRelease as AnyObject?) === (control as AnyObject)
                            _ = control.handle(.pointerUp(inside: inside))
                        }
                        // Momentum continues on whichever node this drag claimed, not a fresh
                        // whole-tree lookup — the claim holds through the momentum phase.
                        if let scroll = scrollTracker.claimedScrollNode {
                            self.startScrollDeceleration(
                                scroll: scroll, velocityY: self.scrollVelocityY)
                        }
                        scrollTracker.end()
                        self.lastScrollTimestamp = nil
                        lastTouchPoint = nil
                    case .cancelled:
                        if edgePullActive,
                            let edgePull = Self.findScrollNode(in: node)
                        {
                            edgePull.cancelEdgePull()
                        }
                        edgePullActive = false
                        _ = pressedControl?.handle(.cancelled)
                        pressedControl = nil
                        scrollTracker.cancel()
                        self.scrollDecelerationTask?.cancel()
                        self.scrollDecelerationTask = nil
                        self.lastScrollTimestamp = nil
                        lastTouchPoint = nil
                    default:
                        break
                    }
                },
                signalHandler: { [weak self] signal in
                    guard let self else { return }
                    switch signal {
                    case let .traitsChanged(interfaceStyle, _, _):
                        self.applySystemColorScheme(interfaceStyle)
                    case let .safeAreaChanged(insets):
                        self.applySafeArea(insets)
                    default:
                        break
                    }
                }
            )
            let controller = UIKitWindowRootViewController(host: host, adapter: adapter)
            nativeWindow.rootViewController = controller
            nativeWindow.makeKeyAndVisible()
            rootViewController = controller
            hostView = host
            host.emit(
                .traitsChanged(
                    interfaceStyle: host.traitCollection.userInterfaceStyle.rawValue,
                    horizontalSizeClass: host.traitCollection.horizontalSizeClass.rawValue,
                    verticalSizeClass: host.traitCollection.verticalSizeClass.rawValue
                )
            )
            host.emit(
                .safeAreaChanged(
                    PhysicalEdgeInsets(
                        top: host.safeAreaInsets.top,
                        left: host.safeAreaInsets.left,
                        bottom: host.safeAreaInsets.bottom,
                        right: host.safeAreaInsets.right
                    )
                )
            )
            return true
        }

        private static func findScrollNode(in node: Node) -> ScrollNode? {
            if let scroll = node as? ScrollNode { return scroll }
            for child in node.subnodes {
                if let found = findScrollNode(in: child) { return found }
            }
            return nil
        }

        /// Nested-scroll arbitration candidates at `point`, innermost first. Falls back to the
        /// single whole-tree `findScrollNode(in:)` lookup when hit-testing finds nothing — most
        /// commonly because the tree hasn't completed its first (async) layout pass yet and no
        /// node has a `calculatedFrame`. Without this fallback a gesture that starts before the
        /// first layout pass finishes would silently scroll nothing.
        private static func scrollCandidates(in node: Node, at point: LayoutPoint) -> [ScrollNode] {
            let hitTested = NestedScrollArbiter.scrollAncestors(in: node, at: point)
            guard hitTested.isEmpty else { return hitTested }
            // An empty result is the *correct* answer for a touch that's legitimately outside
            // every ScrollNode (e.g. a tap on a tab bar) — falling back there would let an
            // unrelated, possibly-scrollable node steal the gesture based on tree order alone,
            // nothing to do with where the touch actually was. Only fall back when the tree
            // hasn't had its first real layout pass at all yet (`node`, the root, has no frame),
            // which is the specific case this fallback exists for: a gesture arriving before
            // `calculatedFrame` exists anywhere, so hit-testing can't answer honestly either way.
            guard node.calculatedFrame == nil else { return [] }
            return [findScrollNode(in: node)].compactMap { $0 }
        }

        /// Hit-tests a point and walks up from the leaf hit to the nearest control-input target.
        /// A tap normally lands on a plain child (e.g. a label) nested inside the actual control.
        private static func findControlTarget(
            in root: Node, at point: LayoutPoint
        ) -> (any ControlInputTarget)? {
            var current = HitTester.hitTest(point: point, root: root)
            while let node = current {
                if let target = node as? any ControlInputTarget { return target }
                current = node.supernode
            }
            return nil
        }

        /// Unmounts the native root while retaining the logical window for later remount.
        /// Ownership: native host callbacks and view hierarchy are released. Isolation: MainActor.
        /// Errors: repeated calls are no-ops. Cancellation: active input is interrupted by detach.
        public func unmount() {
            scrollDecelerationTask?.cancel()
            scrollDecelerationTask = nil
            themeTask?.cancel()
            themeTask = nil
            coordinator.unmount()
            if let hostView { adapter.unmount(hostView) }
            hostView = nil
            rootViewController = nil
            nativeWindow.rootViewController = nil
            nativeWindow.isHidden = true
        }

        private func startScrollDeceleration(scroll: ScrollNode, velocityY: Double) {
            scrollDecelerationTask?.cancel()
            guard abs(velocityY) >= 80 else {
                scrollDecelerationTask = nil
                return
            }
            scrollDecelerationTask = Task { @MainActor [weak self, weak scroll] in
                var velocity = velocityY
                let frameDuration = 1.0 / 60.0
                while !Task.isCancelled, abs(velocity) >= 8, let scroll {
                    let previousOffset = scroll.state.offset.y
                    _ = scroll.moveBy(x: 0, y: velocity * frameDuration)
                    if scroll.state.offset.y == previousOffset { break }
                    velocity *= 0.94
                    try? await Task.sleep(for: .milliseconds(16))
                }
                self?.scrollDecelerationTask = nil
            }
        }

        private func applySystemColorScheme(_ interfaceStyle: Int) {
            let scheme: ColorScheme
            switch interfaceStyle {
            case 1: scheme = .light
            case 2: scheme = .dark
            default: scheme = .unspecified
            }
            themeTask?.cancel()
            let store = logicalWindow.themeStore
            let scope = logicalWindow.environment
            themeTask = Task { [weak self] in
                await store.apply(scheme: scheme, to: scope)
                guard !Task.isCancelled,
                    let self,
                    let root = self.logicalWindow.rootController?.anyNode,
                    let hostView = self.hostView
                else { return }
                let scale = Double(self.nativeWindow.screen.scale)
                self.coordinator.invalidate(
                    root: root,
                    bounds: LayoutFrame(
                        width: hostView.bounds.width,
                        height: hostView.bounds.height
                    ),
                    scale: scale
                )
            }
        }

        private func applySafeArea(_ physical: PhysicalEdgeInsets) {
            guard let root = logicalWindow.rootController?.anyNode else { return }
            let direction = root.environmentSnapshot.values.layoutDirection
            let logical = Self.logicalSafeArea(physical, direction: direction)
            let scope = logicalWindow.environment
            guard scope.snapshot.values.safeAreaInsets != logical else { return }
            scope.set(SafeAreaInsetsKey.self, logical)
            guard let hostView else { return }
            let scale = Double(nativeWindow.screen.scale)
            coordinator.invalidate(
                root: root,
                bounds: LayoutFrame(
                    width: hostView.bounds.width,
                    height: hostView.bounds.height
                ),
                scale: scale
            )
        }

        private static func logicalSafeArea(
            _ physical: PhysicalEdgeInsets,
            direction: LayoutDirection
        ) -> SafeAreaInsets {
            switch direction {
            case .leftToRight:
                return SafeAreaInsets(
                    top: physical.top, leading: physical.left,
                    bottom: physical.bottom, trailing: physical.right
                )
            case .rightToLeft:
                return SafeAreaInsets(
                    top: physical.top, leading: physical.right,
                    bottom: physical.bottom, trailing: physical.left
                )
            }
        }
    }

    @MainActor
    private final class UIKitWindowRootViewController: UIViewController {
        private let host: UIKitHostView
        private let adapter: UIKitAdapter

        init(host: UIKitHostView, adapter: UIKitAdapter) {
            self.host = host
            self.adapter = adapter
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            adapter.mount(host, in: view)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            host.frame = view.bounds
            host.layoutIfNeeded()
        }
    }

    #if os(iOS)
        /// UIKit menu/toolbar/keyboard presenter for the shared command registry.
        /// Ownership: presenter borrows the registry and owns native menu actions. Isolation: MainActor.
        /// Errors: unavailable native capabilities use command registry fallback. Cancellation: dispose releases native actions.
        @MainActor
        public final class UIKitCommandPresenter {
            private weak var registry: CommandRegistry?

            /// Creates a presenter without registering commands. Ownership: registry is weakly borrowed. Isolation: MainActor. Errors: none. Cancellation: no work starts.
            public init(registry: CommandRegistry) { self.registry = registry }

            /// Builds a native menu from command metadata. Ownership: returned menu owns its UI actions. Isolation: MainActor. Errors: missing commands are omitted. Cancellation: action tasks are caller-owned.
            public func makeMenu(title: String = "Commands") -> UIMenu {
                let actions =
                    registry?.definitions(capability: .menu).map { definition in
                        UIAction(title: definition.title.fallback) { [weak self] _ in
                            Task { @MainActor in _ = await self?.registry?.execute(definition.id) }
                        }
                    } ?? []
                return UIMenu(title: title, children: actions)
            }

            /// Builds toolbar items whose actions dispatch through the registry. Ownership: returned items are caller-owned.
            /// Isolation: MainActor. Errors: unavailable commands are omitted. Cancellation: item actions stop after presenter deallocation.
            public func makeToolbarItems() -> [UIBarButtonItem] {
                registry?.definitions(capability: .toolbar).map { definition in
                    let item = UIBarButtonItem(
                        title: definition.title.fallback, style: .plain, target: nil, action: nil)
                    item.primaryAction = UIAction { [weak self] _ in
                        Task { @MainActor in _ = await self?.registry?.execute(definition.id) }
                    }
                    return item
                } ?? []
            }
        }

        /// Responder bridge that exposes registry shortcuts to iPad/mac-style keyboards.
        /// Ownership: responder weakly borrows the registry. Isolation: MainActor. Errors: unmatched shortcuts are ignored. Cancellation: deallocation removes key commands.
        @MainActor
        public final class UIKitCommandResponder: UIResponder {
            private weak var registry: CommandRegistry?

            /// Creates a responder bridge. Ownership: registry is weakly borrowed. Isolation: MainActor. Errors: none. Cancellation: no work starts.
            public init(registry: CommandRegistry) { self.registry = registry; super.init() }

            /// Current key commands for active registry definitions. Ownership: returned commands are native snapshots. Isolation: MainActor. Errors: unsupported modifier combinations are omitted. Cancellation: not applicable.
            public override var keyCommands: [UIKeyCommand]? {
                registry?.definitions(capability: .keyboard).compactMap { definition in
                    guard let shortcut = definition.shortcut else { return nil }
                    var modifiers: UIKeyModifierFlags = []
                    if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
                    if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
                    if shortcut.modifiers.contains(.option) { modifiers.insert(.alternate) }
                    if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
                    return UIKeyCommand(
                        input: shortcut.key,
                        modifierFlags: modifiers,
                        action: #selector(performKeyCommand(_:)))
                }
            }

            /// Dispatches one native key command. Ownership: event is borrowed. Isolation: MainActor. Errors: unmatched shortcuts are ignored. Cancellation: registry action policy applies.
            @objc public func performKeyCommand(_ command: UIKeyCommand) {
                let modifiers = command.modifierFlags
                var weaveModifiers: CommandModifiers = []
                if modifiers.contains(.command) { weaveModifiers.insert(.command) }
                if modifiers.contains(.shift) { weaveModifiers.insert(.shift) }
                if modifiers.contains(.alternate) { weaveModifiers.insert(.option) }
                if modifiers.contains(.control) { weaveModifiers.insert(.control) }
                guard let input = command.input else { return }
                let shortcut = CommandShortcut(key: input, modifiers: weaveModifiers)
                Task { @MainActor in _ = await registry?.execute(shortcut) }
            }
        }

        /// UIKit drag and drop bridge translating native UIDropSession into Core transfer contracts.
        /// Ownership: the bridge coordinates session translation with TransferCoordinator. Isolation: MainActor.
        /// Errors: unreadable item providers produce typed transfer errors. Cancellation: cancelled sessions stop loading.
        @MainActor
        public final class UIKitTransferBridge: NSObject, UIDropInteractionDelegate {
            private let coordinator: TransferCoordinator
            private let ownerID: TransferOwnerID
            private weak var destinationNode: (any TransferableNode)?

            /// Creates a UIKit transfer bridge.
            /// Ownership: coordinator is retained, ownerID is copied. Isolation: MainActor. Errors: none. Cancellation: no work starts.
            public init(
                coordinator: TransferCoordinator,
                ownerID: TransferOwnerID,
                destinationNode: (any TransferableNode)? = nil
            ) {
                self.coordinator = coordinator
                self.ownerID = ownerID
                self.destinationNode = destinationNode
                super.init()
            }

            /// Attaches destination node to receive drops.
            /// Ownership: destination node is weakly referenced. Isolation: MainActor. Errors: none. Cancellation: none.
            public func setDestinationNode(_ node: (any TransferableNode)?) {
                self.destinationNode = node
            }

            /// Extracts transfer metadata from a native drop session.
            /// Ownership: metadata array is caller-owned. Isolation: MainActor. Errors: none. Cancellation: none.
            public func extractMetadata(from session: UIDropSession) -> [TransferMetadata] {
                session.items.flatMap { item in
                    item.itemProvider.registeredTypeIdentifiers.map { type in
                        TransferMetadata(
                            contentType: type,
                            size: nil,
                            suggestedName: item.itemProvider.suggestedName
                        )
                    }
                }
            }

            /// Determines if the drop session can be handled by checking registered types.
            /// Ownership: session is borrowed. Isolation: MainActor. Errors: none. Cancellation: not applicable.
            public func canHandle(session: UIDropSession) -> Bool {
                !extractMetadata(from: session).isEmpty
            }

            /// Evaluates a candidate drop session on a transferable node.
            /// Ownership: parameters are borrowed. Isolation: MainActor. Errors: none. Cancellation: cancelled sessions produce .forbidden.
            public func evaluateDrop(
                session: UIDropSession,
                node: any TransferableNode,
                kind: TransferSessionKind? = nil
            ) async -> UIDropOperation {
                let metadata = extractMetadata(from: session)
                guard !metadata.isEmpty else { return .cancel }

                let effectiveKind =
                    kind ?? (session.localDragSession != nil ? .internalReorder : .externalTransfer)
                let transferSession = TransferSession(
                    ownerID: ownerID,
                    kind: effectiveKind,
                    limits: TransferLimits(allowedTypes: Set(metadata.map(\.contentType)))
                )

                let proposal = await coordinator.proposeDrop(
                    metadata: metadata,
                    session: transferSession,
                    destinationOwner: ownerID,
                    node: node
                )

                switch proposal {
                case .copy: return .copy
                case .move: return .move
                case .link: return .copy
                case .forbidden: return .cancel
                }
            }

            /// Performs the drop by loading item provider data and importing it into the node.
            /// Ownership: data is loaded asynchronously. Isolation: MainActor. Errors: failures are returned in the outcome. Cancellation: respects session cancellation.
            public func performDrop(
                session: UIDropSession,
                node: any TransferableNode,
                kind: TransferSessionKind? = nil
            ) async -> TransferOutcome {
                let items = session.items
                guard !items.isEmpty else { return .rejected(.noRepresentation) }

                var transferItems: [TransferItem] = []
                var targetMetadata: [TransferMetadata] = []

                do {
                    for item in items {
                        let provider = item.itemProvider
                        var representations: [TransferRepresentation] = []
                        for type in provider.registeredTypeIdentifiers {
                            let typeID = type
                            let data: Data = try await withCheckedThrowingContinuation {
                                continuation in
                                provider.loadDataRepresentation(forTypeIdentifier: typeID) {
                                    data, error in
                                    if let data {
                                        continuation.resume(returning: data)
                                    } else if let error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume(
                                            throwing: TransferError.invalidPayload)
                                    }
                                }
                            }
                            representations.append(
                                TransferRepresentation(
                                    contentType: typeID,
                                    size: data.count,
                                    load: { data }
                                )
                            )
                            targetMetadata.append(
                                TransferMetadata(
                                    contentType: typeID,
                                    size: data.count,
                                    suggestedName: provider.suggestedName
                                )
                            )
                        }
                        if !representations.isEmpty {
                            transferItems.append(TransferItem(representations: representations))
                        }
                    }
                } catch {
                    return .failed(.loaderFailed(String(describing: error)))
                }

                guard !transferItems.isEmpty else { return .rejected(.noRepresentation) }

                let effectiveKind =
                    kind ?? (session.localDragSession != nil ? .internalReorder : .externalTransfer)
                let transferSession = TransferSession(
                    ownerID: ownerID,
                    kind: effectiveKind,
                    limits: TransferLimits(allowedTypes: Set(targetMetadata.map(\.contentType)))
                )

                return await coordinator.importItems(
                    targetMetadata,
                    from: transferItems,
                    session: transferSession,
                    destinationOwner: ownerID,
                    into: node
                )
            }
        }
    #endif

    /// AVFoundation-backed implementation of the platform-neutral video backend.
    /// Ownership: backend owns the player and observers. Isolation: MainActor. Errors: AVFoundation failures become `VideoFailure`. Cancellation: `unload` releases the item and observer.
    @MainActor
    public final class AVPlayerVideoBackend: NSObject, VideoBackend, CALayerAttachingVideoBackend {
        private let player = AVPlayer()
        private var playerLayer: AVPlayerLayer?
        private let continuation: AsyncStream<VideoBackendEvent>.Continuation
        private let stream: AsyncStream<VideoBackendEvent>
        private var timeObserver: Any?

        /// Creates an idle AVPlayer backend.
        /// Ownership: backend owns AVPlayer. Isolation: MainActor. Errors: none. Cancellation: no load starts.
        public override init() {
            let pair = AsyncStream<VideoBackendEvent>.makeStream()
            stream = pair.stream
            continuation = pair.continuation
            super.init()
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                Task { @MainActor [weak self] in
                    self?.continuation.yield(.progress(seconds: seconds))
                }
            }
        }

        /// Backend event stream. Ownership: stream is borrowed. Isolation: MainActor delivery. Errors: typed backend failures. Cancellation: stream finishes on deinit.
        public var events: AsyncStream<VideoBackendEvent> { stream }

        /// Attaches this backend's AVPlayerLayer as a sublayer of hostLayer.
        /// Ownership: hostLayer borrows player layer. Isolation: MainActor. Errors: none. Cancellation: detach removes sublayer.
        public func attachVideoLayer(to hostLayer: CALayer) {
            let layer = playerLayer ?? AVPlayerLayer(player: player)
            layer.videoGravity = .resizeAspect
            layer.player = player
            playerLayer = layer
            if layer.superlayer !== hostLayer {
                hostLayer.addSublayer(layer)
            }
        }

        /// Detaches the AVPlayerLayer from its superlayer.
        /// Ownership: player layer is unlinked from hierarchy. Isolation: MainActor. Errors: none. Cancellation: idempotent.
        public func detachVideoLayer() {
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
        }

        /// Updates the bounds of the attached AVPlayerLayer.
        /// Ownership: frame is copied. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func updateVideoLayerBounds(_ bounds: CGRect) {
            playerLayer?.frame = bounds
        }

        /// Creates a layer-backed surface attached to this backend's player.
        /// Ownership: returned view is caller-owned; backend retains AVPlayer. Isolation: MainActor. Errors: none. Cancellation: view stops rendering after backend disposal.
        public func makeView(frame: CGRect = .zero) -> AVPlayerVideoView {
            let view = AVPlayerVideoView(frame: frame)
            view.layer.masksToBounds = true
            view.player = player
            return view
        }

        /// Loads and prepares a source, replacing the current item.
        /// Ownership: backend retains the player item. Isolation: MainActor. Errors: AVAsset load errors throw. Cancellation: task cancellation propagates to asset loading.
        public func load(_ source: VideoSource) async throws -> VideoMetadata {
            let asset = AVURLAsset(url: source.url)
            let duration = try await asset.load(.duration)
            try Task.checkCancellation()
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            return VideoMetadata(duration: duration.isNumeric ? duration.seconds : nil)
        }

        /// Starts playback. Ownership: player remains backend-owned. Isolation: MainActor. Errors: native failures arrive through events. Cancellation: pause/unload stops playback.
        public func play() { player.play() }
        /// Pauses playback. Ownership: player remains backend-owned. Isolation: MainActor. Errors: none. Cancellation: unload releases the item.
        public func pause() { player.pause() }

        /// Releases the item and all pending playback observations.
        /// Ownership: player item is released. Isolation: MainActor. Errors: none. Cancellation: observers stop emitting after unload.
        public func unload() {
            player.pause()
            player.replaceCurrentItem(with: nil)
            detachVideoLayer()
        }

        /// Permanently releases AVPlayer observations and finishes events.
        /// Ownership: player observer and item are released. Isolation: MainActor. Errors: none. Cancellation: no later events are emitted.
        public func dispose() {
            unload()
            if let timeObserver {
                player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
            continuation.finish()
        }
    }

    /// UIKit rendering surface for an `AVPlayerVideoBackend`.
    /// Ownership: view borrows the player. Isolation: MainActor. Errors: unsupported rendering is delegated to AVPlayerLayer. Cancellation: removing the view stops presentation.
    @MainActor
    public final class AVPlayerVideoView: UIView {
        override public class var layerClass: AnyClass { AVPlayerLayer.self }
        public var player: AVPlayer? {
            get { (layer as? AVPlayerLayer)?.player }
            set {
                let playerLayer = layer as? AVPlayerLayer
                playerLayer?.player = newValue
                playerLayer?.videoGravity = .resizeAspect
            }
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            (layer as? AVPlayerLayer)?.frame = bounds
        }
    }

    /// CoreText-backed implementation of Weave's text layout boundary.
    /// Ownership: backend owns no native view and returns immutable results. Isolation: MainActor entry; CoreText work uses Sendable inputs. Errors: invalid fonts fall back to Helvetica. Cancellation: task cancellation is checked before returning.
    @MainActor
    public final class CoreTextLayoutBackend: TextLayoutBackend {
        /// Creates a stateless CoreText backend.
        /// Ownership: no external resources are retained. Isolation: MainActor. Errors: none. Cancellation: no work starts.
        public init() {}

        /// Measures text with CoreText. Ownership: result is owned by the caller. Isolation:
        /// MainActor. Errors: invalid fonts use backend fallbacks. Cancellation: not applicable.
        public func measure(_ input: TextLayoutInput) -> TextMetrics {
            CoreTextRasterRenderer.measure(
                text: input.text,
                style: input.style,
                constraint: input.constraint,
                direction: input.direction,
                localeIdentifier: input.localeIdentifier,
                maxLines: input.maxLines,
                truncation: input.truncation
            )
        }

        /// Measures and prepares a display result from one immutable input.
        /// Ownership: result is newly owned by the caller. Isolation: MainActor. Errors: none. Cancellation: cancelled requests throw `CancellationError`.
        public func display(_ input: TextLayoutInput, generation: UInt64) async throws
            -> TextDisplayResult
        {
            try Task.checkCancellation()
            let metrics = CoreTextRasterRenderer.measure(
                text: input.text,
                style: input.style,
                constraint: input.constraint,
                direction: input.direction,
                localeIdentifier: input.localeIdentifier,
                maxLines: input.maxLines,
                truncation: input.truncation
            )
            let rendered =
                metrics.didTruncate
                ? truncated(input.text, maxLines: metrics.lineCount, policy: input.truncation)
                : input.text
            return TextDisplayResult(
                renderedText: rendered,
                metrics: metrics,
                generation: generation
            )
        }

        private func truncated(_ text: String, maxLines: Int, policy: TextTruncation) -> String {
            guard maxLines > 0 else { return "" }
            guard case let .tail(ellipsis) = policy else { return text }
            let limit = max(0, text.count - ellipsis.count)
            return String(text.prefix(limit)) + ellipsis
        }
    }

    /// URLSession + ImageIO loader with target-size thumbnail decoding.
    /// Ownership: loader retains no cache or image objects. Isolation: async Sendable boundary. Errors: transport/corrupt bytes throw `ImageFailure`. Cancellation: URLSession and ImageIO work observe task cancellation.
    public struct ImageIOImageLoader: ImageLoader, Sendable {
        /// Creates a stateless network/image decoder.
        /// Ownership: no external resources are retained. Isolation: none. Errors: none. Cancellation: no work starts.
        public init() {}

        /// Downloads and decodes one image, downsampling to the requested pixel size.
        /// Ownership: returned data is owned by `LoadedImage`. Isolation: async. Errors: HTTP and corrupt image data throw. Cancellation: caller cancellation propagates.
        public func load(_ request: ImageRequest) async throws -> LoadedImage {
            let (data, response) = try await URLSession.shared.data(from: request.source.url)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse,
                !(200..<300).contains(response.statusCode)
            {
                throw ImageFailure(message: "HTTP \(response.statusCode)")
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw ImageFailure(message: "Image data is corrupt or unsupported")
            }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let target = request.targetSize {
                options[kCGImageSourceThumbnailMaxPixelSize] =
                    max(target.width, target.height) * request.scale
            }
            guard
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else {
                throw ImageFailure(message: "Image decode failed")
            }
            let output = NSMutableData()
            guard
                let destination = CGImageDestinationCreateWithData(
                    output, UTType.png.identifier as CFString, 1, nil)
            else { throw ImageFailure(message: "Image encode failed") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ImageFailure(message: "Image encode failed")
            }
            return LoadedImage(
                data: output as Data,
                size: MeasuredSize(width: Double(image.width), height: Double(image.height)))
        }
    }

    /// UIKit VoiceOver bridge consuming headless Weave snapshots.
    /// Ownership: the bridge retains only the latest snapshot. Isolation: MainActor. Errors: UIKit
    /// notification delivery is best effort. Cancellation: a newer snapshot replaces the old one.
    @MainActor
    public final class UIKitAccessibilityBridge: AccessibilityBridge {
        public private(set) var latestSnapshot: AccessibilitySnapshot?

        /// Creates an empty UIKit accessibility bridge.
        /// Ownership: no native elements are allocated. Isolation: MainActor. Errors: none. Cancellation: none.
        public init() {}

        /// Publishes a committed snapshot to UIKit accessibility.
        /// Ownership: the snapshot is copied. Isolation: MainActor. Errors: no thrown errors.
        /// Cancellation: superseded snapshots are replaced.
        public func apply(_ snapshot: AccessibilitySnapshot) {
            latestSnapshot = snapshot
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
        }
    }

    /// UIKit text-field bridge for an `EditableTextNode`.
    /// Ownership: bridge weakly references the native field and node; caller owns both. Isolation: MainActor. Errors: native selection updates are clamped. Cancellation: detach removes target callbacks.
    @MainActor
    public final class UIKitTextFieldBridge: NSObject, UITextFieldDelegate, TextInputBridge {
        private weak var textField: UITextField?
        private weak var node: EditableTextNode?
        private var applying = false

        /// Creates a bridge and installs editing callbacks. Ownership: bridge does not retain field or node. Isolation: MainActor. Errors: none. Cancellation: deinit releases callbacks.
        public init(textField: UITextField, node: EditableTextNode) {
            self.textField = textField
            self.node = node
            super.init()
            textField.delegate = self
            textField.addTarget(self, action: #selector(textDidChange), for: .editingChanged)
        }

        /// Applies committed Core state to UIKit without feeding the update back as a new edit.
        /// Ownership: state is borrowed. Isolation: MainActor. Errors: native ranges clamp. Cancellation: none.
        public func apply(_ state: TextEditingState) {
            guard let textField else { return }
            applying = true
            textField.text = state.text
            textField.isSecureTextEntry = state.isSecure
            if let position = textField.position(
                from: textField.beginningOfDocument, offset: state.selection.location),
                let end = textField.position(from: position, offset: state.selection.length)
            {
                textField.selectedTextRange = textField.textRange(from: position, to: end)
            }
            applying = false
        }

        /// Sends a typed action into Core. Ownership: action is copied. Isolation: MainActor. Errors: invalid edits are ignored. Cancellation: detached bridge drops the action.
        public func send(_ action: TextEditingAction) { _ = node?.apply(action) }

        @objc private func textDidChange() {
            guard !applying, let textField else { return }
            guard let node else { return }
            // UIKit reports the complete control value. Replace the previous committed
            // value, rather than inserting the complete value at the old caret (which
            // duplicates the prefix on every editingChanged callback).
            let previous = node.editingState.text
            send(
                .replace(
                    range: TextRange(location: 0, length: previous.count),
                    text: textField.text ?? ""))
            if let selected = textField.selectedTextRange {
                let location = textField.offset(
                    from: textField.beginningOfDocument, to: selected.start)
                let length = textField.offset(from: selected.start, to: selected.end)
                send(.setSelection(TextRange(location: location, length: length)))
            }
        }

        /// Converts Return into a typed submit action. Ownership: native field is borrowed. Isolation: MainActor. Errors: none. Cancellation: delegate removal stops delivery.
        public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            send(.submit)
            return true
        }

    }

    /// UIKit multiline text-view bridge. Return is handled by UITextView and becomes a newline.
    /// Ownership: bridge borrows the native view and node. Isolation: MainActor. Errors: native ranges are clamped. Cancellation: delegate removal stops delivery.
    @MainActor
    public final class UIKitTextViewBridge: NSObject, UITextViewDelegate, TextInputBridge {
        private weak var textView: UITextView?
        private weak var node: EditableTextNode?
        private var applying = false

        /// Creates a bridge borrowing the text view and node. Ownership: caller owns both. Isolation: MainActor. Errors: none. Cancellation: delegate removal stops delivery.
        public init(textView: UITextView, node: EditableTextNode) {
            self.textView = textView
            self.node = node
            super.init()
            textView.delegate = self
        }

        /// Applies Core state without feeding it back as an edit. Ownership: state is borrowed. Isolation: MainActor. Errors: ranges are clamped. Cancellation: none.
        public func apply(_ state: TextEditingState) {
            guard let textView else { return }
            applying = true
            textView.text = state.text
            textView.selectedRange = NSRange(
                location: state.selection.location, length: state.selection.length)
            applying = false
        }

        /// Sends one typed action to Core. Ownership: action is copied. Isolation: MainActor. Errors: invalid edits are ignored. Cancellation: detached bridge drops the action.
        public func send(_ action: TextEditingAction) { _ = node?.apply(action) }

        /// Converts native changes into one replacement and selection action. Ownership: notification is borrowed. Isolation: MainActor. Errors: invalid ranges are clamped. Cancellation: detached bridge stops delivery.
        public func textViewDidChange(_ textView: UITextView) {
            guard !applying, let node else { return }
            send(
                .replace(
                    range: TextRange(location: 0, length: node.editingState.text.count),
                    text: textView.text))
            send(
                .setSelection(
                    TextRange(
                        location: textView.selectedRange.location,
                        length: textView.selectedRange.length)))
        }
    }

    #if os(iOS)
        /// UIKit haptics adapter; unsupported feedback is safely ignored by the system generator.
        /// Ownership: adapter owns no long-lived generator. Isolation: MainActor. Errors: native capability failures are ignored. Cancellation: none.
        @MainActor
        public final class UIKitHapticsClient: HapticsClient {
            /// Creates a UIKit haptics adapter.
            /// Ownership: adapter owns no generator until play. Isolation: MainActor. Errors: none. Cancellation: none.
            public init() {}

            /// Plays one UIKit haptic intent.
            /// Ownership: intent is borrowed. Isolation: MainActor. Errors: unsupported feedback is ignored. Cancellation: none.
            public func play(_ feedback: HapticFeedback) {
                switch feedback {
                case .selection:
                    let generator = UISelectionFeedbackGenerator()
                    generator.prepare(); generator.selectionChanged()
                case let .impact(intensity):
                    let generator = UIImpactFeedbackGenerator(
                        style: intensity >= 0.66 ? .heavy : intensity >= 0.33 ? .medium : .light)
                    generator.prepare();
                    generator.impactOccurred(intensity: min(max(intensity, 0), 1))
                case let .notification(kind):
                    let generator = UINotificationFeedbackGenerator()
                    generator.prepare()
                    generator.notificationOccurred(
                        kind == .success ? .success : kind == .warning ? .warning : .error)
                }
            }
        }

        /// UIKit system-sound adapter for short feedback intents.
        /// Ownership: adapter owns no audio resources. Isolation: MainActor. Errors: unavailable system sounds are ignored. Cancellation: none.
        @MainActor
        public final class UIKitSoundClient: SoundClient {
            /// Creates a UIKit sound adapter.
            /// Ownership: adapter owns no audio resources. Isolation: MainActor. Errors: none. Cancellation: none.
            public init() {}

            /// Plays one short system sound.
            /// Ownership: intent is borrowed. Isolation: MainActor. Errors: unavailable sounds are ignored. Cancellation: none.
            public func play(_ feedback: SoundFeedback) {
                let id: SystemSoundID
                switch feedback {
                case .selection: id = 1104
                case .success: id = 1057
                case .warning: id = 1007
                case .error: id = 1006
                }
                AudioServicesPlaySystemSound(id)
            }
        }
    #endif
#endif
