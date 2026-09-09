import Foundation

/// Describes the logical direction used to resolve leading and trailing edges.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum LayoutDirection: Sendable, Hashable {
    case leftToRight
    case rightToLeft
}

/// A finite, non-negative size expressed in points, a parent fraction, or intrinsic size.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// associated values resolve to `nil`. Cancellation: not applicable.
public enum SizeValue: Sendable, Hashable {
    case points(Double)
    case fraction(Double)
    case auto

    /// Resolves the value against an optional parent dimension.
    ///
    /// Ownership: the returned scalar is owned by the caller. Isolation: none. Errors: invalid
    /// values and fractions without a parent return `nil`. Cancellation: not applicable.
    public func resolved(parent: Double?) -> Double? {
        switch self {
        case let .points(value):
            return value.isFinite && value >= 0 ? value : nil
        case let .fraction(value):
            guard value.isFinite, value >= 0, value <= 1, let parent, parent.isFinite, parent >= 0
            else {
                return nil
            }
            return parent * value
        case .auto:
            return nil
        }
    }
}

/// A constraint applied to one layout axis.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// numeric payloads are treated as unspecified by `normalized()`. Cancellation: not applicable.
public enum SizeConstraintAxis: Sendable, Hashable {
    case unspecified
    case atMost(Double)
    case exact(Double)

    /// Returns a safe constraint, clamping negative values and ignoring non-finite values.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func normalized() -> Self {
        switch self {
        case .unspecified: return .unspecified
        case let .atMost(value): return value.isFinite && value >= 0 ? .atMost(value) : .unspecified
        case let .exact(value): return value.isFinite && value >= 0 ? .exact(value) : .unspecified
        }
    }
}

/// Independent width and height constraints for a measurement pass.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct SizeConstraint: Sendable, Hashable {
    public let width: SizeConstraintAxis
    public let height: SizeConstraintAxis

    /// Creates width and height constraints.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(width: SizeConstraintAxis = .unspecified, height: SizeConstraintAxis = .unspecified)
    {
        self.width = width.normalized()
        self.height = height.normalized()
    }
}

/// A point in the framework's platform-neutral layout coordinate space.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    /// Creates a point, replacing non-finite coordinates with zero.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(x: Double, y: Double) {
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
    }
}

/// The measured size returned by a layout node.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct MeasuredSize: Sendable, Hashable {
    public let width: Double
    public let height: Double

    /// Creates a non-negative measured size.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(width: Double, height: Double) {
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }
}

/// A rectangle in the framework's platform-neutral layout coordinate space.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutFrame: Sendable, Hashable {
    public let origin: LayoutPoint
    public let width: Double
    public let height: Double

    /// Creates a non-negative frame.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(origin: LayoutPoint = LayoutPoint(x: 0, y: 0), width: Double, height: Double) {
        self.origin = origin
        self.width = width.isFinite ? max(0, width) : 0
        self.height = height.isFinite ? max(0, height) : 0
    }
}

/// Logical edge insets that resolve to physical edges during a layout pass.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// values are clamped to zero. Cancellation: not applicable.
public struct DirectionalEdgeInsets: Sendable, Hashable {
    public let top: Double
    public let leading: Double
    public let bottom: Double
    public let trailing: Double

    /// Creates logical edge insets.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = Self.sanitize(top)
        self.leading = Self.sanitize(leading)
        self.bottom = Self.sanitize(bottom)
        self.trailing = Self.sanitize(trailing)
    }

    /// Resolves logical edges without guessing a direction at construction time.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func resolved(for direction: LayoutDirection) -> PhysicalEdgeInsets {
        switch direction {
        case .leftToRight:
            return PhysicalEdgeInsets(top: top, left: leading, bottom: bottom, right: trailing)
        case .rightToLeft:
            return PhysicalEdgeInsets(top: top, left: trailing, bottom: bottom, right: leading)
        }
    }

    private static func sanitize(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}

/// Physical edge insets used only after direction resolution.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct PhysicalEdgeInsets: Sendable, Hashable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    /// Creates physical edge insets.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double, left: Double, bottom: Double, right: Double) {
        self.top = max(0, top.isFinite ? top : 0)
        self.left = max(0, left.isFinite ? left : 0)
        self.bottom = max(0, bottom.isFinite ? bottom : 0)
        self.right = max(0, right.isFinite ? right : 0)
    }
}

/// Logical optional offsets resolved to physical edges during a layout pass.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: invalid
/// values become `nil`. Cancellation: not applicable.
public struct DirectionalEdgeOffsets: Sendable, Hashable {
    public let top: Double?
    public let leading: Double?
    public let bottom: Double?
    public let trailing: Double?

