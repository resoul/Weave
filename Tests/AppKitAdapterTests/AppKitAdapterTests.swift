#if canImport(AppKit)
    import AppKit
    import QuartzCore
    import Testing
    import Weave
    import WeaveAdapters
    @testable import AppKitAdapter

    @MainActor
    @Test
    func appKitAdapterMountIsIdempotent_andUnmountReleasesNodeHost() {
        let adapter = AppKitAdapter()
        let node = Node()
        let parent = NSView(frame: .zero)
        let host = adapter.makeHost(for: node)
        adapter.mount(host, in: parent)
        adapter.mount(host, in: parent)
        #expect(parent.subviews.count == 1)
        #expect(node.lifecycleState == .connected)
        adapter.unmount(host)
        #expect(parent.subviews.isEmpty)
    }

    @Test
    @MainActor
    func appKitWindowHostMountsAndUnmountsLogicalRoot() {
        let controller = Controller<Node, Never, Never>(node: Node())
        let logicalWindow = Window(rootController: controller)
        let nativeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = AppKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)

        #expect(host.mount())
        #expect(nativeWindow.contentViewController != nil)
        #expect(logicalWindow.rootController?.anyNode.lifecycleState == .connected)

        host.unmount()
        #expect(nativeWindow.contentViewController == nil)
    }

    @Test
    @MainActor
    func appKitHostEmitsResizeSignalWithBackingScale() {
        var signals: [AppKitPlatformSignal] = []
        let adapter = AppKitAdapter()
        let node = Node()
        let host = adapter.makeHost(for: node, frame: NSRect(x: 0, y: 0, width: 320, height: 240)) {
            _ in
        } signalHandler: { signal in
            signals.append(signal)
        }

        host.viewDidEndLiveResize()

        #expect(signals.count == 1)
        guard case let .resized(size, scale) = signals.first else {
            Issue.record("Expected a resized platform signal")
            return
        }
        #expect(size == CGSize(width: 320, height: 240))
        #expect(scale > 0)
    }

    private final class MockTransferNode: Node, TransferableNode {
        var importedItems: [ImportedTransferItem] = []
        var proposal: DropProposal = .copy

        func exportItems(for session: TransferSession) async throws -> [TransferItem] {
            []
        }

        func canImport(_ metadata: [TransferMetadata]) async -> DropProposal {
            proposal
        }

        func importItems(_ items: [ImportedTransferItem]) async throws {
            importedItems.append(contentsOf: items)
        }
    }

    @Test
    @MainActor
    func appKitTransferBridgeExtractsMetadataAndEvaluatesDropProposal() async {
        let coordinator = TransferCoordinator()
        let bridge = AppKitTransferBridge(
            coordinator: coordinator, ownerID: TransferOwnerID("test-window"))
        let item = NSPasteboardItem()
        #expect(item.setString("Hello Weave", forType: .string))

        let metadata = bridge.extractMetadata(from: [item])
        #expect(!metadata.isEmpty)
        #expect(
            metadata.contains(where: {
                $0.contentType == NSPasteboard.PasteboardType.string.rawValue
            }))

        let node = MockTransferNode()
        let session = TransferSession(
            ownerID: TransferOwnerID("test-window"),
            kind: .externalTransfer,
            limits: TransferLimits(allowedTypes: [NSPasteboard.PasteboardType.string.rawValue])
        )
        let proposal = await coordinator.proposeDrop(
            metadata: metadata,
            session: session,
            destinationOwner: TransferOwnerID("test-window"),
            node: node
        )
        #expect(proposal == .copy)
    }

    @Test
    @MainActor
    func appKitLayerRendererClipsAndOffsetsScrollNode() {
        let scroll = ScrollNode(axis: .vertical)
        let child = Node()
        scroll.addSubnode(child)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 200, height: 300),
            contentSize: MeasuredSize(width: 200, height: 800)
        )
        _ = scroll.moveBy(x: 0, y: 120)

        let placements = [
            LayoutPlacement(
                identity: scroll.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 200, height: 300)
            ),
            LayoutPlacement(
                identity: child.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 200, height: 50)
            ),
        ]
        let result = LayoutResult(
            placements: placements,
            treeIdentity: scroll.id,
            environmentRevision: 1,
            contentRevision: 1
        )

        let renderer = AppKitLayerRenderer(root: scroll)
        let hostLayer = CALayer()
        renderer.applyCommitted(result: result, on: hostLayer, scale: 2)

        guard let scrollLayer = hostLayer.sublayers?.first else {
            #expect(Bool(false), "scroll layer must exist")
            return
        }
        #expect(scrollLayer.masksToBounds == true)
        #expect(scrollLayer.bounds.origin == CGPoint(x: 0, y: 120))
    }

    @Test
    @MainActor
    func appKitWindowHostScrollWheelDeliversToScrollNode() {
        let scroll = ScrollNode(axis: .vertical)
        scroll.updateViewport(
            viewportSize: MeasuredSize(width: 200, height: 300),
            contentSize: MeasuredSize(width: 200, height: 800)
        )
        let controller = Controller<ScrollNode, Never, Never>(node: scroll)
        let logicalWindow = Window(rootController: controller)
        let nativeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = AppKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)
        #expect(host.mount())

        // Find the installed host view and emit scroll input
        guard
            let hostView = nativeWindow.contentView?.subviews.first(where: { $0 is AppKitHostView })
                as? AppKitHostView
        else {
            #expect(Bool(false), "AppKitHostView must be mounted")
            return
        }

        #if DEBUG
            hostView.emitInputForTesting(
                .scroll(point: CGPoint(x: 100, y: 100), deltaX: 0, deltaY: -45, phase: .began))
            #expect(scroll.state.offset.y == 45)
        #endif

        host.unmount()
    }

    /// Card 03: before this, `AppKitWindowHost` (like `UIKitWindowHost`) always routed a scroll
    /// to whichever `ScrollNode` a single whole-tree DFS from the root found first — never the
    /// one actually under the pointer. This builds a horizontal row nested in a vertical list and
    /// confirms a horizontal scroll at a point inside the row reaches the row, not the outer list.
    @MainActor
    private func makeNestedScrollFixture() -> (
        outer: ScrollNode, inner: ScrollNode, host: AppKitWindowHost, hostView: AppKitHostView?
    ) {
        let outer = ScrollNode(axis: .vertical)
        let inner = ScrollNode(axis: .horizontal)
        outer.addSubnode(inner)
        outer.updateViewport(
            viewportSize: MeasuredSize(width: 300, height: 300),
            contentSize: MeasuredSize(width: 300, height: 1000)
        )
        inner.updateViewport(
            viewportSize: MeasuredSize(width: 300, height: 100),
            contentSize: MeasuredSize(width: 1000, height: 100)
        )

        let controller = Controller<ScrollNode, Never, Never>(node: outer)
        let logicalWindow = Window(rootController: controller)
        let nativeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = AppKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)
        _ = host.mount()

        let placements = [
            LayoutPlacement(
                identity: outer.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 300)),
            LayoutPlacement(
                identity: inner.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
        ]
        outer.applyRecursively(
            LayoutResult(
                placements: placements, treeIdentity: outer.id, environmentRevision: 1,
                contentRevision: 1))

        let hostView =
            nativeWindow.contentView?.subviews.first(where: { $0 is AppKitHostView })
            as? AppKitHostView
        return (outer, inner, host, hostView)
    }

    @Test
    @MainActor
    func appKitWindowHostRoutesHorizontalScrollToNestedRowNotOuterList() {
        let (outer, inner, host, hostView) = makeNestedScrollFixture()
        guard let hostView else {
            #expect(Bool(false), "AppKitHostView must be mounted")
            return
        }

        #if DEBUG
            hostView.emitInputForTesting(
                .scroll(point: CGPoint(x: 50, y: 50), deltaX: -30, deltaY: 0, phase: .began))
            #expect(inner.state.offset.x == 30)
            #expect(outer.state.offset.y == 0)
        #endif

        host.unmount()
    }

    @Test
    @MainActor
    func appKitWindowHostRoutesVerticalScrollToOuterListOverNestedRow() {
        let (outer, inner, host, hostView) = makeNestedScrollFixture()
        guard let hostView else {
            #expect(Bool(false), "AppKitHostView must be mounted")
            return
        }

        #if DEBUG
            hostView.emitInputForTesting(
                .scroll(point: CGPoint(x: 50, y: 50), deltaX: 0, deltaY: -60, phase: .began))
            #expect(outer.state.offset.y == 60)
            #expect(inner.state.offset.x == 0)
        #endif

        host.unmount()
    }

    /// Regression for a real bug found running the card 08 demo app: `scrollCandidates`'s
    /// fallback to a naive whole-tree `findScrollNode` — meant only for gestures arriving before
    /// the very first layout pass — was firing for *any* point with no `ScrollNode` ancestor, even
    /// after real layout. A click on non-scrollable chrome (a tab bar, here a plain sibling above
    /// a real scrollable list) would silently claim and move an unrelated scroll node elsewhere in
    /// the tree, and — worse, in the real UIKit path this mirrors — cancel a pending control press
    /// on the very thing the user clicked. This asserts a drag starting outside every ScrollNode,
    /// after a real layout pass, moves nothing.
    @Test
    @MainActor
    func appKitWindowHostDoesNotStealScrollForPointOutsideAnyScrollNodeAfterRealLayout() {
        let chrome = Node().style {
            $0.width = .fraction(1)
            $0.height = .points(60)
        }
        let list = ScrollNode(axis: .vertical)
        list.updateViewport(
            viewportSize: MeasuredSize(width: 300, height: 240),
            contentSize: MeasuredSize(width: 300, height: 2000)
        )
        let root = Node().style {
            $0.flexDirection = .column
            $0.width = .fraction(1)
            $0.height = .fraction(1)
        }
        root.addSubnode(chrome)
        root.addSubnode(list)

        let controller = Controller<Node, Never, Never>(node: root)
        let logicalWindow = Window(rootController: controller)
        let nativeWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let host = AppKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)
        #expect(host.mount())

        let placements = [
            LayoutPlacement(
                identity: root.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 300)),
            LayoutPlacement(
                identity: chrome.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 60)),
            LayoutPlacement(
                identity: list.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 60), width: 300, height: 240)),
        ]
        root.applyRecursively(
            LayoutResult(
                placements: placements, treeIdentity: root.id, environmentRevision: 1,
                contentRevision: 1))

        guard
            let hostView = nativeWindow.contentView?.subviews.first(where: { $0 is AppKitHostView }
            ) as? AppKitHostView
        else {
            #expect(Bool(false), "AppKitHostView must be mounted")
            return
        }

        #if DEBUG
            // A click-drag squarely inside `chrome` (y: 0..<60), well outside `list` (y: 60..<300).
            hostView.emitInputForTesting(.mouseDown(point: CGPoint(x: 50, y: 30)))
            hostView.emitInputForTesting(.mouseDragged(point: CGPoint(x: 50, y: 10)))
            hostView.emitInputForTesting(.mouseUp(point: CGPoint(x: 50, y: 10)))
            #expect(list.state.offset == LayoutPoint(x: 0, y: 0))
        #endif

        host.unmount()
    }

    @Test
    @MainActor
    func appKitVisualStyleAppliesAndResetsLayerPresentation() {
        let layer = CALayer()
        let color = ThemeColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.8)
        applyVisualStyle(
            VisualStyle(
                background: .color(color),
                border: Border(color: .init(red: 1, green: 1, blue: 1), width: 2),
                cornerRadius: 12,
                shadow: Shadow(
                    color: .init(red: 0, green: 0, blue: 0),
                    opacity: 0.25,
                    radius: 6,
                    offset: LayoutPoint(x: 0, y: 3)
                )
            ),
            to: layer
        )

        #expect(layer.backgroundColor != nil)
        #expect(layer.borderWidth == 2)
        #expect(layer.cornerRadius == 12)
        #expect(layer.shadowOpacity == 0.25)

        applyVisualStyle(VisualStyle(), to: layer)

        #expect(layer.backgroundColor == nil)
        #expect(layer.borderColor == nil)
        #expect(layer.borderWidth == 0)
        #expect(layer.shadowOpacity == 0)
        #expect(layer.shadowRadius == 0)
        #expect(layer.shadowOffset == .zero)
    }
#endif
