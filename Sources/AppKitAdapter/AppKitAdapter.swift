#if canImport(AppKit)
    import AppKit
    import AVFoundation
    import CoreText
    import ImageIO
    import UniformTypeIdentifiers
    import WeaveUI
    import WeaveAdapters

    /// Platform-neutral raw input emitted by the AppKit boundary.
    /// Ownership: the value owns copied input data. Isolation: none. Errors: unsupported native
    /// details are omitted. Cancellation: interruption is represented by `cancelled`.
    public enum AppKitInput: Sendable, Hashable {
        case mouseDown(point: CGPoint)
        case mouseDragged(point: CGPoint)
        case mouseUp(point: CGPoint)
        case scroll(deltaX: Double, deltaY: Double)
        case keyDown(keyCode: UInt16, characters: String?)
        case cancelled
    }

    /// Platform lifecycle and resource signal forwarded to shared runtime policy.
    /// Ownership: the signal is an immutable value. Isolation: none. Errors: unsupported native
    /// details are omitted. Cancellation: input interruption is explicit.
    public enum AppKitPlatformSignal: Sendable, Hashable {
        case becameActive
        case resignedActive
        case resized(size: CGSize, scale: Double)
        case safeAreaChanged(PhysicalEdgeInsets)
        case appearanceChanged(isDark: Bool?)
        case memoryPressure
        case inputInterrupted
    }

    /// MainActor layer-backed AppKit host for one logical Node.
    /// Ownership: the host weakly references the Node and owns its NSView layer. Isolation:
    /// MainActor. Errors: repeated mount/unmount operations are idempotent. Cancellation: detach
    /// releases host input state.
    @MainActor
    public final class AppKitHostView: NSView {
        private weak var node: Node?
        public private(set) var coordinator: RenderCoordinator?
        private var ownsCoordinator = false
        private var layerRenderer: AppKitLayerRenderer?
        private var inputHandler: (@MainActor @Sendable (AppKitInput) -> Void)?
        private var signalHandler: (@MainActor @Sendable (AppKitPlatformSignal) -> Void)?
        private var swipeContainer: (any SwipeRevealContainer)?
        private var swipeStartPoint: CGPoint?
        private var swipeIsActive = false

        /// Creates a layer-backed host without starting lifecycle work.
        /// Ownership: the host owns its native view storage. Isolation: MainActor. Errors: none.
        /// Cancellation: no work starts during initialization.
        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        /// Creates a host from an archive.
        /// Ownership: AppKit owns decoded storage. Isolation: MainActor. Errors: decoding follows AppKit.
        /// Cancellation: not applicable.
        public required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        public override var isFlipped: Bool { true }

        /// Installs the logical node and raw input callback.
        /// Ownership: the host retains only a weak node and callback. Isolation: MainActor.
        /// Errors: replacing a callback is deterministic. Cancellation: prior callback is released.
        public func attach(
            node: Node,
            coordinator: RenderCoordinator? = nil,
            inputHandler: (@MainActor @Sendable (AppKitInput) -> Void)? = nil,
            signalHandler: (@MainActor @Sendable (AppKitPlatformSignal) -> Void)? = nil
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
            let renderer = AppKitLayerRenderer(root: node)
            self.layerRenderer = renderer
            coord.mount(root: node)
            coord.onCommitGeometry = { [weak self] result, request in
                guard let self, let layer = self.layer else { return }
                self.layerRenderer?.applyCommitted(
                    result: result,
                    on: layer,
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
                    self.needsLayout = true
                    return
                }
                if target !== root, self.coordinator?.currentTransaction != nil {
                    self.coordinator?.invalidateDisplay(for: target)
                } else {
                    let scale = Double(self.window?.backingScaleFactor ?? 1)
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
        }

        /// Connects the logical node once after a committed mount.
        /// Ownership: lifecycle remains owned by the Node. Isolation: MainActor. Errors: duplicate
        /// connects are rejected by the lifecycle machine. Cancellation: none.
        public func connectNode() { _ = node?.connect() }

        /// Releases the node and raw input callback.
        /// Ownership: host releases its references. Isolation: MainActor. Errors: none.
        /// Cancellation: pending input delivery is stopped.
        public func detach() {
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
        }

        /// Cancels the current raw input session.
        /// Ownership: no state escapes the host. Isolation: MainActor. Errors: none.
        /// Cancellation: emits one typed cancellation signal.
        public func interruptInput() { inputHandler?(.cancelled) }

        #if DEBUG
            internal func emitInputForTesting(_ input: AppKitInput) {
                inputHandler?(input)
            }
        #endif

        /// Emits a typed platform signal without exposing AppKit objects.
        /// Ownership: the signal is an immutable value. Isolation: MainActor. Errors: none.
        /// Cancellation: none.
        public func emit(_ signal: AppKitPlatformSignal) { signalHandler?(signal) }

        public override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            swipeStartPoint = point
            swipeIsActive = false
            inputHandler?(.mouseDown(point: point))
        }

        public override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
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
            inputHandler?(.mouseDragged(point: point))
        }

        public override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if swipeIsActive {
                if !invokeSwipeAction(at: point) { finishSwipePresentation(velocity: 0) }
                swipeStartPoint = nil
                swipeIsActive = false
                return
            }
            if isSwipeOpen {
                if !invokeSwipeAction(at: point) { closeSwipePresentation() }
                swipeStartPoint = nil
                swipeIsActive = false
                return
            }
            swipeStartPoint = nil
            inputHandler?(.mouseUp(point: point))
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

        public override func scrollWheel(with event: NSEvent) {
            inputHandler?(.scroll(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY))
        }

        public override func keyDown(with event: NSEvent) {
            inputHandler?(
                .keyDown(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            )
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

        public override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            needsLayout = true
            emit(
                .resized(
                    size: CGSize(width: bounds.width, height: bounds.height),
                    scale: Double(window?.backingScaleFactor ?? 1)
                )
            )
        }

        public override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { emit(.inputInterrupted) }
            return resigned
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                emit(.inputInterrupted)
            } else {
                emit(currentAppearanceSignal())
                emit(currentSafeAreaSignal())
            }
        }

        public override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            emit(currentAppearanceSignal())
        }

        func emitCurrentAppearance() {
            emit(currentAppearanceSignal())
        }

        private func currentAppearanceSignal() -> AppKitPlatformSignal {
            let match = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
            return .appearanceChanged(isDark: match.map { $0 == .darkAqua })
        }

        private func currentSafeAreaSignal() -> AppKitPlatformSignal {
            let insets = safeAreaInsets
            return .safeAreaChanged(
                PhysicalEdgeInsets(
                    top: Double(insets.top), left: Double(insets.left),
                    bottom: Double(insets.bottom), right: Double(insets.right)
                )
            )
        }

        public override func layout() {
            super.layout()
            emit(currentSafeAreaSignal())
            guard let node, bounds.width >= 0, bounds.height >= 0 else { return }
            let scale = Double(window?.backingScaleFactor ?? 1)
            coordinator?.invalidate(
                root: node,
                bounds: LayoutFrame(width: bounds.width, height: bounds.height),
                scale: scale
            )
        }
    }

    /// Thin AppKit adapter translating native host lifecycle into Weave operations.
    /// Ownership: the adapter owns no application graph. Isolation: MainActor. Errors: repeated
    /// operations are idempotent. Cancellation: unmount releases host input state.
    @MainActor
    public final class AppKitAdapter {
        /// Receives platform lifecycle/resource signals on MainActor.
        /// Ownership: the adapter owns the callback. Isolation: MainActor. Errors: none.
        /// Cancellation: clearing the callback stops delivery.
        public var onSignal: (@MainActor @Sendable (AppKitPlatformSignal) -> Void)?

        /// Creates an adapter and installs CoreText as the default text layout backend.
        /// Ownership: adapter owns no external resources. Isolation: MainActor. Errors: none.
        /// Cancellation: no work starts during initialization.
        public init(
            onSignal: (@MainActor @Sendable (AppKitPlatformSignal) -> Void)? = nil
        ) {
            self.onSignal = onSignal
            TextLayoutBackendRegistry.makeDefault = { CoreTextLayoutBackend() }
        }

        /// Forwards a platform signal into the shared resource/session contract.
        /// Ownership: the adapter forwards an immutable value. Isolation: MainActor. Errors: none.
        /// Cancellation: input interruption is terminal for the current session.
        public func emit(_ signal: AppKitPlatformSignal) { onSignal?(signal) }

        /// Creates a layer-backed host for a Node.
        /// Ownership: returned host is caller-owned. Isolation: MainActor. Errors: none.
        /// Cancellation: no asynchronous work starts.
        public func makeHost(
            for node: Node,
            coordinator: RenderCoordinator? = nil,
            frame: CGRect = .zero,
            inputHandler: (@MainActor @Sendable (AppKitInput) -> Void)? = nil,
            signalHandler: (@MainActor @Sendable (AppKitPlatformSignal) -> Void)? = nil
        ) -> AppKitHostView {
            let host = AppKitHostView(frame: frame)
            host.attach(
                node: node,
                coordinator: coordinator,
                inputHandler: inputHandler,
                signalHandler: signalHandler
            )
            return host
        }

        /// Mounts the host into a parent and connects the Node once.
        /// Ownership: parent retains the host after insertion. Isolation: MainActor. Errors: invalid
        /// duplicate insertion is avoided. Cancellation: none.
        public func mount(_ host: AppKitHostView, in parent: NSView) {
            guard host.superview !== parent else { return }
            host.removeFromSuperview()
            parent.addSubview(host)
            host.connectNode()
        }

        /// Unmounts the host without disposing the logical Node.
        /// Ownership: parent releases the host. Isolation: MainActor. Errors: none.
        /// Cancellation: host input state is released.
        public func unmount(_ host: AppKitHostView) {
            host.removeFromSuperview()
            host.detach()
        }

        /// Converts a point between views while preserving AppKit's flipped host coordinates.
        /// Ownership: returned point is a value. Isolation: MainActor. Errors: AppKit handles invalid
        /// conversion according to its native contract. Cancellation: not applicable.
        public func convert(
            _ point: CGPoint,
            from source: NSView?,
            to destination: NSView
        ) -> CGPoint {
            destination.convert(point, from: source)
        }
    }

    /// Adapter-owned native host for one logical Weave window.
    /// Ownership: the host owns the native window/controller and borrows the logical window.
    /// Isolation: MainActor. Errors: mounting an empty logical window returns `false`; repeated
    /// mount/unmount operations are idempotent. Cancellation: unmount detaches host callbacks.
    @MainActor
    public final class AppKitWindowHost: WindowHost {
        public let logicalWindow: Window
        public let nativeWindow: NSWindow
        public let coordinator: RenderCoordinator
        private let adapter: AppKitAdapter
        private var hostView: AppKitHostView?
        private var rootViewController: NSViewController?
        private var themeTask: Task<Void, Never>?

        /// Creates an idle native host. No native hierarchy is mounted until `mount()`.
        /// Ownership: the host retains the native window and borrows the logical window.
        /// Isolation: MainActor. Errors: none. Cancellation: no work starts during initialization.
        public init(
            window: Window,
            nativeWindow: NSWindow,
            adapter: AppKitAdapter = AppKitAdapter(),
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

            let controller = NSViewController()
            let container = NSView(frame: nativeWindow.contentView?.bounds ?? .zero)
            container.wantsLayer = true
            controller.view = container
            var lastPointer: CGPoint?
            var edgePullActive = false
            let host = adapter.makeHost(
                for: node,
                coordinator: coordinator,
                frame: container.bounds,
                inputHandler: { [weak node] input in
                    guard let node else { return }
                    switch input {
                    case let .mouseDown(point):
                        lastPointer = point
                        edgePullActive = false
                    case let .mouseDragged(point):
                        guard let previousPointer = lastPointer else { return }
                        let dy = Double(previousPointer.y - point.y)
                        if let edgePull = Self.findScrollNode(in: node) {
                            if edgePullActive {
                                edgePull.updateEdgePull(delta: dy)
                                lastPointer = point
                                return
                            }
                            if edgePull.beginEdgePull(for: dy) {
                                edgePullActive = true
                                edgePull.updateEdgePull(delta: dy)
                                lastPointer = point
                                return
                            }
                        }
                        if let scroll = Self.findScrollNode(in: node) {
                            _ = scroll.moveBy(x: 0, y: dy)
                        }
                        lastPointer = point
                    case .mouseUp:
                        if edgePullActive,
                            let edgePull = Self.findScrollNode(in: node)
                        {
                            edgePull.finishEdgePull()
                        }
                        edgePullActive = false
                        lastPointer = nil
                    case let .scroll(deltaX, deltaY):
                        if let scroll = Self.findScrollNode(in: node) {
                            _ = scroll.moveBy(x: -deltaX, y: -deltaY)
                        }
                    case .cancelled:
                        if edgePullActive,
                            let edgePull = Self.findScrollNode(in: node)
                        {
                            edgePull.cancelEdgePull()
                        }
                        edgePullActive = false
                        lastPointer = nil
                    default:
                        break
                    }
                },
                signalHandler: { [weak self] signal in
                    guard let self else { return }
                    switch signal {
                    case let .appearanceChanged(isDark):
                        self.applySystemColorScheme(isDark)
                    case let .safeAreaChanged(insets):
                        self.applySafeArea(insets)
                    default:
                        break
                    }
                }
            )
            host.autoresizingMask = [.width, .height]
            adapter.mount(host, in: container)
            nativeWindow.contentViewController = controller
            nativeWindow.makeKeyAndOrderFront(nil)
            rootViewController = controller
            hostView = host
            host.emitCurrentAppearance()
            host.emit(
                .safeAreaChanged(
                    PhysicalEdgeInsets(
                        top: host.safeAreaInsets.top, left: host.safeAreaInsets.left,
                        bottom: host.safeAreaInsets.bottom, right: host.safeAreaInsets.right
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

        /// Unmounts the native root while retaining the logical window for later remount.
        /// Ownership: native host callbacks and view hierarchy are released. Isolation: MainActor.
        /// Errors: repeated calls are no-ops. Cancellation: active input is interrupted by detach.
        public func unmount() {
            themeTask?.cancel()
            themeTask = nil
            coordinator.unmount()
            if let hostView { adapter.unmount(hostView) }
            hostView = nil
            rootViewController = nil
            nativeWindow.contentViewController = nil
            nativeWindow.orderOut(nil)
        }

        private func applySystemColorScheme(_ isDark: Bool?) {
            let scheme: ColorScheme
            switch isDark {
            case true: scheme = .dark
            case false: scheme = .light
            case nil: scheme = .unspecified
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
                self.coordinator.invalidate(
                    root: root,
                    bounds: LayoutFrame(
                        width: hostView.bounds.width,
                        height: hostView.bounds.height
                    ),
                    scale: 1
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
            coordinator.invalidate(
                root: root,
                bounds: LayoutFrame(
                    width: hostView.bounds.width,
                    height: hostView.bounds.height
                ),
                scale: Double(nativeWindow.backingScaleFactor)
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

    /// AppKit menu, toolbar and keyboard presenter for the shared command registry.
    /// Ownership: presenter weakly borrows the registry and owns native menu targets. Isolation: MainActor.
    /// Errors: unsupported command capabilities use registry fallback. Cancellation: dispose releases native targets.
    @MainActor
    public final class AppKitCommandPresenter: NSObject {
        private weak var registry: CommandRegistry?

        /// Creates a presenter. Ownership: registry is weakly borrowed. Isolation: MainActor. Errors: none. Cancellation: no work starts.
        public init(registry: CommandRegistry) {
            self.registry = registry
            super.init()
        }

        /// Builds menu items with native key equivalents. Ownership: returned menu items are caller-owned.
        /// Isolation: MainActor. Errors: missing commands are omitted. Cancellation: action tasks are caller-owned.
        public func makeMenuItems() -> [NSMenuItem] {
            registry?.definitions(capability: .menu).map { definition in
                let item = NSMenuItem(
                    title: definition.title.fallback,
                    action: #selector(performMenuItem(_:)),
                    keyEquivalent: definition.shortcut?.key ?? "")
                item.target = self
                if let shortcut = definition.shortcut {
                    item.keyEquivalentModifierMask = nativeModifiers(shortcut.modifiers)
                }
                item.representedObject = definition.id.rawValue
                item.isEnabled = true
                return item
            } ?? []
        }

        /// Builds toolbar items using command buttons. Ownership: returned items are caller-owned.
        /// Isolation: MainActor. Errors: missing commands are omitted. Cancellation: item actions stop after presenter deallocation.
        public func makeToolbarItems() -> [NSToolbarItem] {
            registry?.definitions(capability: .toolbar).map { definition in
                let item = NSToolbarItem(
                    itemIdentifier: NSToolbarItem.Identifier(definition.id.rawValue))
                item.label = definition.title.fallback
                let button = NSButton(
                    title: definition.title.fallback, target: self,
                    action: #selector(performToolbarItem(_:)))
                button.bezelStyle = .texturedRounded
                button.identifier = NSUserInterfaceItemIdentifier(definition.id.rawValue)
                item.view = button
                return item
            } ?? []
        }

        /// Dispatches a menu item through the active registry scope. Ownership: sender is borrowed.
        /// Isolation: MainActor. Errors: unavailable commands are ignored. Cancellation: registry action policy applies.
        @objc public func performMenuItem(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String else { return }
            Task { @MainActor in _ = await registry?.execute(CommandID(rawValue: raw)) }
        }

        /// Dispatches a toolbar item through the active registry scope. Ownership: sender is borrowed.
        /// Isolation: MainActor. Errors: unavailable commands are ignored. Cancellation: registry action policy applies.
        @objc public func performToolbarItem(_ sender: NSButton) {
            guard let raw = sender.identifier?.rawValue else { return }
            Task { @MainActor in _ = await registry?.execute(CommandID(rawValue: raw)) }
        }

        private func nativeModifiers(_ modifiers: CommandModifiers) -> NSEvent.ModifierFlags {
            var result: NSEvent.ModifierFlags = []
            if modifiers.contains(.command) { result.insert(.command) }
            if modifiers.contains(.shift) { result.insert(.shift) }
            if modifiers.contains(.option) { result.insert(.option) }
            if modifiers.contains(.control) { result.insert(.control) }
            return result
        }
    }

    /// AppKit drag and drop bridge translating native pasteboard sessions into Core transfer contracts.
    /// Ownership: the bridge coordinates session translation with TransferCoordinator. Isolation: MainActor.
    /// Errors: unreadable pasteboard payloads return typed transfer errors. Cancellation: cancelled sessions stop loading.
    @MainActor
    public final class AppKitTransferBridge: NSObject {
        private let coordinator: TransferCoordinator
        private let ownerID: TransferOwnerID

        /// Creates an AppKit transfer bridge.
        /// Ownership: coordinator is retained, ownerID is copied. Isolation: MainActor. Errors: none. Cancellation: no work starts.
        public init(coordinator: TransferCoordinator, ownerID: TransferOwnerID) {
            self.coordinator = coordinator
            self.ownerID = ownerID
            super.init()
        }

        /// Extracts transfer metadata from an AppKit pasteboard.
        /// Ownership: metadata is caller-owned. Isolation: MainActor. Errors: none. Cancellation: none.
        public func extractMetadata(from pasteboard: NSPasteboard) -> [TransferMetadata] {
            extractMetadata(from: pasteboard.pasteboardItems ?? [])
        }

        /// Converts pasteboard items into platform-neutral transfer metadata.
        /// Ownership: items are borrowed and metadata is caller-owned. Isolation: MainActor. Errors: none. Cancellation: none.
        internal func extractMetadata(from items: [NSPasteboardItem]) -> [TransferMetadata] {
            items.flatMap { item in
                item.types.map { type in
                    TransferMetadata(
                        contentType: type.rawValue,
                        size: item.data(forType: type)?.count,
                        suggestedName: item.string(forType: .string)
                    )
                }
            }
        }

        /// Evaluates a candidate drop on a transferable node.
        /// Ownership: parameters are borrowed. Isolation: MainActor. Errors: none. Cancellation: cancelled sessions produce empty operations.
        public func evaluateDrop(
            draggingInfo: NSDraggingInfo,
            node: any TransferableNode,
            kind: TransferSessionKind? = nil
        ) async -> NSDragOperation {
            let metadata = extractMetadata(from: draggingInfo.draggingPasteboard)
            guard !metadata.isEmpty else { return [] }

            let effectiveKind =
                kind ?? (draggingInfo.draggingSource != nil ? .internalReorder : .externalTransfer)
            let session = TransferSession(
                ownerID: ownerID,
                kind: effectiveKind,
                limits: TransferLimits(allowedTypes: Set(metadata.map(\.contentType)))
            )

            let proposal = await coordinator.proposeDrop(
                metadata: metadata,
                session: session,
                destinationOwner: ownerID,
                node: node
            )

            switch proposal {
            case .copy: return .copy
            case .move: return .move
            case .link: return .link
            case .forbidden: return []
            }
        }

        /// Performs the drop by loading pasteboard data and importing it into the destination node.
        /// Ownership: temporary data is released after import. Isolation: MainActor. Errors: failures are returned in outcome. Cancellation: respects session cancellation.
        public func performDrop(
            draggingInfo: NSDraggingInfo,
            node: any TransferableNode,
            kind: TransferSessionKind? = nil
        ) async -> TransferOutcome {
            let pasteboard = draggingInfo.draggingPasteboard
            guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
                return .rejected(.noRepresentation)
            }

            var transferItems: [TransferItem] = []
            var targetMetadata: [TransferMetadata] = []

            for item in items {
                var representations: [TransferRepresentation] = []
                for type in item.types {
                    let typeString = type.rawValue
                    if let data = item.data(forType: type) {
                        representations.append(
                            TransferRepresentation(
                                contentType: typeString,
                                size: data.count,
                                load: { data }
                            )
                        )
                        targetMetadata.append(
                            TransferMetadata(
                                contentType: typeString,
                                size: data.count,
                                suggestedName: item.string(forType: .string)
                            )
                        )
                    }
                }
                if !representations.isEmpty {
                    transferItems.append(TransferItem(representations: representations))
                }
            }

            guard !transferItems.isEmpty else {
                return .rejected(.noRepresentation)
            }

            let effectiveKind =
                kind ?? (draggingInfo.draggingSource != nil ? .internalReorder : .externalTransfer)
            let session = TransferSession(
                ownerID: ownerID,
                kind: effectiveKind,
                limits: TransferLimits(allowedTypes: Set(targetMetadata.map(\.contentType)))
            )

            return await coordinator.importItems(
                targetMetadata,
                from: transferItems,
                session: session,
                destinationOwner: ownerID,
                into: node
            )
        }
    }

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
        public func makeView(frame: NSRect = .zero) -> AVPlayerVideoView {
            let view = AVPlayerVideoView(frame: frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.cgColor
            view.layer?.frame = view.bounds
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

    /// AppKit rendering surface for an `AVPlayerVideoBackend`.
    /// Ownership: view borrows the player. Isolation: MainActor. Errors: unsupported rendering is delegated to AVPlayerLayer. Cancellation: removing the view stops presentation.
    @MainActor
    public final class AVPlayerVideoView: NSView {
        public var player: AVPlayer? {
            get { (layer as? AVPlayerLayer)?.player }
            set { (layer as? AVPlayerLayer)?.player = newValue }
        }

        override public func makeBackingLayer() -> CALayer {
            let layer = AVPlayerLayer()
            layer.videoGravity = .resizeAspect
            return layer
        }

        override public func layout() {
            super.layout()
            layer?.frame = bounds
            (layer as? AVPlayerLayer)?.videoGravity = .resizeAspect
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

    /// AppKit VoiceOver bridge consuming headless Weave snapshots.
    /// Ownership: the bridge retains only the latest snapshot. Isolation: MainActor. Errors: AppKit
    /// notification delivery is best effort. Cancellation: a newer snapshot replaces the old one.
    @MainActor
    public final class AppKitAccessibilityBridge: AccessibilityBridge {
        public private(set) var latestSnapshot: AccessibilitySnapshot?

        /// Creates an empty AppKit accessibility bridge.
        /// Ownership: no native elements are allocated. Isolation: MainActor. Errors: none. Cancellation: none.
        public init() {}

        /// Publishes a committed snapshot to AppKit accessibility.
        /// Ownership: the snapshot is copied. Isolation: MainActor. Errors: no thrown errors.
        /// Cancellation: superseded snapshots are replaced.
        public func apply(_ snapshot: AccessibilitySnapshot) {
            latestSnapshot = snapshot
            NSAccessibility.post(element: NSApplication.shared, notification: .layoutChanged)
        }
    }

    /// AppKit text-field bridge for an `EditableTextNode`.
    /// Ownership: bridge weakly references native field and node; caller owns both. Isolation: MainActor. Errors: native selection updates are clamped. Cancellation: detach stops delegate delivery.
    @MainActor
    public final class AppKitTextFieldBridge: NSObject, NSTextFieldDelegate, TextInputBridge {
        private weak var textField: NSTextField?
        private weak var node: EditableTextNode?
        private var applying = false

        /// Creates a bridge and installs the AppKit delegate. Ownership: bridge does not retain field or node. Isolation: MainActor. Errors: none. Cancellation: deinit releases delegate.
        public init(textField: NSTextField, node: EditableTextNode) {
            self.textField = textField
            self.node = node
            super.init()
            textField.delegate = self
        }

        /// Applies committed Core state to AppKit without creating a feedback edit.
        /// Ownership: state is borrowed. Isolation: MainActor. Errors: native values are clamped. Cancellation: none.
        public func apply(_ state: TextEditingState) {
            guard let textField else { return }
            applying = true
            textField.stringValue = state.text
            applying = false
        }

        /// Sends a typed action into Core. Ownership: action is copied. Isolation: MainActor. Errors: invalid edits are ignored. Cancellation: detached bridge drops the action.
        public func send(_ action: TextEditingAction) { _ = node?.apply(action) }

        /// Converts AppKit control changes into one typed replacement action. Ownership: notification is borrowed. Isolation: MainActor. Errors: invalid edits are ignored. Cancellation: delegate removal stops delivery.
        public func controlTextDidChange(_ obj: Notification) {
            guard !applying, let textField else { return }
            guard let node else { return }
            // AppKit notifications carry the complete control value. Replace the
            // previous committed value to avoid duplicating text at the caret.
            send(
                .replace(
                    range: TextRange(location: 0, length: node.editingState.text.count),
                    text: textField.stringValue))
        }

    }

    /// AppKit multiline text-view bridge. Return is handled by NSTextView and becomes a newline.
    /// Ownership: bridge borrows the native view and node. Isolation: MainActor. Errors: native ranges are clamped. Cancellation: delegate removal stops delivery.
    @MainActor
    public final class AppKitTextViewBridge: NSObject, NSTextViewDelegate, TextInputBridge {
        private weak var textView: NSTextView?
        private weak var node: EditableTextNode?
        private var applying = false

        /// Creates a bridge borrowing the text view and node. Ownership: caller owns both. Isolation: MainActor. Errors: none. Cancellation: delegate removal stops delivery.
        public init(textView: NSTextView, node: EditableTextNode) {
            self.textView = textView
            self.node = node
            super.init()
            textView.delegate = self
        }

        /// Applies Core state without feeding it back as an edit. Ownership: state is borrowed. Isolation: MainActor. Errors: ranges are clamped. Cancellation: none.
        public func apply(_ state: TextEditingState) {
            guard let textView else { return }
            applying = true
            textView.string = state.text
            textView.setSelectedRange(
                NSRange(location: state.selection.location, length: state.selection.length))
            applying = false
        }

        /// Sends one typed action to Core. Ownership: action is copied. Isolation: MainActor. Errors: invalid edits are ignored. Cancellation: detached bridge drops the action.
        public func send(_ action: TextEditingAction) { _ = node?.apply(action) }

        /// Converts native changes into one replacement and selection action. Ownership: notification is borrowed. Isolation: MainActor. Errors: invalid ranges are clamped. Cancellation: detached bridge stops delivery.
        public func textDidChange(_ notification: Notification) {
            guard !applying, let textView, let node else { return }
            send(
                .replace(
                    range: TextRange(location: 0, length: node.editingState.text.count),
                    text: textView.string))
            let selection = textView.selectedRange()
            send(.setSelection(TextRange(location: selection.location, length: selection.length)))
        }
    }

    /// AppKit haptics adapter for supported trackpad capabilities.
    /// Ownership: adapter owns no native session. Isolation: MainActor. Errors: unsupported hardware is a no-op. Cancellation: none.
    @MainActor
    public final class AppKitHapticsClient: HapticsClient {
        /// Creates an AppKit haptics adapter.
        /// Ownership: adapter owns no native session. Isolation: MainActor. Errors: none. Cancellation: none.
        public init() {}

        /// Plays one AppKit haptic intent.
        /// Ownership: intent is borrowed. Isolation: MainActor. Errors: unsupported hardware is ignored. Cancellation: none.
        public func play(_ feedback: HapticFeedback) {
            let performer = NSHapticFeedbackManager.defaultPerformer
            switch feedback {
            case .selection: performer.perform(.alignment, performanceTime: .now)
            case .impact: performer.perform(.generic, performanceTime: .now)
            case .notification: performer.perform(.levelChange, performanceTime: .now)
            }
        }
    }

    /// AppKit sound adapter using system beep for safe feedback.
    /// Ownership: adapter owns no audio resources. Isolation: MainActor. Errors: unavailable output is ignored. Cancellation: none.
    @MainActor
    public final class AppKitSoundClient: SoundClient {
        /// Creates an AppKit sound adapter.
        /// Ownership: adapter owns no audio resources. Isolation: MainActor. Errors: none. Cancellation: none.
        public init() {}
        /// Plays a safe system beep for the intent.
        /// Ownership: intent is borrowed. Isolation: MainActor. Errors: unavailable output is ignored. Cancellation: none.
        public func play(_ feedback: SoundFeedback) { NSSound.beep() }
    }
#endif
