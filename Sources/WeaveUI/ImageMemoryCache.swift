import Foundation

/// Actor-owned decoded image cache with an independent byte budget.
/// Ownership: the actor owns cached payloads. Isolation: actor. Errors: oversized values are
/// ignored after any existing value is removed. Cancellation: cancellation applies at await points.
public actor ImageMemoryCache {
    private struct Entry {
        let image: LoadedImage
        let size: Int
        var access: UInt64
    }

    private let maxBytes: Int
    private var entries: [String: Entry] = [:]
    private var usedBytes = 0
    private var accessCounter: UInt64 = 0

    /// Creates a decoded cache with a separate memory budget.
    /// Ownership: the actor retains no external objects. Isolation: actor. Errors: non-positive
    /// budgets normalize to one byte. Cancellation: no work starts during initialization.
    public init(maxBytes: Int) { self.maxBytes = max(1, maxBytes) }

    /// Returns a cached image and records a most-recently-used access.
    /// Ownership: returned image is copied. Isolation: actor. Errors: none. Cancellation: none.
    public func image(for key: String) -> LoadedImage? {
        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.access = accessCounter
        entries[key] = entry
        return entry.image
    }

    /// Stores a decoded image and evicts least-recently-used values to stay within the byte budget.
    /// Ownership: payload is copied into the actor. Isolation: actor. Errors: none. Cancellation: none.
    public func insert(_ image: LoadedImage, for key: String) {
        if let old = entries.removeValue(forKey: key) { usedBytes -= old.size }
        let size = image.data.count
        guard size <= maxBytes else { return }
        accessCounter &+= 1
        entries[key] = Entry(image: image, size: size, access: accessCounter)
        usedBytes += size
        while usedBytes > maxBytes,
            let victim = entries.min(by: { $0.value.access < $1.value.access })
        {
            usedBytes -= victim.value.size
            entries.removeValue(forKey: victim.key)
        }
    }

    /// Removes one decoded value without affecting disk cache state.
    /// Ownership: actor releases the payload. Isolation: actor. Errors: none. Cancellation: none.
    public func remove(_ key: String) {
        if let entry = entries.removeValue(forKey: key) { usedBytes -= entry.size }
    }

    /// Removes all decoded values while retaining the configured budget.
    /// Ownership: actor releases all payloads. Isolation: actor. Errors: none. Cancellation: none.
    public func removeAll() { entries.removeAll(); usedBytes = 0 }

    /// Current decoded byte usage, excluding disk cache bytes.
    /// Ownership: value is copied. Isolation: actor. Errors: none. Cancellation: none.
    public func byteUsage() -> Int { usedBytes }
}
