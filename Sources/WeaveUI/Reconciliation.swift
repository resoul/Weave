/// Structural identity used by the immutable reconciler.
/// Ownership: the value is copied by patches. Isolation: none. Errors: duplicate keys are reported
/// by the differ. Cancellation: not applicable.
public struct ReconciliationIdentity: Sendable, Hashable {
    public let typeName: String
    public let explicitKey: String?
    public let siblingPosition: Int

    /// Creates a structural identity from a descriptor position.
    /// Ownership: strings are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(typeName: String, explicitKey: String? = nil, siblingPosition: Int) {
        self.typeName = typeName
        self.explicitKey = explicitKey
        self.siblingPosition = siblingPosition
    }
}

/// Immutable patch emitted by the reconciliation differ.
/// Ownership: descriptors and identities are value snapshots. Isolation: none. Errors: invalid
/// indexes are never emitted. Cancellation: not applicable.
public enum ReconciliationPatch: Sendable, Hashable {
    case insert(descriptor: NodeDescriptor, atIndex: Int)
    case remove(identity: ReconciliationIdentity, fromIndex: Int)
    case update(atIndex: Int, descriptor: NodeDescriptor)
    case move(identity: ReconciliationIdentity, fromIndex: Int, toIndex: Int)
    case replace(atIndex: Int, descriptor: NodeDescriptor)
}

/// Result of comparing two immutable child descriptions.
/// Ownership: the result owns its patches and diagnostics. Isolation: none. Errors: duplicate keys
/// are retained as diagnostics and the first occurrence wins. Cancellation: not applicable.
public struct ReconciliationDiff: Sendable, Hashable {
    public let patches: [ReconciliationPatch]
    public let diagnostics: NodeBuildDiagnostics

    /// Creates a reconciliation result.
    /// Ownership: arrays are copied into the result. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        patches: [ReconciliationPatch],
        diagnostics: NodeBuildDiagnostics = NodeBuildDiagnostics()
    ) {
        self.patches = patches
        self.diagnostics = diagnostics
    }
}

/// Deterministic differ for keyed and positional child descriptions.
/// Ownership: inputs are read as immutable snapshots. Isolation: none. Errors: duplicate keys are
/// diagnosed deterministically. Cancellation: not applicable.
public enum Reconciler {
    /// Compares old and new children while preserving matching runtime identity.
    /// Ownership: returned patches own copied descriptors. Isolation: none. Errors: duplicate keys
    /// keep the first occurrence and later occurrences are inserted. Cancellation: not applicable.
    public static func diff(old: [NodeDescriptor], new: [NodeDescriptor]) -> ReconciliationDiff {
        var oldByKey: [String: Int] = [:]
        var duplicateKeys: [String] = []
        for (index, descriptor) in old.enumerated() {
            guard let key = descriptor.key else { continue }
            if oldByKey.updateValue(index, forKey: key) != nil {
                duplicateKeys.append(key)
                oldByKey[key] = oldByKey[key].map { min($0, index) }
            }
        }

        var newKeyCounts: [String: Int] = [:]
        for descriptor in new {
            guard let key = descriptor.key else { continue }
            newKeyCounts[key, default: 0] += 1
        }
        for (key, count) in newKeyCounts where count > 1 {
            duplicateKeys.append(contentsOf: repeatElement(key, count: count - 1))
        }

        struct Token: Sendable, Hashable {
            let oldIndex: Int
            var descriptor: NodeDescriptor
        }
        var working = old.enumerated().map { Token(oldIndex: $0.offset, descriptor: $0.element) }
        var used = Set<Int>()
        var patches: [ReconciliationPatch] = []

        for (newIndex, descriptor) in new.enumerated() {
            var candidate: Int?
            if let key = descriptor.key, let oldIndex = oldByKey[key], newKeyCounts[key] == 1 {
                candidate = oldIndex
            } else if descriptor.key == nil, newIndex < old.count, old[newIndex].key == nil {
                candidate = newIndex
            }

            guard let oldIndex = candidate,
                !used.contains(oldIndex),
                let location = working.firstIndex(where: { $0.oldIndex == oldIndex })
            else {
                working.insert(Token(oldIndex: -newIndex - 1, descriptor: descriptor), at: newIndex)
                patches.append(.insert(descriptor: descriptor, atIndex: newIndex))
                continue
            }
            used.insert(oldIndex)
            if location != newIndex {
                let token = working.remove(at: location)
                working.insert(token, at: newIndex)
                let identity = ReconciliationIdentity(
                    typeName: token.descriptor.typeName,
                    explicitKey: token.descriptor.key,
                    siblingPosition: location
                )
                patches.append(.move(identity: identity, fromIndex: location, toIndex: newIndex))
            }
            if working[newIndex].descriptor.typeName != descriptor.typeName {
                working[newIndex].descriptor = descriptor
                patches.append(.replace(atIndex: newIndex, descriptor: descriptor))
            } else if working[newIndex].descriptor != descriptor {
                working[newIndex].descriptor = descriptor
                patches.append(.update(atIndex: newIndex, descriptor: descriptor))
            }
        }

        while working.count > new.count {
            let index = working.count - 1
            let token = working.removeLast()
            guard token.oldIndex >= 0 else { continue }
            let identity = ReconciliationIdentity(
                typeName: token.descriptor.typeName,
                explicitKey: token.descriptor.key,
                siblingPosition: token.oldIndex
            )
            patches.append(.remove(identity: identity, fromIndex: index))
        }
        return ReconciliationDiff(
            patches: patches,
            diagnostics: NodeBuildDiagnostics(duplicateKeys: duplicateKeys)
        )
    }
}
