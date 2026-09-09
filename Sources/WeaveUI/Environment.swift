import Foundation

/// Describes which committed UI work a changed environment value invalidates.
///
/// Ownership: masks are value types owned by their caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentInvalidation: OptionSet, Sendable, Hashable {
    /// No render, layout, or accessibility work is required.
    public static let none: Self = []
    /// The value can change presentation without changing measured geometry.
    public static let display = Self(rawValue: 1 << 0)
    /// The value can change measured geometry.
    public static let layout = Self(rawValue: 1 << 1)
    /// The value can change the semantic or accessibility tree.
    public static let accessibility = Self(rawValue: 1 << 2)
    /// The value can change both measured geometry and presentation.
    public static let layoutAndDisplay: Self = [.layout, .display]

    public let rawValue: UInt8

    /// Creates an invalidation mask from its stable serialized representation.
    ///
    /// Ownership: the caller owns the mask value. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }
}

/// Declares a typed value inherited through an environment scope.
///
/// Ownership: the key type owns its default value contract. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public protocol EnvironmentKey: Sendable {
    associatedtype Value: Sendable

    /// The value used when no scope provides an override.
    static var defaultValue: Value { get }
    /// The committed work affected when this key changes.
    static var invalidation: EnvironmentInvalidation { get }
}

/// Logical safe-area insets propagated through the window environment.
/// Ownership: immutable value copied into environment snapshots. Isolation: none. Errors:
/// non-finite and negative values normalize to zero. Cancellation: not applicable.
public struct SafeAreaInsets: Sendable, Hashable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    /// Creates normalized logical insets.
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: invalid
    /// components become zero. Cancellation: not applicable.
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = Self.normalize(top)
        self.leading = Self.normalize(leading)
        self.bottom = Self.normalize(bottom)
        self.trailing = Self.normalize(trailing)
    }

    private static func normalize(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}

/// Selects safe-area edges ignored by an explicit layout boundary.
/// Ownership: immutable value. Isolation: none. Errors: unknown bits are preserved only through
/// the raw initializer. Cancellation: not applicable.
public struct SafeAreaEdges: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    /// Creates an edge mask from its stable raw representation.
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: unknown
    /// bits are preserved. Cancellation: not applicable.
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let top = Self(rawValue: 1 << 0)
    public static let leading = Self(rawValue: 1 << 1)
    public static let bottom = Self(rawValue: 1 << 2)
    public static let trailing = Self(rawValue: 1 << 3)
    public static let none: Self = []
    public static let all: Self = [.top, .leading, .bottom, .trailing]
}

/// Environment key for logical safe-area insets.
/// Ownership: the key owns an immutable zero default. Isolation: none. Errors: none. Cancellation:
/// not applicable.
public enum SafeAreaInsetsKey: EnvironmentKey {
    public static let defaultValue = SafeAreaInsets()
    public static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

/// Bounded resource inputs propagated with the environment.
///
/// Ownership: this value is copied with each immutable snapshot. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentResourceConfiguration: Sendable, Hashable {
    /// Maximum memory budget for framework-owned decoded resources.
    public let memoryBudgetBytes: Int
    /// Maximum number of concurrent preparation operations.
    public let decodeConcurrency: Int
    /// Whether prefetch work is allowed for non-visible resources.
    public let prefetchEnabled: Bool

    /// Creates a bounded resource configuration, clamping invalid numeric inputs to safe values.
    ///
    /// Ownership: the returned configuration is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(memoryBudgetBytes: Int, decodeConcurrency: Int, prefetchEnabled: Bool) {
        self.memoryBudgetBytes = max(0, memoryBudgetBytes)
        self.decodeConcurrency = max(1, decodeConcurrency)
        self.prefetchEnabled = prefetchEnabled
    }
}

/// The inherited resource policy key used by workers and cache owners.
///
/// Ownership: the key supplies an immutable default value. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum ResourceConfigurationKey: EnvironmentKey {
    public static let defaultValue = EnvironmentResourceConfiguration(
        memoryBudgetBytes: 64 * 1024 * 1024,
        decodeConcurrency: 2,
        prefetchEnabled: true
    )
    public static let invalidation: EnvironmentInvalidation = .none
}

