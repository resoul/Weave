/// Immutable border painted around a node's layer bounds.
///
/// Ownership: the value owns copied color and width. Isolation: none. Errors: non-finite or
/// negative widths normalize to zero. Cancellation: not applicable.
public struct Border: Sendable, Hashable {
    public let color: ThemeColor
    public let width: Double

    /// Creates a border without changing layout or hit-test geometry.
    ///
    /// Ownership: the border copies its arguments. Isolation: none. Errors: invalid width is
    /// normalized to zero. Cancellation: not applicable.
    public init(color: ThemeColor, width: Double) {
        self.color = color
        self.width = width.isFinite ? max(0, width) : 0
    }
}

/// Immutable shadow painted by a node's native layer.
///
/// Ownership: the value owns copied color, metrics and offset. Isolation: none. Errors: opacity,
/// radius and offset components are normalized. Cancellation: not applicable.
public struct Shadow: Sendable, Hashable {
    public let color: ThemeColor
    public let opacity: Double
    public let radius: Double
    /// Shadow displacement vector in layout coordinates, not a position in the node tree.
    public let offset: LayoutPoint

    /// Creates a shadow without changing layout or hit-test geometry.
    ///
    /// Ownership: the shadow copies its arguments. Isolation: none. Errors: invalid opacity and
    /// radius are normalized. Cancellation: not applicable.
    public init(color: ThemeColor, opacity: Double, radius: Double, offset: LayoutPoint) {
        self.color = color
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0
        self.radius = radius.isFinite ? max(0, radius) : 0
        self.offset = offset
    }
}

/// Paint source supported by the synchronous native layer presentation path.
///
/// Ownership: the value owns its immutable token. Isolation: none. Errors: none. Cancellation:
/// not applicable. Gradient and image sources require a later async display contract.
public enum Fill: Sendable, Hashable {
    case none
    case color(ThemeColor)
    case theme(ThemeColorRole)
}

/// Semantic color resolved from the node's current environment theme.
/// Ownership: immutable value. Isolation: none. Errors: unknown roles are impossible by type.
/// Cancellation: not applicable.
public enum ThemeColorRole: Sendable, Hashable {
    case background, surface, primary, secondary, accent
    case text, textSecondary, border, error, success, warning
}

/// Paint-only presentation properties for a logical node.
///
/// Ownership: the value is immutable and owned by its Node. Isolation: none. Errors: invalid
/// radius is normalized to zero. Cancellation: not applicable. These values never participate in
/// FlexSolver measurement, layout placement or hit-test geometry.
public struct VisualStyle: Sendable, Hashable {
    public let background: Fill
    public let border: Border?
    public let cornerRadius: Double
    public let shadow: Shadow?

    /// Creates paint-only presentation properties.
    ///
    /// Ownership: the style copies its immutable values. Isolation: none. Errors: invalid radius
    /// is normalized to zero. Cancellation: not applicable.
    public init(
        background: Fill = .none,
        border: Border? = nil,
        cornerRadius: Double = 0,
        shadow: Shadow? = nil
    ) {
        self.background = background
        self.border = border
        self.cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 0
        self.shadow = shadow
    }
}
