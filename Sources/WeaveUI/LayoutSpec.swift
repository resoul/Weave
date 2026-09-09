/// Logical axis for stack specifications.
///
/// Ownership: the value is immutable and owned by its spec. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum LayoutSpecAxis: Sendable, Hashable { case horizontal, vertical }

/// Immutable context passed to a LayoutSpec measurement.
///
/// Ownership: the context is a value owned by the layout caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutSpecContext: Sendable, Hashable {
    public let constraint: SizeConstraint
    public let direction: LayoutDirection

    /// Creates a spec context.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        constraint: SizeConstraint = SizeConstraint(), direction: LayoutDirection = .leftToRight
    ) {
        self.constraint = constraint
        self.direction = direction
    }
}

/// Value description resolved during layout without creating a Node or platform object.
/// Ownership: spec owns immutable values. Isolation: none. Errors: none. Cancellation: not applicable.
///
/// Ownership: a spec owns its immutable child descriptions. Isolation: none. Errors: invalid
/// values normalize through `MeasuredSize`. Cancellation: not applicable.
public protocol LayoutSpec: Sendable {
    /// Measures the description under a snapshot context.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    func measure(in context: LayoutSpecContext) -> MeasuredSize
}

/// Empty description that occupies no space.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct EmptySpec: LayoutSpec, Hashable {
    /// Creates an empty spec.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}
    /// Returns zero size.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        MeasuredSize(width: 0, height: 0)
    }
}

/// Stacks children along one logical axis with spacing.
/// Ownership: spec owns immutable child descriptions. Isolation: none. Errors: none. Cancellation: not applicable.
public struct StackSpec: LayoutSpec {
    public let axis: LayoutSpecAxis
    public let spacing: Double
    public let children: [any LayoutSpec]

    /// Creates a stack description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(axis: LayoutSpecAxis, spacing: Double = 0, children: [any LayoutSpec] = []) {
        self.axis = axis
        self.spacing = spacing.isFinite ? max(0, spacing) : 0
        self.children = children
    }

    /// Measures children bottom-up.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        let values = children.map { $0.measure(in: context) }
        guard let first = values.first else { return MeasuredSize(width: 0, height: 0) }
        switch axis {
        case .horizontal:
            return MeasuredSize(
                width: values.reduce(0) { $0 + $1.width } + spacing * Double(values.count - 1),
                height: values.map(\.height).max() ?? first.height)
        case .vertical:
            return MeasuredSize(
                width: values.map(\.width).max() ?? first.width,
                height: values.reduce(0) { $0 + $1.height } + spacing * Double(values.count - 1))
        }
    }
}

/// Adds directional padding around a child description.
/// Ownership: spec owns immutable child description. Isolation: none. Errors: none. Cancellation: not applicable.
public struct InsetSpec: LayoutSpec {
    public let insets: DirectionalEdgeInsets
    public let child: any LayoutSpec
    /// Creates an inset description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(insets: DirectionalEdgeInsets, child: any LayoutSpec) {
        self.insets = insets; self.child = child
    }
    /// Measures the child with reduced constraints and restores insets.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        let physical = insets.resolved(for: context.direction)
        let childSize = child.measure(
            in: LayoutSpecContext(constraint: context.constraint, direction: context.direction))
        return MeasuredSize(
            width: childSize.width + physical.left + physical.right,
            height: childSize.height + physical.top + physical.bottom)
    }
}

/// Measures to the largest of background and overlay descriptions.
/// Ownership: spec owns immutable child descriptions. Isolation: none. Errors: none. Cancellation: not applicable.
public struct OverlaySpec: LayoutSpec {
    public let child: any LayoutSpec
    public let overlay: any LayoutSpec
    /// Creates an overlay description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(child: any LayoutSpec, overlay: any LayoutSpec) {
        self.child = child; self.overlay = overlay
    }
    /// Measures both layers and returns their union.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        let base = child.measure(in: context); let top = overlay.measure(in: context)
        return MeasuredSize(width: max(base.width, top.width), height: max(base.height, top.height))
    }
}

/// Keeps a child size while expressing centered placement for the layout phase.
/// Ownership: spec owns immutable child description. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CenterSpec: LayoutSpec {
    public let child: any LayoutSpec
    /// Creates a center description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(child: any LayoutSpec) { self.child = child }
    /// Measures the child unchanged.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        child.measure(in: context)
    }
}

/// Applies an aspect ratio to a child or constrained box.
/// Ownership: spec owns immutable child description. Isolation: none. Errors: none. Cancellation: not applicable.
public struct RatioSpec: LayoutSpec {
    public let ratio: Double
    public let child: any LayoutSpec
    /// Creates a ratio description; invalid ratios become one.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(ratio: Double, child: any LayoutSpec) {
        self.ratio = ratio.isFinite && ratio > 0 ? ratio : 1; self.child = child
    }
    /// Measures with ratio when one axis is constrained.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        let childSize = child.measure(in: context)
        if childSize.width > 0, childSize.height == 0 {
            return MeasuredSize(width: childSize.width, height: childSize.width / ratio)
        }
        if childSize.height > 0, childSize.width == 0 {
            return MeasuredSize(width: childSize.height * ratio, height: childSize.height)
        }
        return childSize
    }
}

/// Positions children in a containing block; measurement is the union of child sizes.
/// Ownership: spec owns immutable child descriptions. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AbsoluteSpec: LayoutSpec {
    public let children: [any LayoutSpec]
    /// Creates an absolute container description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(children: [any LayoutSpec] = []) { self.children = children }
    /// Measures the union of absolute children.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        let values = children.map { $0.measure(in: context) }
        return MeasuredSize(
            width: values.map(\.width).max() ?? 0, height: values.map(\.height).max() ?? 0)
    }
}

/// Adds a background description without changing content size.
/// Ownership: spec owns immutable child descriptions. Isolation: none. Errors: none. Cancellation: not applicable.
public struct BackgroundSpec: LayoutSpec {
    public let child: any LayoutSpec
    public let background: any LayoutSpec
    /// Creates a background description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(child: any LayoutSpec, background: any LayoutSpec) {
        self.child = child; self.background = background
    }
    /// Measures content; background is constrained to the same logical box.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        child.measure(in: context)
    }
}

/// Transparent wrapper used by composition and modifiers.
/// Ownership: spec owns immutable child description. Isolation: none. Errors: none. Cancellation: not applicable.
public struct WrapperSpec: LayoutSpec {
    public let child: any LayoutSpec
    /// Creates a wrapper description.
    /// Ownership: caller owns the value. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(child: any LayoutSpec) { self.child = child }
    /// Measures the wrapped child unchanged.
    /// Ownership: result is owned by caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public func measure(in context: LayoutSpecContext) -> MeasuredSize {
        child.measure(in: context)
    }
}
