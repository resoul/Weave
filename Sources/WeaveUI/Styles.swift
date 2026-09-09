import Foundation

/// Modifier family used to keep behavior, semantics and presentation separate.
/// Ownership: the value is copied by ModifierSet. Isolation: none. Errors: unknown families are retained for diagnostics. Cancellation: not applicable.
public enum ModifierFamily: Sendable, Hashable {
    case layout
    case visual
    case semantic
    case event
    case identity
}

/// Immutable scalar accepted by a modifier record.
/// Ownership: the value is copied into a modifier set. Isolation: none. Errors: invalid values are normalized by the consuming family. Cancellation: not applicable.
public enum ModifierValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

/// One immutable modifier record.
/// Ownership: the record owns copied values. Isolation: none. Errors: duplicate keys resolve last-write-wins deterministically. Cancellation: not applicable.
public struct ModifierRecord: Sendable, Hashable {
    public let family: ModifierFamily
    public let key: String
    public let value: ModifierValue

    /// Creates a modifier record.
    /// Ownership: values are copied. Isolation: none. Errors: empty keys are retained for diagnostics. Cancellation: not applicable.
    public init(family: ModifierFamily, key: String, value: ModifierValue) {
        self.family = family; self.key = key; self.value = value
    }
}

/// Immutable ordered modifier chain.
/// Ownership: the chain owns its copied records. Isolation: none. Errors: incompatible combinations are reported by diagnostics. Cancellation: not applicable.
public struct ModifierSet: Sendable, Hashable {
    public let records: [ModifierRecord]

    /// Creates an empty modifier set.
    /// Ownership: the set owns copied records. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(records: [ModifierRecord] = []) { self.records = records }

    /// Returns a new chain with one modifier appended.
    /// Ownership: the returned chain owns a copied record. Isolation: none. Errors: none. Cancellation: not applicable.
    public func appending(_ record: ModifierRecord) -> Self {
        Self(records: records + [record])
    }

    /// Resolves records by family/key; later records override earlier records.
    /// Ownership: the result is owned by the caller. Isolation: none. Errors: incompatible duplicate families are listed. Cancellation: not applicable.
    public func resolved() -> ModifierResolution {
        var values: [String: ModifierRecord] = [:]
        var diagnostics: [String] = []
        for record in records {
            let identity = "\(record.family):\(record.key)"
            if values[identity] != nil { diagnostics.append(identity) }
            values[identity] = record
        }
        return ModifierResolution(
            records: Array(values.values).sorted {
                "\($0.family):\($0.key)" < "\($1.family):\($1.key)"
            }, diagnostics: diagnostics)
    }
}

/// Deterministic modifier resolution result.
/// Ownership: the result owns records and diagnostics. Isolation: none. Errors: diagnostics identify overridden keys. Cancellation: not applicable.
public struct ModifierResolution: Sendable, Hashable {
    public let records: [ModifierRecord]
    public let diagnostics: [String]

    /// Creates a resolution result.
    /// Ownership: arrays are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(records: [ModifierRecord], diagnostics: [String] = []) {
        self.records = records; self.diagnostics = diagnostics
    }
}

/// Typed style value key for scoped presentation values.
/// Ownership: implementations supply immutable defaults. Isolation: none. Errors: none. Cancellation: not applicable.
public protocol StyleKey: Sendable {
    associatedtype Value: Sendable
    static var defaultValue: Value { get }
}

/// Immutable scoped style values.
/// Ownership: the scope owns copied values. Isolation: none. Errors: absent keys return defaults. Cancellation: not applicable.
public struct StyleValues: Sendable {
    private var storage: [ObjectIdentifier: any Sendable] = [:]

    /// Creates an empty style scope.
    /// Ownership: the scope owns its storage. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Reads or writes a typed style value.
    /// Ownership: values are copied according to Sendable semantics. Isolation: none. Errors: missing values use defaults. Cancellation: not applicable.
    public subscript<K: StyleKey>(_ key: K.Type) -> K.Value {
        get { storage[ObjectIdentifier(K.self)] as? K.Value ?? K.defaultValue }
        set { storage[ObjectIdentifier(K.self)] = newValue }
    }

    /// Merges a child scope over this scope.
    /// Ownership: the returned values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public func merging(_ child: StyleValues) -> StyleValues {
        var result = self
        for (key, value) in child.storage { result.storage[key] = value }
        return result
    }
}

/// Configuration-based button presentation style.
/// Ownership: the style owns immutable presentation policy. Isolation: MainActor while building NodeContent. Errors: style output does not change activation semantics. Cancellation: no work starts during style description.
@MainActor
public protocol ButtonStyle: Sendable {
    @NodeBuilder func makeBody(configuration: ButtonConfiguration) -> NodeContent
}

/// Default style that leaves behavior and semantics on ButtonNode.
/// Ownership: the style is stateless. Isolation: MainActor. Errors: none. Cancellation: no work starts.
@MainActor
public struct DefaultButtonStyle: ButtonStyle {
    /// Creates the default style.
    /// Ownership: no retained state. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {}

    /// Returns an immutable presentation description.
    /// Ownership: returned content is owned by caller. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func makeBody(configuration: ButtonConfiguration) -> NodeContent {
        NodeContent.children([
            NodeDescriptor(typeName: "ButtonPresentation", key: configuration.title)
        ])
    }
}

/// Input presentation configuration independent of input behavior.
/// Ownership: values are copied by InputStyle. Isolation: none. Errors: none. Cancellation: not applicable.
public struct InputConfiguration: Sendable, Hashable {
    public let isFocused: Bool
    public let isDisabled: Bool
    public let hasError: Bool

    /// Creates input presentation configuration.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(isFocused: Bool = false, isDisabled: Bool = false, hasError: Bool = false) {
        self.isFocused = isFocused; self.isDisabled = isDisabled; self.hasError = hasError
    }
}

/// Input presentation style boundary.
/// Ownership: style owns immutable presentation policy. Isolation: MainActor for content building. Errors: style cannot mutate input behavior. Cancellation: no work starts.
@MainActor
public protocol InputStyle: Sendable {
    @NodeBuilder func makeBody(configuration: InputConfiguration) -> NodeContent
}

/// Card presentation configuration.
/// Ownership: values are copied by CardStyle. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CardConfiguration: Sendable, Hashable {
    public let isHighlighted: Bool
    public let isSelected: Bool

    /// Creates card presentation configuration.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(isHighlighted: Bool = false, isSelected: Bool = false) {
        self.isHighlighted = isHighlighted; self.isSelected = isSelected
    }
}

/// Card presentation style boundary.
/// Ownership: style owns immutable presentation policy. Isolation: MainActor for content building. Errors: style cannot mutate selection/actions. Cancellation: no work starts.
@MainActor
public protocol CardStyle: Sendable {
    @NodeBuilder func makeBody(configuration: CardConfiguration) -> NodeContent
}
