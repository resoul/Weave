import Foundation
import Security
import Testing
@testable import Storage

@Test("UserDefaultsStore isolates its namespace and round trips Codable")
func userDefaultsStoreRoundTrip() async throws {
    let suiteName = "WeaveTests-\(UUID().uuidString)"
    let foreign = UserDefaults(suiteName: suiteName)!
    foreign.set("value", forKey: "other.foreign")
    let store = UserDefaultsStore(suiteName: suiteName, namespace: "test")
    try await store.set("number", value: 42)
    #expect(try await store.get("number", as: Int.self) == 42)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask { try? await store.set("concurrent-\(index)", value: index) }
        }
    }
    try await store.removeAll()
    #expect(UserDefaults(suiteName: suiteName)?.object(forKey: "other.foreign") != nil)
}

@Test("FileCacheStore TTL removes entries at the exact boundary")
func fileCacheTTL() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "weave-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = LockedClock(Date(timeIntervalSince1970: 10))
    let store = try FileCacheStore(
        directory: directory, evictionPolicy: .ttl(maxAge: 5, maxBytes: nil),
        clock: StorageClock { clock.value })
    try await store.setData("ttl", data: Data("x".utf8))
    clock.value = Date(timeIntervalSince1970: 15)
    try await store.setData("other", data: Data("y".utf8))
    #expect(try await store.getData("ttl") == nil)
}

@Test("FileCacheStore evicts least recently used data and survives restart")
func fileCacheLRUAndRestart() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "weave-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let clock = LockedClock(Date(timeIntervalSince1970: 100))
    let store = try FileCacheStore(
        directory: directory, evictionPolicy: .lru(maxBytes: 5), clock: StorageClock { clock.value }
    )
    try await store.setData("a", data: Data("1234".utf8))
    clock.value = Date(timeIntervalSince1970: 101)
    try await store.setData("b", data: Data("12".utf8))
    #expect(try await store.getData("a") == nil)
    #expect(try await store.getData("b") == Data("12".utf8))
    let restarted = try FileCacheStore(
        directory: directory, evictionPolicy: .none, clock: StorageClock { clock.value })
    #expect(try await restarted.getData("b") == Data("12".utf8))
}

@Test("FileCacheStore rejects traversal and preserves old value on failed key")
func fileCacheSafety() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "weave-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try FileCacheStore(directory: directory, evictionPolicy: .none)
    var rejected = false
    do { try await store.setData("", data: Data("x".utf8)) } catch StorageError.invalidKey {
        rejected = true
    } catch {}
    #expect(rejected)
    try await store.setData("safe", data: Data("old".utf8))
    #expect(try await store.getData("safe") == Data("old".utf8))

    let limited = try FileCacheStore(
        directory: directory.appendingPathComponent("limited"), evictionPolicy: .lru(maxBytes: 3))
    try await limited.setData("safe", data: Data("old".utf8))
    var rejectedOversized = false
    do { try await limited.setData("safe", data: Data("larger".utf8)) } catch StorageError
        .itemTooLarge
    { rejectedOversized = true } catch {}
    #expect(rejectedOversized)
    #expect(try await limited.getData("safe") == Data("old".utf8))
}

private final class LockedClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

@Test("KeychainStore maps status codes and isolates service namespace")
func keychainStoreFakeBackend() async throws {
    let backend = FakeKeychainBackend()
    let first = KeychainStore(service: "service-a", backend: backend)
    let second = KeychainStore(service: "service-b", backend: backend)
    try await first.set("token", value: "secret")
    #expect(try await first.get("token", as: String.self) == "secret")
    #expect(try await second.get("token", as: String.self) == nil)
    try await first.set("token", value: "updated")
    #expect(try await first.get("token", as: String.self) == "updated")
    try await first.removeAll()
    #expect(try await first.get("token", as: String.self) == nil)
    try await second.set("token", value: "other")
    #expect(try await second.get("token", as: String.self) == "other")

    backend.readStatus = errSecAuthFailed
    var denied = false
    do { _ = try await first.get("token", as: String.self) } catch KeychainError.accessDenied {
        denied = true
    } catch {}
    #expect(denied)
}

