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
            hostView.emitInputForTesting(.scroll(deltaX: 0, deltaY: -45))
            #expect(scroll.state.offset.y == 45)
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
