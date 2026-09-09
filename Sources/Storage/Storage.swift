import Foundation
import Security
public import Flux

/// A mutation emitted by a store. Values are immutable snapshots; the stream is bounded.
/// Ownership: the value owns copied key data. Isolation: none. Errors: none. Cancellation: not applicable.
public struct StoreChange: Sendable, Equatable {
    /// The mutation kind. Ownership: copied value. Isolation: none. Errors: none. Cancellation: not applicable.
    public enum Operation: Sendable, Equatable { case set, remove, removeAll }
    /// The changed logical key, or nil for namespace-wide removal.
    /// Ownership: immutable copied value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let key: String?
    /// The operation applied to the store.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public let operation: Operation

    /// Creates a change snapshot. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(key: String?, operation: Operation) {
        self.key = key
        self.operation = operation
    }
}

/// Actor-compatible asynchronous persistence contract.
/// Ownership: implementations own their storage. Isolation: operations are async and implementation-defined. Errors: methods throw storage failures. Cancellation: task cancellation propagates.
public protocol Store: Sendable {
    /// Bounded mutation stream. Ownership: caller owns iteration. Isolation: sendable stream. Errors: none. Cancellation: cancelling iteration stops observation.
    var changes: AsyncStream<StoreChange> { get }
    /// Loads a value; missing keys return nil. Ownership: decoded value is returned to caller. Isolation: async. Errors: decode/storage failures. Cancellation: propagates.
    func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T?
    /// Stores a Codable value. Ownership: value is encoded before return. Isolation: async. Errors: encode/storage failures. Cancellation: propagates.
    func set<T: Codable & Sendable>(_ key: String, value: T) async throws
    /// Removes one key. Ownership: store owns removal. Isolation: async. Errors: storage failures. Cancellation: propagates.
    func remove(_ key: String) async throws
    /// Removes only this store's namespace. Ownership: store-owned. Isolation: async. Errors: storage failures. Cancellation: propagates.
    func removeAll() async throws
}

/// Typed persistence failures. Ownership: immutable value. Isolation: none. Errors: this is the error surface. Cancellation: task cancellation remains separate.
public enum StorageError: Error, Sendable, Equatable {
    case invalidKey
    case invalidConfiguration(String)
    case encodingFailed
    case decodingFailed
    case corruptData
    case itemTooLarge
}

private actor StoreChangeCenter {
    static let shared = StoreChangeCenter()
    private var sinks:
        [UUID: (scope: String, continuation: AsyncStream<StoreChange>.Continuation)] = [:]

    nonisolated static func makeStream(scope: String) -> AsyncStream<StoreChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let id = UUID()
            Task {
                await StoreChangeCenter.shared.register(
                    id: id, scope: scope, continuation: continuation)
            }
            continuation.onTermination = { @Sendable _ in
                Task { await StoreChangeCenter.shared.remove(id) }
            }
        }
    }

    func publish(scope: String, change: StoreChange) {
        for sink in sinks.values where sink.scope == scope { _ = sink.continuation.yield(change) }
    }

    private func register(
        id: UUID, scope: String, continuation: AsyncStream<StoreChange>.Continuation
    ) {
        sinks[id] = (scope, continuation)
    }

    private func remove(_ id: UUID) { sinks.removeValue(forKey: id) }
}

/// Typed Keychain failure preserving the OSStatus category without exposing credentials.
/// Ownership: immutable diagnostic value. Isolation: none. Errors: this is the Keychain error surface. Cancellation: task cancellation remains separate.
public enum KeychainError: Error, Sendable, Equatable {
    case missing
    case accessDenied
    case duplicate
    case corruptValue
    case unexpectedStatus(Int32)
}

protocol KeychainBackend: Sendable {
    func read(service: String, account: String, accessGroup: String?) -> (Int32, Data?)
    func add(service: String, account: String, accessGroup: String?, data: Data) -> Int32
    func update(service: String, account: String, accessGroup: String?, data: Data) -> Int32
    func delete(service: String, account: String, accessGroup: String?) -> Int32
    func deleteAll(service: String, accessGroup: String?) -> Int32
}