    /// Creates logical offsets.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: non-finite
    /// values become `nil`. Cancellation: not applicable.
    public init(
        top: Double? = nil, leading: Double? = nil, bottom: Double? = nil, trailing: Double? = nil
    ) {
        self.top = Self.sanitize(top)
        self.leading = Self.sanitize(leading)
        self.bottom = Self.sanitize(bottom)
        self.trailing = Self.sanitize(trailing)
    }

    /// Resolves logical offsets using the supplied direction.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func resolved(for direction: LayoutDirection) -> PhysicalEdgeOffsets {
        switch direction {
        case .leftToRight:
            return PhysicalEdgeOffsets(top: top, left: leading, bottom: bottom, right: trailing)
        case .rightToLeft:
            return PhysicalEdgeOffsets(top: top, left: trailing, bottom: bottom, right: leading)
        }
    }

    private static func sanitize(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

/// Physical offsets used only after direction resolution.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct PhysicalEdgeOffsets: Sendable, Hashable {
    public let top: Double?
    public let left: Double?
    public let bottom: Double?
    public let right: Double?

    /// Creates physical optional offsets.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(top: Double?, left: Double?, bottom: Double?, right: Double?) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

/// Immutable visual properties kept separate from measurement inputs.
///
/// Ownership: the value is immutable and owned by its caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutVisualProperties: Sendable, Hashable {
    public let zIndex: Int
    public let overflow: OverflowPolicy
    public let opacity: Double
    public let transform: LayoutTransform

    /// Creates visual properties.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(zIndex: Int = 0, overflow: OverflowPolicy = .visible) {
        self.init(zIndex: zIndex, overflow: overflow, opacity: 1, transform: .identity)
    }

    /// Creates visual properties with explicit presentation state.
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: invalid
    /// opacity is clamped. Cancellation: not applicable.
    public init(
        zIndex: Int,
        overflow: OverflowPolicy,
        opacity: Double,
        transform: LayoutTransform
    ) {
        self.zIndex = zIndex
        self.overflow = overflow
        self.opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 1
        self.transform = transform
    }
}

/// A platform-neutral affine transform used by hit testing around a node frame origin.
/// Ownership: the value is immutable and copied by layout descriptions. Isolation: none.
/// Errors: non-finite values normalize to identity components. Cancellation: not applicable.
public struct LayoutTransform: Sendable, Hashable {
    public let scaleX: Double
    public let scaleY: Double
    public let rotationRadians: Double
    public let translationX: Double
    public let translationY: Double

    /// Identity transform.
    /// Ownership: immutable shared value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let identity = LayoutTransform()

    /// Creates an affine scale/rotation/translation transform.
    /// Ownership: values are copied. Isolation: none. Errors: invalid values normalize safely.
    /// Cancellation: not applicable.
    public init(
        scaleX: Double = 1,
        scaleY: Double = 1,
        rotationRadians: Double = 0,
        translationX: Double = 0,
        translationY: Double = 0
    ) {
        self.scaleX = Self.valid(scaleX, fallback: 1)
        self.scaleY = Self.valid(scaleY, fallback: 1)
        self.rotationRadians = Self.valid(rotationRadians, fallback: 0)
        self.translationX = Self.valid(translationX, fallback: 0)
        self.translationY = Self.valid(translationY, fallback: 0)
    }

    /// Converts a point from presentation space into this node's local space.
    /// Ownership: the returned point is a value. Isolation: none. Errors: singular scales use one.
    /// Cancellation: not applicable.
    public func inverseApplying(_ point: LayoutPoint, around origin: LayoutPoint) -> LayoutPoint {
        let translatedX = point.x - origin.x - translationX
        let translatedY = point.y - origin.y - translationY
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        let rotatedX = cosine * translatedX + sine * translatedY
        let rotatedY = -sine * translatedX + cosine * translatedY
        return LayoutPoint(
            x: origin.x + rotatedX / nonSingular(scaleX),
            y: origin.y + rotatedY / nonSingular(scaleY)
        )
    }

    private static func valid(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? value : fallback
    }

    private func nonSingular(_ value: Double) -> Double { abs(value) < 0.000001 ? 1 : value }
}