/// A sparse, typed collection of environment values.
///
/// Ownership: each instance owns its sparse overrides. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentValues: Sendable {
    private var storage: [ObjectIdentifier: any Sendable]

    /// Creates values containing only key defaults.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {
        storage = [:]
    }

    /// Reads a typed value, returning its key default when no override exists.
    ///
    /// Ownership: the returned value is copied or shared according to its Sendable value semantics.
    /// Isolation: none. Errors: none. Cancellation: not applicable.
    public subscript<K: EnvironmentKey>(_ key: K.Type) -> K.Value {
        get {
            storage[ObjectIdentifier(K.self)] as? K.Value ?? K.defaultValue
        }
        set {
            storage[ObjectIdentifier(K.self)] = newValue
        }
    }

    fileprivate mutating func remove<K: EnvironmentKey>(_ key: K.Type) {
        storage.removeValue(forKey: ObjectIdentifier(K.self))
    }

    fileprivate func merged(with overrides: EnvironmentValues) -> EnvironmentValues {
        var result = self
        for (key, value) in overrides.storage {
            result.storage[key] = value
        }
        return result
    }
}

public extension EnvironmentValues {
    /// Current logical safe-area insets for this environment scope.
    var safeAreaInsets: SafeAreaInsets {
        get { self[SafeAreaInsetsKey.self] }
        set { self[SafeAreaInsetsKey.self] = newValue }
    }
}

/// A frozen environment value set that can safely cross an actor boundary.
///
/// Ownership: the snapshot owns its immutable values. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentSnapshot: Sendable {
    /// The effective values captured by this snapshot.
    public let values: EnvironmentValues
    /// The monotonically increasing revision at capture time.
    public let revision: UInt64

    /// Creates a frozen snapshot for a platform-neutral presentation contract.
    /// Ownership: values are copied and owned by the snapshot. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(values: EnvironmentValues, revision: UInt64) {
        self.values = values
        self.revision = revision
    }

    /// Creates a dependency-aware read and records the key in `dependencies`.
    ///
    /// Ownership: the returned value is borrowed from the immutable snapshot.
    /// Isolation: none. Errors: none. Cancellation: not applicable.
    public func read<K: EnvironmentKey>(
        _ key: K.Type,
        recording dependencies: inout EnvironmentDependencies
    ) -> K.Value {
        dependencies.record(key)
        return values[key]
    }
}

/// The set of environment keys read by one layout, display, or accessibility operation.
///
/// Ownership: the dependency set is owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentDependencies: Sendable, Hashable {
    private var keyIDs: Set<ObjectIdentifier> = []

    /// Creates an empty dependency set.
    ///
    /// Ownership: the caller owns the set. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Records a typed key as a dependency.
    ///
    /// Ownership: the key type is static. Isolation: none. Errors: none. Cancellation: not applicable.
    public mutating func record<K: EnvironmentKey>(_ key: K.Type) {
        keyIDs.insert(ObjectIdentifier(K.self))
    }

    fileprivate func contains(_ key: ObjectIdentifier) -> Bool {
        keyIDs.contains(key)
    }
}

/// A single committed environment change.
///
/// Ownership: the change is a value owned by its change set. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentChange: Sendable, Hashable {
    /// Stable diagnostic name of the changed key type.
    public let keyName: String
    /// Invalidation work declared by the key.
    public let invalidation: EnvironmentInvalidation
    /// Revision assigned to the commit containing this change.
    public let revision: UInt64
    fileprivate let keyID: ObjectIdentifier

    fileprivate init(
        keyID: ObjectIdentifier,
        keyName: String,
        invalidation: EnvironmentInvalidation,
        revision: UInt64
    ) {
        self.keyID = keyID
        self.keyName = keyName
        self.invalidation = invalidation
        self.revision = revision
    }
}

/// A coalesced set of changes from one environment commit.
///
/// Ownership: the change set owns its immutable changes. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct EnvironmentChangeSet: Sendable, Hashable {
    /// Changes committed together at one revision.
    public let changes: [EnvironmentChange]
    /// The revision represented by this set.
    public let revision: UInt64

    fileprivate init(changes: [EnvironmentChange], revision: UInt64) {
        self.changes = changes
        self.revision = revision
    }

    /// Returns whether this change set affects a recorded dependency set.
    ///
    /// Ownership: dependencies are read-only input. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func affects(_ dependencies: EnvironmentDependencies) -> Bool {
        changes.contains { dependencies.contains($0.keyID) }
    }

    /// The combined invalidation work required by this change set.
    ///
    /// Ownership: the returned mask is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public var invalidation: EnvironmentInvalidation {
        changes.reduce(into: .none) { $0.formUnion($1.invalidation) }
    }
}

