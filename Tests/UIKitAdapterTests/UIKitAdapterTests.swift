import Testing

#if canImport(UIKit)
    import UIKit
    import Weave
    @testable import UIKitAdapter

    @Test
    func uikitAdapterTargetCompilesAcrossThePackageMatrix() {
        #expect(Bool(true))
    }

    @Test
    @MainActor
    func uiKitHostEmitsTypedInterruptionSignal() {
        var signals: [UIKitPlatformSignal] = []
        let adapter = UIKitAdapter()
        let host = adapter.makeHost(
            for: Node(),
            signalHandler: { signal in signals.append(signal) }
        )

        host.willMove(toWindow: nil)

        #expect(signals == [.inputInterrupted])
    }

    @Test
    @MainActor
    func uiKitInputHarnessPreservesOrderingAndCancellation() {
        var inputs: [UIKitInput] = []
        let host = UIKitAdapter().makeHost(
            for: Node(),
            inputHandler: { input in inputs.append(input) }
        )

        #if DEBUG
            host.emitInputForTesting(.touchDown(point: CGPoint(x: 2, y: 3)))
            host.emitInputForTesting(.touchMoved(point: CGPoint(x: 4, y: 5)))
            host.emitInputForTesting(.touchUp(point: CGPoint(x: 4, y: 5)))
            host.emitInputForTesting(.cancelled)
        #endif

        let expected: [UIKitInput] = [
            .touchDown(point: CGPoint(x: 2, y: 3)),
            .touchMoved(point: CGPoint(x: 4, y: 5)),
            .touchUp(point: CGPoint(x: 4, y: 5)),
            .cancelled,
        ]
        #expect(inputs == expected)
    }

    @Test
    @MainActor
    func uiKitWindowHostRejectsEmptyLogicalWindow() {
        let logicalWindow = Window()
        let nativeWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let host = UIKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)

        #expect(!host.mount())
        host.unmount()
        #expect(nativeWindow.rootViewController == nil)
    }

    #if os(iOS)
        private final class MockUIKitTransferNode: Node, TransferableNode {
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
        func uiKitTransferBridgeInitializesAndTranslatesProposal() async {
            let coordinator = TransferCoordinator()
            let bridge = UIKitAdapter.UIKitTransferBridge(
                coordinator: coordinator,
                ownerID: TransferOwnerID("test-window")
            )
            let node = MockUIKitTransferNode()
            bridge.setDestinationNode(node)

            let session = TransferSession(
                ownerID: TransferOwnerID("test-window"),
                kind: .externalTransfer,
                limits: TransferLimits(allowedTypes: ["public.text"])
            )
            let metadata = [TransferMetadata(contentType: "public.text")]
            let proposal = await coordinator.proposeDrop(
                metadata: metadata,
                session: session,
                destinationOwner: TransferOwnerID("test-window"),
                node: node
            )
            #expect(proposal == .copy)
        }
    #endif
#else
    @Test
    func uikitAdapterTargetCompilesAcrossThePackageMatrix() {
        #expect(Bool(true))
    }
#endif
