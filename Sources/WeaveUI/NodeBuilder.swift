/// Immutable diagnostics produced while resolving declarative content.
///
/// Ownership: diagnostics are values owned by the build result. Isolation: none. Errors: duplicate
/// keys are reported deterministically. Cancellation: not applicable.
public struct NodeBuildDiagnostics: Sendable, Hashable {
    public let duplicateKeys: [String]
    /// Creates diagnostics.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(duplicateKeys: [String] = []) { self.duplicateKeys = duplicateKeys }
    /// Whether no duplicate key was encountered.
    public var isClean: Bool { duplicateKeys.isEmpty }
}

extension NodeContent {
    /// Diagnostics retained by this immutable content description.
    public var diagnostics: NodeBuildDiagnostics { NodeBuildDiagnostics() }

    /// Flattens groups into descriptors for reconciliation without creating runtime Nodes.
    /// Ownership: returned descriptors are copied values. Isolation: none. Errors: none. Cancellation: not applicable.
    public var flattenedDescriptors: [NodeDescriptor] {
        switch self {
        case .empty: return []
        case let .children(descriptors): return descriptors
        }
    }
}

/// Immutable content and diagnostics returned by a keyed collection build.
/// Ownership: the result owns value snapshots. Isolation: none. Errors: duplicate IDs are listed.
/// Cancellation: not applicable.
public struct ForEachResult: Sendable, Hashable {
    public let content: NodeContent
    public let diagnostics: NodeBuildDiagnostics

    /// Creates a keyed collection result.
    /// Ownership: arguments are copied into the result. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(content: NodeContent, diagnostics: NodeBuildDiagnostics) {
        self.content = content
        self.diagnostics = diagnostics
    }
}

/// Result builder for immutable NodeContent descriptions.
///
/// Ownership: builder outputs are immutable values. Isolation: none. Errors: invalid branches
/// resolve to empty content. Cancellation: not applicable.
@resultBuilder
public enum NodeBuilder {
    /// Builds a block of content.
    public static func buildBlock(_ components: NodeContent...) -> NodeContent {
        .children(components.flatMap(\.flattenedDescriptors))
    }

    /// Converts a descriptor expression to content.
    public static func buildExpression(_ expression: NodeDescriptor) -> NodeContent {
        .children([expression])
    }
    /// Converts an already-built content expression.
    public static func buildExpression(_ expression: NodeContent) -> NodeContent { expression }
    /// Builds an optional branch.
    public static func buildOptional(_ component: NodeContent?) -> NodeContent {
        component ?? .empty
    }
    /// Builds the first conditional branch.
    public static func buildEither(first component: NodeContent) -> NodeContent { component }
    /// Builds the second conditional branch.
    public static func buildEither(second component: NodeContent) -> NodeContent { component }
    /// Builds a loop while preserving order.
    public static func buildArray(_ components: [NodeContent]) -> NodeContent {
        .children(components.flatMap(\.flattenedDescriptors))
    }
    /// Builds availability branches as ordinary conditional content.
    public static func buildLimitedAvailability(_ component: NodeContent) -> NodeContent {
        component
    }
}

/// Group creates structure without creating a runtime Node.
/// Ownership: content values are immutable and caller-owned. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum Group {
    /// Resolves a group into immutable child descriptions.
    /// Ownership: returned content is owned by caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    @NodeBuilder
    public static func content(@NodeBuilder _ content: () -> NodeContent) -> NodeContent {
        content()
    }
}

/// Empty is an explicit zero-child description.
/// Ownership: the empty value is caller-owned. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum Empty {
    /// Returns empty immutable content.
    /// Ownership: returned content is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public static var content: NodeContent { .empty }
}

/// Stable-key collection description for mutable data.
/// Ownership: descriptions own copied values. Isolation: none. Errors: duplicate IDs are reported.
/// Cancellation: not applicable.
public enum ForEach {
    /// Creates descriptors and diagnostics using stable IDs.
    /// Ownership: returned values own copied descriptors. Isolation: none. Errors: duplicate IDs
    /// are omitted after their first occurrence and listed in diagnostics. Cancellation: not applicable.
    public static func result<Data: Collection, ID: Hashable>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        _ make: (Data.Element) -> NodeDescriptor
    ) -> ForEachResult {
        var seen = Set<String>()
        var duplicates: [String] = []
        let descriptors = data.compactMap { element -> NodeDescriptor? in
            let key = String(describing: element[keyPath: id])
            guard seen.insert(key).inserted else {
                duplicates.append(key)
                return nil
            }
            let descriptor = make(element)
            return NodeDescriptor(typeName: descriptor.typeName, key: key)
        }
        return ForEachResult(
            content: .children(descriptors),
            diagnostics: NodeBuildDiagnostics(duplicateKeys: duplicates)
        )
    }

    /// Creates descriptors using stable IDs and drops duplicate keys after recording policy input.
    /// Ownership: returned content owns copied descriptors. Isolation: none. Errors: duplicate IDs
    /// are omitted after their first occurrence. Cancellation: not applicable.
    public static func content<Data: Collection, ID: Hashable>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        _ make: (Data.Element) -> NodeDescriptor
    ) -> NodeContent {
        result(data, id: id, make).content
    }
}