private struct SecurityKeychainBackend: KeychainBackend {
    func read(service: String, account: String, accessGroup: String?) -> (Int32, Data?) {
        var query = baseQuery(service: service, accessGroup: accessGroup)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func add(service: String, account: String, accessGroup: String?, data: Data) -> Int32 {
        var query = baseQuery(service: service, accessGroup: accessGroup)
        query[kSecAttrAccount as String] = account
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(service: String, account: String, accessGroup: String?, data: Data) -> Int32 {
        var query = baseQuery(service: service, accessGroup: accessGroup)
        query[kSecAttrAccount as String] = account
        return SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    }

    func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        var query = baseQuery(service: service, accessGroup: accessGroup)
        query[kSecAttrAccount as String] = account
        return SecItemDelete(query as CFDictionary)
    }

    func deleteAll(service: String, accessGroup: String?) -> Int32 {
        SecItemDelete(baseQuery(service: service, accessGroup: accessGroup) as CFDictionary)
    }

    private func baseQuery(service: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

/// Actor-isolated Keychain implementation of Store.
/// Ownership: the actor owns service and backend references; credentials never enter logs or change snapshots. Isolation: actor. Errors: KeychainError and serialization failures. Cancellation: cancelled operations do not publish changes.
public actor KeychainStore: Store {
    private let service: String
    private let accessGroup: String?
    private let backend: any KeychainBackend
    private let continuation: AsyncStream<StoreChange>.Continuation
    public nonisolated let changes: AsyncStream<StoreChange>

    /// Creates a system Security-backed store. Ownership: service/accessGroup are copied. Isolation: actor. Errors: malformed values surface during operations. Cancellation: no I/O starts during init.
    public init(service: String, accessGroup: String? = nil) {
        self.init(service: service, accessGroup: accessGroup, backend: SecurityKeychainBackend())
    }

    internal init(service: String, accessGroup: String? = nil, backend: any KeychainBackend) {
        self.service = service
        self.accessGroup = accessGroup
        self.backend = backend
        let pair = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.changes = pair.stream
        self.continuation = pair.continuation
    }

    /// Loads and decodes a Keychain value. Ownership: decoded value is caller-owned. Isolation: actor. Errors: missing returns nil; status and decode failures throw. Cancellation: propagates.
    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T? {
        let (status, data) = backend.read(service: service, account: key, accessGroup: accessGroup)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess, let data else { throw map(status) }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw KeychainError.corruptValue
        }
    }

    /// Encodes and inserts or updates a Keychain value. Ownership: bytes are copied by Security. Isolation: actor. Errors: status and encoding failures throw. Cancellation: propagates.
    public func set<T: Codable & Sendable>(_ key: String, value: T) async throws {
        let data: Data
        do { data = try JSONEncoder().encode(value) } catch { throw StorageError.encodingFailed }
        let added = backend.add(
            service: service, account: key, accessGroup: accessGroup, data: data)
        let status =
            added == errSecDuplicateItem
            ? backend.update(service: service, account: key, accessGroup: accessGroup, data: data)
            : added
        guard status == errSecSuccess else { throw map(status) }
        continuation.yield(StoreChange(key: key, operation: .set))
    }

    /// Removes one Keychain value. Ownership: backend owns deletion. Isolation: actor. Errors: missing is idempotent; other status failures throw. Cancellation: propagates.
    public func remove(_ key: String) async throws {
        let status = backend.delete(service: service, account: key, accessGroup: accessGroup)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
        continuation.yield(StoreChange(key: key, operation: .remove))
    }

    /// Removes only entries matching this service and access group. Ownership: backend owns deletion. Isolation: actor. Errors: missing namespace is successful. Cancellation: propagates.
    public func removeAll() async throws {
        let status = backend.deleteAll(service: service, accessGroup: accessGroup)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
        continuation.yield(StoreChange(key: nil, operation: .removeAll))
    }

    private func map(_ status: Int32) -> KeychainError {
        switch status {
        case errSecItemNotFound: return .missing
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecMissingEntitlement:
            return .accessDenied
        case errSecDuplicateItem: return .duplicate
        default: return .unexpectedStatus(status)
        }
    }
}

/// Errors reported by a persisted handle and its explicit schema boundary.
/// Ownership: immutable diagnostic value. Isolation: none. Errors: this is the observable error surface. Cancellation: task cancellation remains separate.
public enum PersistedError: Error, Sendable, Equatable {
    case schemaMismatch(expected: Int, found: Int)
    case persistence(String)
    case disposed
}

/// Async observable persistence handle. It has no synchronous property wrapper semantics.
/// Ownership: the handle owns its key/default/schema dependencies and an optional observation task. Isolation: actor. Errors: load/set throw and are also emitted on `errors`. Cancellation: dispose cancels observation and pending writes.
public protocol PersistedValue: Sendable {
    associatedtype Value: Codable & Sendable & Equatable
    var changes: Flux<Value> { get }
    var errors: Flux<PersistedError> { get }
    func start() async
    func load() async throws -> Value
    func set(_ value: Value) async throws
    func dispose() async
}

/// Actor-owned persisted value with ordered writes and explicit observation lifecycle.
/// Ownership: the handle owns its current snapshot and tasks; Store remains caller-owned. Isolation: actor. Errors: persistence and schema failures are typed. Cancellation: `dispose` terminates owned work.
public actor Persisted<Value: Codable & Sendable & Equatable>: PersistedValue {
    private struct Envelope: Codable, Sendable {
        let schemaVersion: Int
        let value: Value
    }

    private let store: any Store
    private let key: String
    private let defaultValue: Value
    private let schemaVersion: Int
    private let state: CurrentValueDistinct<Value>
    private let errorPipe = Pipe<PersistedError>(bufferingPolicy: .bufferingNewest(64))
    private var observationTask: Task<Void, Never>?
    private var writeTail: Task<Void, Error>?
    private var writeGeneration: UInt64 = 0
    private var isDisposed = false

    /// Creates a handle without reading or writing storage. Ownership: dependencies are retained by the actor. Isolation: actor. Errors: invalid schema versions normalize to one. Cancellation: no task starts during init.
    public init(
        key: String,
        defaultValue: Value,
        store: any Store,
        schemaVersion: Int = 1
    ) {
        self.key = key
        self.defaultValue = defaultValue
        self.store = store
        self.schemaVersion = max(1, schemaVersion)
        self.state = CurrentValueDistinct(defaultValue)
    }

    /// Replayed current value plus distinct committed updates. Ownership: subscriber owns its subscription. Isolation: Flux stream is sendable. Errors: none. Cancellation: subscription cancellation is independent.
    public nonisolated var changes: Flux<Value> { state.flux }

    /// Bounded persistence error stream. Ownership: subscriber owns its subscription. Isolation: Flux stream is sendable. Errors: emits typed failures. Cancellation: subscription cancellation is independent.
    public nonisolated var errors: Flux<PersistedError> { errorPipe.flux }

    /// Starts observation explicitly; repeated calls do not create duplicate subscriptions.
    /// Ownership: actor owns the observation task. Isolation: actor. Errors: refresh failures are emitted on `errors`. Cancellation: task is cancelled by `dispose`.
    public func start() async {
        guard observationTask == nil, !isDisposed else { return }
        let store = self.store
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await change in store.changes {
                guard !Task.isCancelled else { return }
                await self.consume(change)
            }
        }
    }

    /// Loads the envelope or returns the configured default for a missing key.
    /// Ownership: returned value is caller-owned and committed to the state stream. Isolation: actor. Errors: schema/store failures throw and emit. Cancellation: propagates.
    public func load() async throws -> Value {
        guard !isDisposed else { throw PersistedError.disposed }
        do {
            guard let envelope = try await store.get(key, as: Envelope.self) else {
                await state.set(defaultValue)
                return defaultValue
            }
            guard envelope.schemaVersion == schemaVersion else {
                throw PersistedError.schemaMismatch(
                    expected: schemaVersion, found: envelope.schemaVersion)
            }
            await state.set(envelope.value)
            return envelope.value
        } catch let error as PersistedError {
            errorPipe.send(error)
            throw error
        } catch {
            let failure = PersistedError.persistence(String(describing: error))
            errorPipe.send(failure)
            throw failure
        }
    }

    /// Queues a write after all earlier writes and commits state only after persistence succeeds.
    /// Ownership: the handle owns the ordered write task. Isolation: actor plus Store actor boundary. Errors: persistence failures throw and emit. Cancellation: cancellation does not publish a value.
    public func set(_ value: Value) async throws {
        guard !isDisposed else { throw PersistedError.disposed }
        let envelope = Envelope(schemaVersion: schemaVersion, value: value)
        let previous = writeTail
        writeGeneration &+= 1
        let generation = writeGeneration
        let store = self.store
        let key = self.key
        let task = Task<Void, Error> {
            if let previous { try await previous.value }
            try await store.set(key, value: envelope)
        }
        writeTail = task
        do {
            try await task.value
            await state.set(value)
            if writeGeneration == generation { writeTail = nil }
        } catch {
            if writeGeneration == generation { writeTail = nil }
            let failure =
                error as? PersistedError ?? PersistedError.persistence(String(describing: error))
            errorPipe.send(failure)
            throw failure
        }
    }

    /// Cancels observation and pending writes; subsequent operations throw disposed.
    /// Ownership: actor releases owned tasks and error subscribers. Isolation: actor. Errors: none. Cancellation: owned tasks are cancelled terminally.
    public func dispose() async {
        guard !isDisposed else { return }
        isDisposed = true
        observationTask?.cancel()
        writeTail?.cancel()
        observationTask = nil
        writeTail = nil
        errorPipe.finish()
    }

    private func consume(_ change: StoreChange) async {
        guard !isDisposed, change.key == nil || change.key == key else { return }
        _ = try? await load()
    }
}

/// A UserDefaults-backed store with an isolated namespace.
/// Ownership: the actor owns its suite reference. Isolation: actor. Errors: methods throw StorageError. Cancellation: cancelled operations stop before publication.
public actor UserDefaultsStore: Store {
    private let suite: UserDefaults
    private let namespace: String
    private nonisolated let scope: String
    /// Bounded mutation stream. Ownership: caller owns iteration. Isolation: nonisolated sendable stream. Errors: none. Cancellation: iteration can be cancelled.
    public nonisolated let changes: AsyncStream<StoreChange>

    /// Creates a namespaced store without starting I/O. Ownership: the actor owns the suite. Isolation: actor. Errors: invalid data is reported by operations. Cancellation: none during init.
    public init(suiteName: String? = nil, namespace: String = "Weave.Storage") {
        self.suite = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.namespace = namespace
        self.scope = "\(suiteName ?? "standard")|\(namespace)"
        self.changes = StoreChangeCenter.makeStream(scope: self.scope)
    }

    /// Loads a Codable value. Ownership: result is caller-owned. Isolation: actor. Errors: decoding/storage failures. Cancellation: propagates.
    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T? {
        guard let data = suite.data(forKey: namespaced(key)) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw StorageError.decodingFailed
        }
    }