@Test("KeychainStore exposes corrupt value without logging its contents")
func keychainStoreCorruptValue() async throws {
    let backend = FakeKeychainBackend()
    backend.raw["service-a||token"] = Data([0xff, 0x00])
    let store = KeychainStore(service: "service-a", backend: backend)
    var corrupt = false
    do { _ = try await store.get("token", as: String.self) } catch KeychainError.corruptValue {
        corrupt = true
    } catch {}
    #expect(corrupt)
}

@Test("Persisted observes writes from another handle and preserves ordering")
func persistedCrossInstanceObservation() async throws {
    let suiteName = "WeavePersisted-\(UUID().uuidString)"
    let firstStore = UserDefaultsStore(suiteName: suiteName, namespace: "state")
    let secondStore = UserDefaultsStore(suiteName: suiteName, namespace: "state")
    let first = Persisted<Int>(key: "counter", defaultValue: 0, store: firstStore)
    let second = Persisted<Int>(key: "counter", defaultValue: 0, store: secondStore)
    await first.start()
    await second.start()
    let observation = Task { () -> Int? in
        for await value in second.changes.stream where value == 2 { return value }
        return nil
    }
    try await first.set(1)
    try await first.set(2)
    #expect(await observation.value == 2)
    #expect(try await second.load() == 2)
}

@Test("Persisted exposes schema errors and dispose stops observation")
func persistedSchemaAndDispose() async throws {
    let suiteName = "WeavePersisted-\(UUID().uuidString)"
    let store = UserDefaultsStore(suiteName: suiteName, namespace: "state")
    let persisted = Persisted<Int>(key: "value", defaultValue: 3, store: store, schemaVersion: 2)
    let foreign = UserDefaults(suiteName: suiteName)!
    foreign.set(try JSONEncoder().encode(["schemaVersion": 1, "value": 8]), forKey: "state.value")
    var mismatch = false
    do { _ = try await persisted.load() } catch PersistedError.schemaMismatch {
        mismatch = true
    } catch {}
    #expect(mismatch)
    await persisted.start()
    await persisted.dispose()
    var disposed = false
    do { _ = try await persisted.load() } catch PersistedError.disposed { disposed = true } catch {}
    #expect(disposed)
}

private final class FakeKeychainBackend: KeychainBackend, @unchecked Sendable {
    var raw: [String: Data] = [:]
    var readStatus: Int32 = errSecSuccess
    private func id(_ service: String, _ account: String, _ group: String?) -> String {
        "\(service)|\(group ?? "")|\(account)"
    }
    func read(service: String, account: String, accessGroup: String?) -> (Int32, Data?) {
        if readStatus != errSecSuccess { return (readStatus, nil) }
        let key = id(service, account, accessGroup)
        guard let value = raw[key] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, value)
    }
    func add(service: String, account: String, accessGroup: String?, data: Data) -> Int32 {
        let key = id(service, account, accessGroup)
        guard raw[key] == nil else { return errSecDuplicateItem }
        raw[key] = data
        return errSecSuccess
    }
    func update(service: String, account: String, accessGroup: String?, data: Data) -> Int32 {
        raw[id(service, account, accessGroup)] = data
        return errSecSuccess
    }
    func delete(service: String, account: String, accessGroup: String?) -> Int32 {
        let key = id(service, account, accessGroup)
        guard raw.removeValue(forKey: key) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }
    func deleteAll(service: String, accessGroup: String?) -> Int32 {
        let prefix = "\(service)|\(accessGroup ?? "")|"
        raw = raw.filter { !$0.key.hasPrefix(prefix) }
        return errSecSuccess
    }
}
