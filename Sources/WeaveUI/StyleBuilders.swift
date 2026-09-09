import Foundation

/// A value type that can be created from a mutable draft.
///
/// Ownership: the draft is owned by the caller and copied into the returned value. Isolation:
/// none. Errors: implementations normalize invalid values according to their existing
/// initializer contracts. Cancellation: not applicable.
public protocol StyleBuildable {
    associatedtype Draft

    /// Creates a draft containing the type's documented defaults.
    /// Ownership: the returned draft is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    static func draft() -> Draft

    /// Converts a draft into the immutable value.
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: invalid
    /// values are handled by the conforming type's existing initializer. Cancellation: not applicable.
    static func bake(_ draft: Draft) -> Self
}

/// Builds a style value by mutating its type-specific draft.
///
/// Ownership: the returned value owns copies of the draft data. Isolation: none. Errors: invalid
/// values are normalized by the style initializer. Cancellation: not applicable.
public func buildStyle<T: StyleBuildable>(
    _ type: T.Type,
    _ configure: (inout T.Draft) -> Void
) -> T {
    var draft = T.draft()
    configure(&draft)
    return T.bake(draft)
}

extension TextStyle: StyleBuildable {
    /// Mutable construction draft for `TextStyle`.
    ///
    /// Ownership: values are copied into the baked style. Isolation: none. Errors: values are
    /// normalized when the draft is baked. Cancellation: not applicable.
    public struct Draft: Sendable {
        public var fontName: String
        public var size: Double
        public var lineHeight: Double
        public var bold: Bool
        public var color: ThemeColor?

        /// Creates a draft using the standard text-style defaults.
        ///
        /// Ownership: the returned draft is owned by the caller. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init(
            fontName: String = "system",
            size: Double = 17,
            lineHeight: Double = 0,
            bold: Bool = false,
            color: ThemeColor? = nil
        ) {
            self.fontName = fontName
            self.size = size
            self.lineHeight = lineHeight
            self.bold = bold
            self.color = color
        }
    }

    public static func draft() -> Draft { Draft() }

    public static func bake(_ draft: Draft) -> TextStyle {
        TextStyle(
            fontName: draft.fontName,
            pointSize: draft.size,
            lineHeight: draft.lineHeight,
            bold: draft.bold,
            color: draft.color
        )
    }

    /// Creates an immutable text style from a mutable draft closure.
    ///
    /// Ownership: the resulting style owns copied values. Isolation: none. Errors: invalid
    /// values are normalized by `TextStyle.init`. Cancellation: not applicable.
    public init(_ configure: (inout Draft) -> Void) {
        self = buildStyle(TextStyle.self, configure)
    }
}

extension LayoutStyle: StyleBuildable {
    /// Mutable construction draft for `LayoutStyle`.
    ///
    /// Ownership: values are copied into the baked style. Isolation: none. Errors: values are
    /// normalized when the draft is baked. Cancellation: not applicable.
    public struct Draft: Sendable {
        public var flexDirection: FlexDirection
        public var flexWrap: FlexWrap
        public var justifyContent: JustifyContent
        public var alignContent: AlignContent
        public var alignItems: AlignItems
        public var alignSelf: AlignSelf
        public var flexGrow: Double
        public var flexShrink: Double
        public var flexBasis: SizeValue
        public var width: SizeValue
        public var height: SizeValue
        public var minWidth: SizeValue
        public var maxWidth: SizeValue
        public var minHeight: SizeValue
        public var maxHeight: SizeValue
        public var aspectRatio: Double?
        public var padding: DirectionalEdgeInsets
        public var margin: DirectionalEdgeInsets
        public var gap: Double
        public var crossGap: Double
        public var positionType: PositionType
        public var offsets: DirectionalEdgeOffsets
        public var visual: LayoutVisualProperties

        /// Creates a draft using the standard layout-style defaults.
        ///
        /// Ownership: the returned draft is owned by the caller. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init(
            flexDirection: FlexDirection = .row,
            flexWrap: FlexWrap = .noWrap,
            justifyContent: JustifyContent = .start,
            alignContent: AlignContent = .stretch,
            alignItems: AlignItems = .stretch,
            alignSelf: AlignSelf = .auto,
            flexGrow: Double = 0,
            flexShrink: Double = 1,
            flexBasis: SizeValue = .auto,
            width: SizeValue = .auto,
            height: SizeValue = .auto,
            minWidth: SizeValue = .auto,
            maxWidth: SizeValue = .auto,
            minHeight: SizeValue = .auto,
            maxHeight: SizeValue = .auto,
            aspectRatio: Double? = nil,
            padding: DirectionalEdgeInsets = DirectionalEdgeInsets(),
            margin: DirectionalEdgeInsets = DirectionalEdgeInsets(),
            gap: Double = 0,
            crossGap: Double = 0,
            positionType: PositionType = .relative,
            offsets: DirectionalEdgeOffsets = DirectionalEdgeOffsets(),
            visual: LayoutVisualProperties = LayoutVisualProperties()
        ) {
            self.flexDirection = flexDirection
            self.flexWrap = flexWrap
            self.justifyContent = justifyContent
            self.alignContent = alignContent
            self.alignItems = alignItems
            self.alignSelf = alignSelf
            self.flexGrow = flexGrow
            self.flexShrink = flexShrink
            self.flexBasis = flexBasis
            self.width = width
            self.height = height
            self.minWidth = minWidth
            self.maxWidth = maxWidth
            self.minHeight = minHeight
            self.maxHeight = maxHeight
            self.aspectRatio = aspectRatio
            self.padding = padding
            self.margin = margin
            self.gap = gap
            self.crossGap = crossGap
            self.positionType = positionType
            self.offsets = offsets
            self.visual = visual
        }