    /// Stores a Codable value. Ownership: encoded copy is retained by UserDefaults. Isolation: actor. Errors: encoding failures. Cancellation: propagates.
    public func set<T: Codable & Sendable>(_ key: String, value: T) async throws {
        guard valid(key) else { throw StorageError.invalidKey }
        do { suite.set(try JSONEncoder().encode(value), forKey: namespaced(key)) } catch {
            throw StorageError.encodingFailed
        }
        await StoreChangeCenter.shared.publish(
            scope: scope, change: StoreChange(key: key, operation: .set))
    }

    /// Removes one namespaced value. Ownership: actor owns mutation. Isolation: actor. Errors: invalid keys throw. Cancellation: propagates.
    public func remove(_ key: String) async throws {
        guard valid(key) else { throw StorageError.invalidKey }
        suite.removeObject(forKey: namespaced(key))
        await StoreChangeCenter.shared.publish(
            scope: scope, change: StoreChange(key: key, operation: .remove))
    }

    /// Removes only this namespace. Ownership: actor owns mutation. Isolation: actor. Errors: none for absent keys. Cancellation: propagates.
    public func removeAll() async throws {
        for key in suite.dictionaryRepresentation().keys where key.hasPrefix(namespace + ".") {
            suite.removeObject(forKey: key)
        }
        await StoreChangeCenter.shared.publish(
            scope: scope, change: StoreChange(key: nil, operation: .removeAll))
    }