/// Main-actor-owned inherited environment scope with sparse overrides.
///
/// Ownership: the scope owns sparse overrides and observes its parent. Isolation: MainActor.
/// Errors: none. Cancellation: not applicable.
@MainActor
public final class EnvironmentScope {
    private static var nextRevision: UInt64 = 0
    private weak var parent: EnvironmentScope?
    private var overrides = EnvironmentValues()
    private var revision: UInt64

    /// Creates a root scope with key defaults.
    ///
    /// Ownership: the scope owns its overrides. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {
        Self.nextRevision &+= 1
        revision = Self.nextRevision
    }

    /// Creates a child scope inheriting values from `parent`.
    ///
    /// Ownership: the child owns only sparse overrides; the parent remains externally owned.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init(parent: EnvironmentScope) {
        self.parent = parent
        Self.nextRevision &+= 1
        revision = Self.nextRevision
    }

    /// Captures effective values and the current inherited revision.
    ///
    /// Ownership: the returned snapshot is owned by the caller. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public var snapshot: EnvironmentSnapshot {
        let inherited =
            parent?.snapshot ?? EnvironmentSnapshot(values: EnvironmentValues(), revision: revision)
        let values = inherited.values.merged(with: overrides)
        return EnvironmentSnapshot(values: values, revision: max(revision, inherited.revision))
    }

    /// Sets a sparse override and returns its revisioned invalidation commit.
    ///
    /// Ownership: the scope stores a Sendable value copy or shared value. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    @discardableResult
    public func set<K: EnvironmentKey>(_ key: K.Type, _ value: K.Value) -> EnvironmentChangeSet {
        overrides[key] = value
        Self.nextRevision &+= 1
        revision = Self.nextRevision
        let change = EnvironmentChange(
            keyID: ObjectIdentifier(K.self),
            keyName: String(reflecting: K.self),
            invalidation: K.invalidation,
            revision: revision
        )
        return EnvironmentChangeSet(changes: [change], revision: revision)
    }

    /// Commits the resolved theme and its color scheme under one environment revision.
    /// Ownership: the scope stores immutable theme values. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable. The returned change set contains both changed keys.
    @discardableResult
    public func commitTheme(
        colorScheme: ColorScheme,
        theme: Theme
    ) -> EnvironmentChangeSet {
        overrides[ColorSchemeKey.self] = colorScheme
        overrides[ThemeKey.self] = theme
        Self.nextRevision &+= 1
        revision = Self.nextRevision
        let changes = [
            EnvironmentChange(
                keyID: ObjectIdentifier(ColorSchemeKey.self),
                keyName: String(reflecting: ColorSchemeKey.self),
                invalidation: ColorSchemeKey.invalidation,
                revision: revision
            ),
            EnvironmentChange(
                keyID: ObjectIdentifier(ThemeKey.self),
                keyName: String(reflecting: ThemeKey.self),
                invalidation: ThemeKey.invalidation,
                revision: revision
            ),
        ]
        return EnvironmentChangeSet(changes: changes, revision: revision)
    }

    /// Removes this scope's override for a key and exposes the inherited value again.
    ///
    /// Ownership: the scope releases its sparse override. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func remove<K: EnvironmentKey>(_ key: K.Type) -> EnvironmentChangeSet {
        overrides.remove(key)
        Self.nextRevision &+= 1
        revision = Self.nextRevision
        let change = EnvironmentChange(
            keyID: ObjectIdentifier(K.self),
            keyName: String(reflecting: K.self),
            invalidation: K.invalidation,
            revision: revision
        )
        return EnvironmentChangeSet(changes: [change], revision: revision)
    }

    /// Reparents the scope while retaining its sparse overrides.
    ///
    /// Ownership: the scope keeps its overrides and observes the new parent. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func reparent(to parent: EnvironmentScope?) {
        self.parent = parent
        Self.nextRevision &+= 1
        revision = Self.nextRevision
    }
}

/// Newest-only buffer for environment state changes.
///
/// Ownership: the buffer owns its pending change. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public final class EnvironmentChangeBuffer {
    private var newest: EnvironmentChangeSet?

    /// Creates an empty newest-only buffer.
    ///
    /// Ownership: the buffer owns its pending change. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Replaces any pending state with the newest commit.
    ///
    /// Ownership: the buffer stores the Sendable change set. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func push(_ changes: EnvironmentChangeSet) {
        newest = changes
    }

    /// Removes and returns the newest pending commit.
    ///
    /// Ownership: the returned change set is owned by the caller. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public func popLatest() -> EnvironmentChangeSet? {
        defer { newest = nil }
        return newest
    }
}