        /// Copies every field from an existing immutable layout style.
        ///
        /// Ownership: the returned draft owns copied values. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init(_ style: LayoutStyle) {
            self.init(
                flexDirection: style.flexDirection,
                flexWrap: style.flexWrap,
                justifyContent: style.justifyContent,
                alignContent: style.alignContent,
                alignItems: style.alignItems,
                alignSelf: style.alignSelf,
                flexGrow: style.flexGrow,
                flexShrink: style.flexShrink,
                flexBasis: style.flexBasis,
                width: style.width,
                height: style.height,
                minWidth: style.minWidth,
                maxWidth: style.maxWidth,
                minHeight: style.minHeight,
                maxHeight: style.maxHeight,
                aspectRatio: style.aspectRatio,
                padding: style.padding,
                margin: style.margin,
                gap: style.gap,
                crossGap: style.crossGap,
                positionType: style.positionType,
                offsets: style.offsets,
                visual: style.visual
            )
        }
    }

    public static func draft() -> Draft { Draft() }

    public static func bake(_ draft: Draft) -> LayoutStyle {
        LayoutStyle(
            flexDirection: draft.flexDirection,
            flexWrap: draft.flexWrap,
            justifyContent: draft.justifyContent,
            alignContent: draft.alignContent,
            alignItems: draft.alignItems,
            alignSelf: draft.alignSelf,
            flexGrow: draft.flexGrow,
            flexShrink: draft.flexShrink,
            flexBasis: draft.flexBasis,
            width: draft.width,
            height: draft.height,
            minWidth: draft.minWidth,
            maxWidth: draft.maxWidth,
            minHeight: draft.minHeight,
            maxHeight: draft.maxHeight,
            aspectRatio: draft.aspectRatio,
            padding: draft.padding,
            margin: draft.margin,
            gap: draft.gap,
            crossGap: draft.crossGap,
            positionType: draft.positionType,
            offsets: draft.offsets,
            visual: draft.visual
        )
    }

    /// Creates an immutable layout style from a mutable draft closure.
    ///
    /// Ownership: the resulting style owns copied values. Isolation: none. Errors: invalid
    /// values are normalized by `LayoutStyle.init`. Cancellation: not applicable.
    public init(_ configure: (inout Draft) -> Void) {
        self = buildStyle(LayoutStyle.self, configure)
    }
}

extension VisualStyle: StyleBuildable {
    /// Mutable construction draft for `VisualStyle`.
    ///
    /// Ownership: the draft is owned by its caller and copied when baked. Isolation: none.
    /// Errors: invalid values are normalized by `VisualStyle.init`. Cancellation: not applicable.
    public struct Draft: Sendable {
        public var background: Fill
        public var border: Border?
        public var cornerRadius: Double
        public var shadow: Shadow?

        /// Creates a draft using the standard visual-style defaults.
        ///
        /// Ownership: the returned draft is owned by the caller. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init(
            background: Fill = .none,
            border: Border? = nil,
            cornerRadius: Double = 0,
            shadow: Shadow? = nil
        ) {
            self.background = background
            self.border = border
            self.cornerRadius = cornerRadius
            self.shadow = shadow
        }

        /// Copies every field from an existing immutable visual style.
        ///
        /// Ownership: the returned draft owns copied values. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init(_ style: VisualStyle) {
            self.init(
                background: style.background,
                border: style.border,
                cornerRadius: style.cornerRadius,
                shadow: style.shadow
            )
        }
    }

    /// Creates a draft containing the type's documented defaults.
    ///
    /// Ownership: the returned draft is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public static func draft() -> Draft { Draft() }

    /// Converts a draft into an immutable visual style.
    ///
    /// Ownership: the returned style owns copied values. Isolation: none. Errors: invalid values
    /// are normalized by `VisualStyle.init`. Cancellation: not applicable.
    public static func bake(_ draft: Draft) -> VisualStyle {
        VisualStyle(
            background: draft.background,
            border: draft.border,
            cornerRadius: draft.cornerRadius,
            shadow: draft.shadow
        )
    }

    /// Creates an immutable visual style from a mutable draft closure.
    ///
    /// Ownership: the returned style owns copied values. Isolation: none. Errors: invalid values
    /// are normalized by `VisualStyle.init`. Cancellation: not applicable.
    public init(_ configure: (inout Draft) -> Void) {
        self = buildStyle(VisualStyle.self, configure)
    }
}