    private func valid(_ key: String) -> Bool { !key.isEmpty && !key.contains("\0") }
    private func namespaced(_ key: String) -> String { "\(namespace).\(key)" }
}

/// Disk eviction policy; memory decoded data is outside this budget. Ownership: copied value. Isolation: none. Errors: invalid limits are rejected by FileCacheStore. Cancellation: not applicable.
public enum CacheEvictionPolicy: Sendable, Equatable {
    case lru(maxBytes: Int)
    case ttl(maxAge: TimeInterval, maxBytes: Int?)
    case none
}

/// Injectable clock for deterministic cache eviction. Ownership: the value retains its closure. Isolation: sendable. Errors: none. Cancellation: not applicable.
public struct StorageClock: Sendable {
    /// Injectable wall clock used for deterministic eviction. Ownership: closure is retained. Isolation: sendable closure. Errors: none. Cancellation: not applicable.
    public let now: @Sendable () -> Date
    /// Creates a clock. Ownership: closure is retained. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }
}

/// Actor-isolated binary cache. Disk accounting is independent from decoded image memory.
/// Ownership: actor owns directory index and filesystem mutations. Isolation: actor. Errors: typed configuration/data errors and filesystem failures. Cancellation: cancelled operations do not publish changes.
public actor FileCacheStore: Store {
    private struct Entry { let url: URL; var size: Int; var lastAccess: Date }
    private let directory: URL
    private let evictionPolicy: CacheEvictionPolicy
    private let clock: StorageClock
    private var entries: [String: Entry] = [:]
    private let continuation: AsyncStream<StoreChange>.Continuation
    /// Bounded mutation stream. Ownership: caller owns iteration. Isolation: nonisolated sendable stream. Errors: none. Cancellation: iteration can be cancelled.
    public nonisolated let changes: AsyncStream<StoreChange>

    /// Creates the directory and restores its index synchronously. Ownership: actor owns directory access. Isolation: actor. Errors: invalid policy/filesystem failures. Cancellation: no operation starts during init.
    public init(
        directory: URL, evictionPolicy: CacheEvictionPolicy = .lru(maxBytes: 100_000_000),
        clock: StorageClock = StorageClock()
    ) throws {
        if case .lru(let n) = evictionPolicy, n < 0 {
            throw StorageError.invalidConfiguration("negative maxBytes")
        }
        if case .ttl(let age, let max) = evictionPolicy, (age < 0 || (max ?? 0) < 0) {
            throw StorageError.invalidConfiguration("negative eviction limit")
        }
        self.directory = directory.standardizedFileURL
        self.evictionPolicy = evictionPolicy
        self.clock = clock
        let pair = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.changes = pair.stream
        self.continuation = pair.continuation
        try FileManager.default.createDirectory(
            at: self.directory, withIntermediateDirectories: true)
        try Self.restoreEntries(at: self.directory, into: &self.entries)
    }

    /// Loads and decodes a value. Ownership: decoded value is caller-owned. Isolation: actor. Errors: decode/filesystem failures. Cancellation: propagates.
    public func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T? {
        guard let data = try await getData(key) else { return nil }
        do { return try JSONDecoder().decode(T.self, from: data) } catch {
            throw StorageError.decodingFailed
        }
    }

    /// Encodes and atomically stores a value. Ownership: encoded bytes are actor-owned. Isolation: actor. Errors: encode/eviction/filesystem failures. Cancellation: propagates.
    public func set<T: Codable & Sendable>(_ key: String, value: T) async throws {
        do { try await setData(key, data: JSONEncoder().encode(value)) } catch let error
            as StorageError
        { throw error } catch { throw StorageError.encodingFailed }
    }

    /// Reads binary data and updates LRU access time. Ownership: returned data is caller-owned. Isolation: actor. Errors: corrupt/filesystem failures. Cancellation: propagates.
    public func getData(_ key: String) async throws -> Data? {
        let id = try safeID(key)
        guard var entry = entries[id] else { return nil }
        do {
            let data = try Data(contentsOf: entry.url, options: [.mappedIfSafe])
            entry.lastAccess = clock.now()
            entries[id] = entry
            try FileManager.default.setAttributes(
                [.modificationDate: entry.lastAccess], ofItemAtPath: entry.url.path)
            return data
        } catch {
            if (error as NSError).code == NSFileReadNoSuchFileError {
                entries.removeValue(forKey: id); return nil
            }
            throw StorageError.corruptData
        }
    }

    /// Atomically writes binary data. Ownership: bytes are copied to disk. Isolation: actor. Errors: invalid/oversized/filesystem failures. Cancellation: failed writes preserve the prior value.
    public func setData(_ key: String, data: Data) async throws {
        let id = try safeID(key)
        if let maxBytes = maxByteLimit, data.count > maxBytes { throw StorageError.itemTooLarge }
        let url = directory.appendingPathComponent("entry-\(id)", isDirectory: false)
        let temp = directory.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: false)
        do {
            try data.write(to: temp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            let now = clock.now()
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            entries[id] = Entry(url: url, size: data.count, lastAccess: now)
            try evictIfNeeded()
            continuation.yield(StoreChange(key: key, operation: .set))
        } catch let error as StorageError {
            try? FileManager.default.removeItem(at: temp); throw error
        } catch { try? FileManager.default.removeItem(at: temp); throw error }
    }

    /// Removes one cache entry. Ownership: actor owns mutation. Isolation: actor. Errors: filesystem failures. Cancellation: propagates.
    public func remove(_ key: String) async throws {
        let id = try safeID(key)
        if let entry = entries.removeValue(forKey: id) {
            try FileManager.default.removeItem(at: entry.url)
        }
        continuation.yield(StoreChange(key: key, operation: .remove))
    }

    /// Removes only cache entries in this directory. Ownership: actor owns mutation. Isolation: actor. Errors: individual cleanup failures are tolerated. Cancellation: propagates.
    public func removeAll() async throws {
        for entry in entries.values { try? FileManager.default.removeItem(at: entry.url) }
        entries.removeAll()
        continuation.yield(StoreChange(key: nil, operation: .removeAll))
    }

    private func safeID(_ key: String) throws -> String {
        guard !key.isEmpty, !key.contains("\0") else { throw StorageError.invalidKey }
        return Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private func evictIfNeeded() throws {
        let now = clock.now()
        if case .ttl(let age, let maxBytes) = evictionPolicy {
            for (id, entry) in entries where now.timeIntervalSince(entry.lastAccess) >= age {
                try? FileManager.default.removeItem(at: entry.url); entries.removeValue(forKey: id)
            }
            if let maxBytes { try evictTo(maxBytes) }
        } else if case .lru(let maxBytes) = evictionPolicy {
            try evictTo(maxBytes)
        }
    }

    private var maxByteLimit: Int? {
        switch evictionPolicy {
        case .lru(let maxBytes): return maxBytes
        case .ttl(_, let maxBytes): return maxBytes
        case .none: return nil
        }
    }

    private func evictTo(_ maxBytes: Int) throws {
        while entries.values.reduce(0, { $0 + $1.size }) > maxBytes {
            guard let victim = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else {
                break
            }
            try FileManager.default.removeItem(at: victim.value.url)
            entries.removeValue(forKey: victim.key)
        }
    }

    private static func restoreEntries(at directory: URL, into entries: inout [String: Entry])
        throws
    {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        for url in urls where url.lastPathComponent.hasPrefix("entry-") {
            let values = try url.resourceValues(forKeys: [
                .fileSizeKey, .contentModificationDateKey,
            ])
            entries[String(url.lastPathComponent.dropFirst(6))] = Entry(
                url: url, size: values.fileSize ?? 0,
                lastAccess: values.contentModificationDate ?? .distantPast)
        }
    }
}
