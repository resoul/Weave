/// Result builder for an imperative tree of live nodes.
///
/// Ownership: the returned array borrows the nodes until the receiving `Node` attaches them.
/// Isolation: node construction and application are MainActor-owned. Errors: invalid hierarchy
/// operations are handled by `Node.addSubnode(_:)`. Cancellation: not applicable.
@resultBuilder public enum NodeTreeBuilder {
    public static func buildBlock(_ components: [Node]...) -> [Node] {
        components.flatMap { $0 }
    }

    public static func buildExpression(_ expression: Node) -> [Node] { [expression] }

    public static func buildExpression(_ expression: [Node]) -> [Node] { expression }

    public static func buildOptional(_ component: [Node]?) -> [Node] { component ?? [] }

    public static func buildEither(first component: [Node]) -> [Node] { component }

    public static func buildEither(second component: [Node]) -> [Node] { component }

    public static func buildArray(_ components: [[Node]]) -> [Node] {
        components.flatMap { $0 }
    }

    public static func buildLimitedAvailability(_ component: [Node]) -> [Node] { component }
}

extension Node {
    /// Establishes an explicit safe-area layout boundary for this node's subtree.
    /// Ownership: the node stores the immutable edge policy. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    @discardableResult
    public func ignoresSafeArea(edges: SafeAreaEdges = .all) -> Self {
        safeAreaBoundary = edges != .none
        safeAreaIgnoredEdges = edges
        setNeedsLayout()
        return self
    }

    /// Mutates a copy of the current layout style and applies it as one new immutable value.
    ///
    /// Ownership: the node retains the baked style. Isolation: MainActor. Errors: style values
    /// are normalized by `LayoutStyle.init`. Cancellation: not applicable.
    @discardableResult
    public func style(_ configure: (inout LayoutStyle.Draft) -> Void) -> Self {
        var draft = LayoutStyle.Draft(style)
        configure(&draft)
        style = LayoutStyle.bake(draft)
        return self
    }

    /// Mutates a copy of the current paint-only appearance and applies it as one immutable value.
    ///
    /// Ownership: the node retains the baked appearance. Isolation: MainActor. Errors: values
    /// are normalized by `VisualStyle.init`. Cancellation: not applicable.
    @discardableResult
    public func appearance(_ configure: (inout VisualStyle.Draft) -> Void) -> Self {
        var draft = VisualStyle.Draft(appearance)
        configure(&draft)
        appearance = VisualStyle.bake(draft)
        return self
    }

    /// Applies point dimensions to the selected axes while preserving all other style fields.
    ///
    /// Ownership: the node retains the updated immutable style. Isolation: MainActor. Errors:
    /// invalid values are normalized by `LayoutStyle.init`. Cancellation: not applicable.
    @discardableResult
    public func frame(width: Double? = nil, height: Double? = nil) -> Self {
        style { draft in
            if let width { draft.width = .points(width) }
            if let height { draft.height = .points(height) }
        }
    }

    /// Builds and attaches children in source order using the node's existing hierarchy policy.
    ///
    /// Ownership: the receiver owns attached children. Isolation: MainActor. Errors: self/cycle
    /// insertions are ignored by `addSubnode(_:)`. Cancellation: not applicable.
    @discardableResult
    public func addSubnodes(@NodeTreeBuilder _ children: @MainActor () -> [Node]) -> Self {
        for child in children() {
            addSubnode(child)
        }
        return self
    }

    /// Runs synchronous configuration against this node and returns it for fluent chaining.
    ///
    /// Ownership: the node remains owned by the caller or its eventual parent. Isolation:
    /// MainActor. Errors: closure errors cannot be thrown by this nonthrowing API. Cancellation:
    /// this is not a lifecycle or async-work boundary; resource work must be owned by mount/connect.
    @discardableResult
    public func configure(_ body: @MainActor (Self) -> Void) -> Self {
        body(self)
        return self
    }
}
