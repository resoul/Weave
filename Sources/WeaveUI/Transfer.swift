import Foundation

/// Identifies one platform drag or drop session.
/// Ownership: the value is copied by the session owner. Isolation: none. Errors: none. Cancellation: the session may be cancelled by its owner.
public struct TransferSessionID: Sendable, Hashable {
    public let rawValue: UUID

    /// Creates a transfer session identity.
    /// Ownership: the UUID is copied. Isolation: none. Errors: none. Cancellation: none.
    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identifies the scene or window that owns a transfer session.
/// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: none.
public struct TransferOwnerID: Sendable, Hashable {
    public let rawValue: String

    /// Creates an owner identity.
    /// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: none.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Distinguishes framework reorder gestures from a transfer to another owner.
/// Ownership: the value is copied. Isolation: none. Errors: none. Cancellation: none.
public enum TransferSessionKind: Sendable, Hashable {
    case internalReorder
    case externalTransfer
}

/// Limits applied before a transfer representation is loaded.
/// Ownership: the value owns its type set. Isolation: none. Errors: invalid limits are rejected at initialization. Cancellation: limits bound work.
public struct TransferLimits: Sendable, Hashable {
    public let allowedTypes: Set<String>
    public let maxBytes: Int
    public let maxItems: Int

    /// Creates bounded transfer limits.
    /// Ownership: the type set is copied. Isolation: none. Errors: non-positive limits trap as a programmer error. Cancellation: limits bound work.
    public init(allowedTypes: Set<String>, maxBytes: Int = 10 * 1024 * 1024, maxItems: Int = 32) {
        precondition(maxBytes > 0, "maxBytes must be positive")
        precondition(maxItems > 0, "maxItems must be positive")
        self.allowedTypes = allowedTypes
        self.maxBytes = maxBytes
        self.maxItems = maxItems
    }

    /// Default conservative limits for application transfers.
    /// Ownership: the value is copied. Isolation: none. Errors: none. Cancellation: limits bound work.
    public static let `default` = TransferLimits(allowedTypes: [])
}

/// Lazily loadable, platform-neutral transfer data.
/// Ownership: the loader is retained by the representation. Isolation: the loader is Sendable and may run off MainActor. Errors: the loader may throw. Cancellation: the loader should observe task cancellation.
public struct TransferRepresentation: Sendable {
    public let contentType: String
    public let size: Int?
    public let load: @Sendable () async throws -> Data

    /// Creates a lazy representation using an application content-type identifier.
    /// Ownership: the closure is retained. Isolation: the closure is Sendable. Errors: loading may throw. Cancellation: loading should observe cancellation.
    public init(
        contentType: String,
        size: Int? = nil,
        load: @escaping @Sendable () async throws -> Data
    ) {
        self.contentType = contentType
        self.size = size
        self.load = load
    }
}

/// An item exported by a transferable node.
/// Ownership: representations are retained by the item. Isolation: the value is Sendable. Errors: loading is deferred. Cancellation: each representation loader is cancellable.
public struct TransferItem: Sendable {
    public let representations: [TransferRepresentation]
    public let suggestedName: String?

    /// Creates an item with ordered fallback representations.
    /// Ownership: the array and name are copied. Isolation: none. Errors: an empty representation list is rejected when a session starts. Cancellation: loading is deferred.
    public init(representations: [TransferRepresentation], suggestedName: String? = nil) {
        self.representations = representations
        self.suggestedName = suggestedName
    }
}

/// Metadata received before a drop payload is loaded.
/// Ownership: all fields are copied. Isolation: none. Errors: metadata is validated against session limits. Cancellation: validation does not load data.
public struct TransferMetadata: Sendable, Hashable {
    public let contentType: String
    public let size: Int?
    public let suggestedName: String?

    /// Creates metadata for a candidate representation.
    /// Ownership: values are copied. Isolation: none. Errors: malformed sizes are rejected by the coordinator. Cancellation: validation is immediate.
    public init(contentType: String, size: Int? = nil, suggestedName: String? = nil) {
        self.contentType = contentType
        self.size = size
        self.suggestedName = suggestedName
    }
}

/// A validated payload passed to a node import operation.
/// Ownership: the value owns its data. Isolation: none. Errors: data has already passed session validation. Cancellation: import is cancelled by the owning session.
public struct ImportedTransferItem: Sendable {
    public let metadata: TransferMetadata
    public let data: Data