/// Main-axis arrangement for a layout node. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FlexDirection: Sendable, Hashable { case row, column, rowReverse, columnReverse }
/// Line wrapping behavior. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FlexWrap: Sendable, Hashable { case noWrap, wrap, wrapReverse }
/// Main-axis distribution. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum JustifyContent: Sendable, Hashable {
    case start, end, center, spaceBetween, spaceAround, spaceEvenly
}
/// Cross-axis distribution for wrapped flex lines. Ownership: value. Isolation: none. Errors:
/// none. Cancellation: not applicable.
public enum AlignContent: Sendable, Hashable {
    case start, end, center, stretch, spaceBetween, spaceAround, spaceEvenly
}
/// Cross-axis alignment. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AlignItems: Sendable, Hashable { case stretch, start, end, center, baseline }
/// Per-node cross-axis alignment override. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AlignSelf: Sendable, Hashable { case auto, stretch, start, end, center, baseline }
/// Positioning mode. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum PositionType: Sendable, Hashable { case relative, absolute }
/// Clipping behavior. Ownership: value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum OverflowPolicy: Sendable, Hashable { case visible, hidden, scroll }

/// Immutable style inputs for a layout node.
///
/// Ownership: the style is a value copied by layout snapshots. Isolation: none. Errors: invalid
/// dimensions are ignored by measurement. Cancellation: not applicable.
public struct LayoutStyle: Sendable, Hashable {
    public let flexDirection: FlexDirection
    public let flexWrap: FlexWrap
    public let justifyContent: JustifyContent
    public let alignContent: AlignContent
    public let alignItems: AlignItems
    public let alignSelf: AlignSelf
    public let flexGrow: Double
    public let flexShrink: Double
    public let flexBasis: SizeValue
    public let width: SizeValue
    public let height: SizeValue
    public let minWidth: SizeValue
    public let maxWidth: SizeValue
    public let minHeight: SizeValue
    public let maxHeight: SizeValue
    public let aspectRatio: Double?
    public let padding: DirectionalEdgeInsets
    public let margin: DirectionalEdgeInsets
    public let gap: Double
    public let crossGap: Double
    public let positionType: PositionType
    public let offsets: DirectionalEdgeOffsets
    public let visual: LayoutVisualProperties

    /// Creates an immutable layout style with safe defaults.
    ///
    /// Ownership: the returned style is owned by the caller. Isolation: none. Errors: invalid
    /// flex and gap values are clamped; invalid aspect ratios are ignored. Cancellation: not applicable.
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
        self.flexDirection = flexDirection; self.flexWrap = flexWrap;
        self.justifyContent = justifyContent
        self.alignContent = alignContent
        self.alignItems = alignItems; self.alignSelf = alignSelf
        self.flexGrow = Self.nonNegative(flexGrow); self.flexShrink = Self.nonNegative(flexShrink)
        self.flexBasis = flexBasis
        self.width = width; self.height = height; self.minWidth = minWidth; self.maxWidth = maxWidth
        self.minHeight = minHeight; self.maxHeight = maxHeight
        self.aspectRatio =
            if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 { aspectRatio } else { nil }
        self.padding = padding; self.margin = margin; self.gap = Self.nonNegative(gap);
        self.crossGap = Self.nonNegative(crossGap)
        self.positionType = positionType; self.offsets = offsets; self.visual = visual
    }

    /// Measures this style under parent dimensions and axis constraints.
    ///
    /// Ownership: the returned measurement is owned by the caller. Isolation: none. Errors: no
    /// error is thrown; unresolved or invalid values resolve to zero. Cancellation: not applicable.
    public func measured(
        parentSize: MeasuredSize? = nil, constraint: SizeConstraint = SizeConstraint()
    ) -> MeasuredSize {
        var width = width.resolved(parent: parentSize?.width)
        var height = height.resolved(parent: parentSize?.height)
        if width == nil, let ratio = aspectRatio, let height { width = height * ratio }
        if height == nil, let ratio = aspectRatio, let width { height = width / ratio }
        let measuredWidth = apply(
            width ?? 0, minimum: minWidth, maximum: maxWidth, parent: parentSize?.width,
            axis: constraint.width)
        let measuredHeight = apply(
            height ?? 0, minimum: minHeight, maximum: maxHeight, parent: parentSize?.height,
            axis: constraint.height)
        return MeasuredSize(width: measuredWidth, height: measuredHeight)
    }

    private func apply(
        _ value: Double, minimum: SizeValue, maximum: SizeValue, parent: Double?,
        axis: SizeConstraintAxis
    ) -> Double {
        var result = value
        if let lower = minimum.resolved(parent: parent) { result = max(result, lower) }
        if let upper = maximum.resolved(parent: parent) { result = min(result, upper) }
        switch axis {
        case .unspecified: break
        case let .atMost(limit): result = min(result, limit)
        case let .exact(exact): result = exact
        }
        return result
    }

    private static func nonNegative(_ value: Double) -> Double {
        value.isFinite ? max(0, value) : 0
    }
}
