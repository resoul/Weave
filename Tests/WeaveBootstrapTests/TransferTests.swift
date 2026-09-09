import Foundation
import Testing
import Weave

@MainActor
private final class TransferNodeStub: TransferableNode {
    var imported: [ImportedTransferItem] = []
    var proposal: DropProposal = .copy
    var exported: [TransferItem]

    init(exported: [TransferItem]) { self.exported = exported }

    func exportItems(for session: TransferSession) async throws -> [TransferItem] { exported }
    func canImport(_ metadata: [TransferMetadata]) async -> DropProposal { proposal }
    func importItems(_ items: [ImportedTransferItem]) async throws { imported = items }
}

@Test
@MainActor
func transferCoordinatorLoadsOnlyValidatedRepresentations() async throws {
    let node = TransferNodeStub(exported: [
        TransferItem(representations: [
            TransferRepresentation(contentType: "public.text", size: 5) { Data("hello".utf8) }
        ])
    ])
    let limits = TransferLimits(allowedTypes: ["public.text"], maxBytes: 16, maxItems: 2)
    let session = TransferSession(
        ownerID: TransferOwnerID("scene-a"), kind: .externalTransfer, limits: limits)
    let coordinator = TransferCoordinator()
    let metadata = [TransferMetadata(contentType: "public.text", size: 5)]

    #expect(
        await coordinator.proposeDrop(
            metadata: metadata, session: session, destinationOwner: TransferOwnerID("scene-a"),
            node: node
        ) == .copy)
    let result = await coordinator.importItems(
        metadata, from: node.exported, session: session,
        destinationOwner: TransferOwnerID("scene-a"), into: node)
    #expect(result == .imported(itemCount: 1, byteCount: 5))
    #expect(node.imported.first?.data == Data("hello".utf8))
}

@Test
@MainActor
func transferCoordinatorRejectsUnsupportedOversizedAndWrongOwnerDrops() async {
    let node = TransferNodeStub(exported: [])
    let limits = TransferLimits(allowedTypes: ["public.text"], maxBytes: 4, maxItems: 1)
    let session = TransferSession(
        ownerID: TransferOwnerID("scene-a"), kind: .externalTransfer, limits: limits)
    let coordinator = TransferCoordinator()

    #expect(
        await coordinator.proposeDrop(
            metadata: [TransferMetadata(contentType: "public.image", size: 1)],
            session: session, destinationOwner: TransferOwnerID("scene-a"), node: node
        ) == .forbidden)
    #expect(
        await coordinator.proposeDrop(
            metadata: [TransferMetadata(contentType: "public.text", size: 5)],
            session: session, destinationOwner: TransferOwnerID("scene-a"), node: node
        ) == .forbidden)
    #expect(
        await coordinator.proposeDrop(
            metadata: [], session: session, destinationOwner: TransferOwnerID("scene-b"), node: node
        ) == .forbidden)
}

@Test
@MainActor
func transferCancellationIsTerminalAndDoesNotDeliverLateImport() async {
    let node = TransferNodeStub(exported: [
        TransferItem(representations: [
            TransferRepresentation(contentType: "public.text") { Data("late".utf8) }
        ])
    ])
    let session = TransferSession(
        ownerID: TransferOwnerID("scene-a"), kind: .internalReorder,
        limits: TransferLimits(allowedTypes: ["public.text"], maxBytes: 32, maxItems: 1))
    let coordinator = TransferCoordinator()
    #expect(await coordinator.cancel(session))
    #expect(!(await coordinator.cancel(session)))
    let result = await coordinator.importItems(
        [TransferMetadata(contentType: "public.text")], from: node.exported, session: session,
        destinationOwner: TransferOwnerID("scene-a"), into: node)
    #expect(result == .cancelled)
    #expect(node.imported.isEmpty)
}