    /// Creates an imported payload.
    /// Ownership: data is copied. Isolation: none. Errors: none. Cancellation: the import operation may still be cancelled.
    public init(metadata: TransferMetadata, data: Data) {
        self.metadata = metadata
        self.data = data
    }
}

/// The destination's decision for a candidate drop.
/// Ownership: the value is copied. Isolation: none. Errors: forbidden describes a typed rejection. Cancellation: a cancelled session cannot propose a drop.
public enum DropProposal: Sendable, Hashable {
    case copy
    case move
    case link
    case forbidden
}

/// Typed transfer failures exposed to adapters and application code.
/// Ownership: associated values are copied. Isolation: none. Errors: each case identifies the rejected operation. Cancellation: cancelled is terminal for a session.
public enum TransferError: Error, Sendable, Hashable, Equatable {
    case unsupportedType(String)
    case itemTooLarge(Int)
    case tooManyItems(Int)
    case ownerMismatch
    case noRepresentation
    case cancelled
    case alreadyFinished
    case invalidPayload
    case loaderFailed(String)
}

/// Result of a completed or rejected drop operation.
/// Ownership: associated values are copied. Isolation: none. Errors: failures are represented explicitly. Cancellation: cancelled is terminal.
public enum TransferOutcome: Sendable, Hashable {
    case imported(itemCount: Int, byteCount: Int)
    case rejected(TransferError)
    case cancelled
    case failed(TransferError)
}

/// A node that participates in platform drag and drop without importing native item-provider types.
/// Ownership: the coordinator borrows the node during each MainActor call. Isolation: all methods run on MainActor. Errors: export/import may throw. Cancellation: the session is checked before and during each operation.
@MainActor
public protocol TransferableNode: AnyObject {
    /// Produces lazy representations for an export session.
    /// Ownership: returned items are owned by the coordinator. Isolation: MainActor entry, loaders may run elsewhere. Errors: export may throw. Cancellation: the session may be cancelled while producing items.
    func exportItems(for session: TransferSession) async throws -> [TransferItem]

    /// Chooses whether metadata can be accepted.
    /// Ownership: metadata is borrowed for the call. Isolation: MainActor. Errors: return `.forbidden` for an unsupported payload. Cancellation: a cancelled session is not proposed.
    func canImport(_ metadata: [TransferMetadata]) async -> DropProposal

    /// Consumes already validated payloads.
    /// Ownership: items are borrowed for the call. Isolation: MainActor. Errors: import may throw. Cancellation: the session is cancelled before a late import is delivered.
    func importItems(_ items: [ImportedTransferItem]) async throws
}

/// Actor-isolated state for one owner-scoped transfer.
/// Ownership: the session owns its lifecycle state. Isolation: actor isolation. Errors: terminal operations report `alreadyFinished`. Cancellation: `cancel()` is idempotent and terminal.
public actor TransferSession {
    public nonisolated let id: TransferSessionID
    public nonisolated let ownerID: TransferOwnerID
    public nonisolated let kind: TransferSessionKind
    public nonisolated let limits: TransferLimits

    private enum State { case active, cancelled, finished }
    private var state: State = .active

    /// Creates an owner-scoped transfer session.
    /// Ownership: the session retains immutable limits. Isolation: actor isolated state. Errors: none. Cancellation: the session starts active.
    public init(
        id: TransferSessionID = TransferSessionID(),
        ownerID: TransferOwnerID,
        kind: TransferSessionKind,
        limits: TransferLimits
    ) {
        self.id = id
        self.ownerID = ownerID
        self.kind = kind
        self.limits = limits
    }

    /// Returns whether the session can receive more work.
    /// Ownership: no state escapes. Isolation: actor. Errors: none. Cancellation: false after cancellation or completion.
    public func isActive() -> Bool { state == .active }

    /// Cancels the session once.
    /// Ownership: no value escapes. Isolation: actor. Errors: none. Cancellation: repeated calls are harmless and return false.
    @discardableResult
    public func cancel() -> Bool {
        guard state == .active else { return false }
        state = .cancelled
        return true
    }

    /// Finishes the session once after a successful drop.
    /// Ownership: no value escapes. Isolation: actor. Errors: none. Cancellation: returns false for cancelled or finished sessions.
    @discardableResult
    public func finish() -> Bool {
        guard state == .active else { return false }
        state = .finished
        return true
    }
}

/// MainActor coordinator used by adapters to translate native drag sessions into Core contracts.
/// Ownership: the coordinator owns no nodes and retains active sessions only for the operation. Isolation: MainActor. Errors: typed outcomes are returned. Cancellation: cancel/drop are terminal and idempotent.
@MainActor
public final class TransferCoordinator {
    /// Creates a transfer coordinator.
    /// Ownership: no graph is retained. Isolation: MainActor. Errors: none. Cancellation: each session controls its own lifetime.
    public init() {}

    /// Exports lazy items after enforcing owner and size-count limits.
    /// Ownership: returned representations are retained by the caller. Isolation: MainActor. Errors: typed transfer errors. Cancellation: cancellation is checked before and after export.
    public func exportItems(
        from node: any TransferableNode,
        session: TransferSession
    ) async throws -> [TransferItem] {
        guard await session.isActive() else { throw TransferError.cancelled }
        let items = try await node.exportItems(for: session)
        guard await session.isActive() else { throw TransferError.cancelled }
        guard items.count <= session.limits.maxItems else {
            throw TransferError.tooManyItems(items.count)
        }
        for item in items {
            guard !item.representations.isEmpty else { throw TransferError.noRepresentation }
            for representation in item.representations {
                try validate(
                    representation.contentType, size: representation.size, limits: session.limits)
            }
        }
        return items
    }

    /// Proposes a drop without loading payload bytes.
    /// Ownership: metadata is borrowed for validation. Isolation: MainActor. Errors: rejection is returned as `.forbidden`. Cancellation: a cancelled session is rejected.
    public func proposeDrop(
        metadata: [TransferMetadata],
        session: TransferSession,
        destinationOwner: TransferOwnerID,
        node: any TransferableNode
    ) async -> DropProposal {
        guard destinationOwner == session.ownerID else { return .forbidden }
        guard await session.isActive() else { return .forbidden }
        guard metadata.count <= session.limits.maxItems else { return .forbidden }
        do {
            for item in metadata {
                try validate(item.contentType, size: item.size, limits: session.limits)
            }
        } catch {
            return .forbidden
        }
        return await node.canImport(metadata)
    }

    /// Loads and imports a selected representation, bounded by session limits.
    /// Ownership: temporary payload data is released when the call returns. Isolation: MainActor orchestration with Sendable loaders. Errors: failures become typed outcomes. Cancellation: cancellation prevents late delivery and is terminal.
    public func importItems(
        _ metadata: [TransferMetadata],
        from exported: [TransferItem],
        session: TransferSession,
        destinationOwner: TransferOwnerID,
        into node: any TransferableNode
    ) async -> TransferOutcome {
        guard destinationOwner == session.ownerID else { return .rejected(.ownerMismatch) }
        guard metadata.count == exported.count else { return .rejected(.invalidPayload) }
        guard await session.isActive() else { return .cancelled }
        guard metadata.count <= session.limits.maxItems else {
            return .rejected(.tooManyItems(metadata.count))
        }

        var imported: [ImportedTransferItem] = []
        var byteCount = 0
        do {
            for (metadata, item) in zip(metadata, exported) {
                try validate(metadata.contentType, size: metadata.size, limits: session.limits)
                guard
                    let representation = item.representations.first(where: {
                        $0.contentType == metadata.contentType
                    })
                else {
                    throw TransferError.noRepresentation
                }
                let data = try await representation.load()
                guard await session.isActive() else { return .cancelled }
                byteCount += data.count
                guard byteCount <= session.limits.maxBytes else {
                    throw TransferError.itemTooLarge(byteCount)
                }
                imported.append(ImportedTransferItem(metadata: metadata, data: data))
            }
            guard await session.isActive(), await session.finish() else { return .cancelled }
            try await node.importItems(imported)
            return .imported(itemCount: imported.count, byteCount: byteCount)
        } catch let error as TransferError {
            if error == .cancelled { return .cancelled }
            _ = await session.cancel()
            return .failed(error)
        } catch is CancellationError {
            _ = await session.cancel()
            return .cancelled
        } catch {
            _ = await session.cancel()
            return .failed(.loaderFailed(String(describing: error)))
        }
    }

    /// Cancels a session and releases any temporary transfer ownership.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: repeated cancellation is harmless.
    @discardableResult
    public func cancel(_ session: TransferSession) async -> Bool {
        await session.cancel()
    }

    private func validate(_ contentType: String, size: Int?, limits: TransferLimits) throws {
        if !limits.allowedTypes.isEmpty && !limits.allowedTypes.contains(contentType) {
            throw TransferError.unsupportedType(contentType)
        }
        if let size, size < 0 { throw TransferError.invalidPayload }
        if let size, size > limits.maxBytes { throw TransferError.itemTooLarge(size) }
    }
}
