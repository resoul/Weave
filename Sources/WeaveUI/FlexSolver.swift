/// Immutable intrinsic metrics supplied by a content node to the measure pass.
///
/// Ownership: the metrics are copied into a snapshot. Isolation: none. Errors: invalid values are
/// normalized by `MeasuredSize`. Cancellation: not applicable.
public struct LayoutContentMetrics: Sendable, Hashable {
    public let intrinsic: MeasuredSize
    public let firstBaseline: Double?

    /// Creates content metrics for an intrinsic measurement.
    ///
    /// Ownership: the returned value is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        intrinsic: MeasuredSize = MeasuredSize(width: 0, height: 0), firstBaseline: Double? = nil
    ) {
        self.intrinsic = intrinsic
        self.firstBaseline = firstBaseline.map { $0.isFinite ? max(0, $0) : 0 }
    }
}

/// A complete immutable input tree for a background measure pass.
///
/// Ownership: the snapshot owns copied styles, metrics and child snapshots. Isolation: none.
/// Errors: none. Cancellation: cancellation is owned by the caller's worker task.
public struct LayoutInputSnapshot: Sendable, Hashable {
    public let identity: UInt64
    public let style: LayoutStyle
    public let content: LayoutContentMetrics
    public let children: [LayoutInputSnapshot]
    public let direction: LayoutDirection
    public let environmentRevision: UInt64
    public let contentRevision: UInt64

    /// Creates a tree snapshot without retaining a live Node or platform object.
    ///
    /// Ownership: all values are copied into the returned snapshot. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        identity: UInt64,
        style: LayoutStyle = LayoutStyle(),
        content: LayoutContentMetrics = LayoutContentMetrics(),
        children: [LayoutInputSnapshot] = [],
        direction: LayoutDirection = .leftToRight,
        environmentRevision: UInt64 = 0,
        contentRevision: UInt64 = 0
    ) {
        self.identity = identity
        self.style = style
        self.content = content
        self.children = children
        self.direction = direction
        self.environmentRevision = environmentRevision
        self.contentRevision = contentRevision
    }
}

/// Stable cache identity for one measure result.
///
/// Ownership: the key is an immutable value owned by the cache caller. Isolation: none. Errors:
/// none. Cancellation: not applicable.
public struct LayoutMeasureCacheKey: Sendable, Hashable {
    public let treeIdentity: UInt64
    public let contentRevision: UInt64
    public let environmentRevision: UInt64
    public let constraint: SizeConstraint
    public let direction: LayoutDirection

    /// Creates a cache key from snapshot revisions and constraints.
    ///
    /// Ownership: the returned key is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        treeIdentity: UInt64,
        contentRevision: UInt64,
        environmentRevision: UInt64,
        constraint: SizeConstraint,
        direction: LayoutDirection
    ) {
        self.treeIdentity = treeIdentity
        self.contentRevision = contentRevision
        self.environmentRevision = environmentRevision
        self.constraint = constraint
        self.direction = direction
    }
}

/// Per-request LRU cache for complete flex measurement results.
/// Ownership: the caller owns the cache for one layout request. Isolation: none. Errors: none.
/// Cancellation: discarded with the owning request.
public struct FlexMeasureCache: Sendable {
    public static let capacity = 64

    private var entries: [(key: LayoutMeasureCacheKey, result: FlexMeasureResult)] = []

    /// Creates an empty request-local cache. Ownership: caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init() {}

    /// Stores a result and evicts the least-recently-used entry when full.
    /// Ownership: the cache copies the immutable result. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public mutating func store(key: LayoutMeasureCacheKey, result: FlexMeasureResult) {
        entries.removeAll { $0.key == key }
        if entries.count >= Self.capacity { entries.removeFirst() }
        entries.append((key: key, result: result))
    }

    /// Looks up a result and refreshes its LRU position on a hit.
    /// Ownership: returned result is an immutable value. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public mutating func lookup(key: LayoutMeasureCacheKey) -> FlexMeasureResult? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.result
    }
}

/// The value returned by a pure measure operation.
///
/// Ownership: the result owns its immutable size and key. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutMeasureResult: Sendable, Hashable {
    public let size: MeasuredSize
    public let cacheKey: LayoutMeasureCacheKey

    /// Creates a measured result.
    ///
    /// Ownership: the returned result is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(size: MeasuredSize, cacheKey: LayoutMeasureCacheKey) {
        self.size = size
        self.cacheKey = cacheKey
    }
}

/// Per-item resolved geometry within a flex line after grow/shrink resolution.
/// Ownership: immutable value owned by the measurement result. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FlexLineItem: Sendable, Hashable {
    /// Stable snapshot identity of the child.
    public let identity: UInt64
    /// Resolved size on the container main axis.
    public let mainSize: Double
    /// Resolved size on the container cross axis.
    public let crossSize: Double
    /// Always `nil` in T-79. Populated by `MeasurableNode` in T-81.
    public let baseline: Double?

    /// Creates immutable item geometry. Ownership: the returned value is owned by the caller.
    /// Isolation: none. Errors: invalid sizes are clamped. Cancellation: not applicable.
    public init(identity: UInt64, mainSize: Double, crossSize: Double, baseline: Double? = nil) {
        self.identity = identity
        self.mainSize = max(0, mainSize)
        self.crossSize = max(0, crossSize)
        self.baseline = baseline
    }
}

/// One resolved flex line.
/// Ownership: immutable value owned by the measurement result. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FlexLine: Sendable, Hashable {
    /// Items in source order for this line.
    public let items: [FlexLineItem]
    /// Maximum resolved cross size of the line.
    public let crossSize: Double

    /// Creates immutable line geometry. Ownership: the returned value is owned by the caller.
    /// Isolation: none. Errors: invalid size is clamped. Cancellation: not applicable.
    public init(items: [FlexLineItem], crossSize: Double) {
        self.items = items
        self.crossSize = max(0, crossSize)
    }
}

/// Complete immutable result of a flex measurement pass.
/// Ownership: immutable value owned by the caller. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct FlexMeasureResult: Sendable, Hashable {
    /// Resolved size of the measured container.
    public let parentSize: MeasuredSize
    /// Per-line child geometry consumed by the layout pass.
    public let lines: [FlexLine]
    /// Revision and constraint identity for this result.
    public let cacheKey: LayoutMeasureCacheKey

    /// Creates a complete measurement result. Ownership: the returned value is owned by the caller.
    /// Isolation: none. Errors: none. Cancellation: not applicable.
    public init(parentSize: MeasuredSize, lines: [FlexLine], cacheKey: LayoutMeasureCacheKey) {
        self.parentSize = parentSize
        self.lines = lines
        self.cacheKey = cacheKey
    }

    /// Compatibility spelling for callers that only need the aggregate size.
    public var size: MeasuredSize { parentSize }
}

/// Pure bottom-up flex measurement over immutable snapshots.
///
/// Ownership: inputs and results are value types. Isolation: none; no live Node or platform object
/// is accessed. Errors: invalid values use the normalization policy of `LayoutStyle`. Cancellation:
/// cancellation is handled by the owning task between calls.
public enum FlexSolver {
    /// Measures a snapshot recursively from children to parent.
    ///
    /// Ownership: the returned result is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public static func measureContainer(
        input: LayoutInputSnapshot,
        constraint: SizeConstraint = SizeConstraint()
    ) -> FlexMeasureResult {
        var cache = FlexMeasureCache()
        return measureContainer(input: input, constraint: constraint, cache: &cache)
    }

    /// Measures using a caller-owned request-local cache.
    /// Ownership: result is owned by the caller; cache remains owned by the caller. Isolation:
    /// none. Errors: none. Cancellation: caller discards the cache when work is cancelled.
    public static func measureContainer(
        input: LayoutInputSnapshot,
        constraint: SizeConstraint = SizeConstraint(),
        cache: inout FlexMeasureCache
    ) -> FlexMeasureResult {
        measure(input, constraint: constraint, cache: &cache)
    }

    private struct BasisItem {
        let index: Int
        let size: MeasuredSize
        let margin: PhysicalEdgeInsets
        let basis: Double
        let cross: Double
        let baseline: Double?
    }

    private static func measure(
        _ input: LayoutInputSnapshot, constraint: SizeConstraint, cache: inout FlexMeasureCache
    ) -> FlexMeasureResult {
        let key = LayoutMeasureCacheKey(
            treeIdentity: input.identity,
            contentRevision: input.contentRevision,
            environmentRevision: input.environmentRevision,
            constraint: constraint,
            direction: input.direction
        )
        if let cached = cache.lookup(key: key) { return cached }
        let direction = input.style.flexDirection
        let padding = input.style.padding.resolved(for: input.direction)
        let horizontalPadding = padding.left + padding.right
        let verticalPadding = padding.top + padding.bottom
        let parentWidth = resolvedLimit(constraint.width)
        let parentHeight = resolvedLimit(constraint.height)
        let availableMain =
            direction.isHorizontal
            ? parentWidth.map { max(0, $0 - horizontalPadding) }
            : parentHeight.map { max(0, $0 - verticalPadding) }
        let availableCross =
            direction.isHorizontal
            ? parentHeight.map { max(0, $0 - verticalPadding) }
            : parentWidth.map { max(0, $0 - horizontalPadding) }
        let childConstraint = SizeConstraint(
            width: direction.isHorizontal
                ? (availableMain.map { .atMost($0) } ?? .unspecified)
                : (availableCross.map { .atMost($0) } ?? .unspecified),
            height: direction.isHorizontal
                ? (availableCross.map { .atMost($0) } ?? .unspecified)
                : (availableMain.map { .atMost($0) } ?? .unspecified)
        )
        let childMeasurements = input.children.enumerated().map { index, child in
            (index, measure(child, constraint: childConstraint, cache: &cache))
        }
        let intrinsic = input.content.intrinsic
        let bases = childMeasurements.compactMap { index, nested -> BasisItem? in
            let child = input.children[index]
            guard child.style.positionType == .relative else { return nil }
            let margin = child.style.margin.resolved(for: input.direction)
            let styleMain =
                direction.isHorizontal
                ? child.style.width.resolved(parent: availableMain)
                : child.style.height.resolved(parent: availableMain)
            let main =
                child.style.flexBasis.resolved(parent: availableMain)
                ?? styleMain
                ?? (direction.isHorizontal ? nested.parentSize.width : nested.parentSize.height)
            let cross = direction.isHorizontal ? nested.parentSize.height : nested.parentSize.width
            return BasisItem(
                index: index, size: nested.parentSize, margin: margin, basis: main, cross: cross,
                baseline: child.content.firstBaseline)
        }
        let lines = resolveLines(
            input: input, items: bases, availableMain: availableMain,
            availableCross: availableCross,
            cache: &cache
        )
        let lineMain =
            lines.map { line in
                line.items.reduce(0) { $0 + $1.mainSize } + input.style.gap
                    * Double(max(0, line.items.count - 1))
            }.max() ?? 0
        let lineCross =
            lines.reduce(0) { $0 + $1.crossSize } + input.style.crossGap
            * Double(max(0, lines.count - 1))
        let measuredWidth =
            input.style.width.resolved(parent: parentWidth)
            ?? (direction.isHorizontal ? lineMain : lineCross) + horizontalPadding
        let measuredHeight =
            input.style.height.resolved(parent: parentHeight)
            ?? (direction.isHorizontal ? lineCross : lineMain) + verticalPadding
        let withIntrinsic = MeasuredSize(
            width: input.children.isEmpty
                ? max(measuredWidth, intrinsic.width + horizontalPadding) : measuredWidth,
            height: input.children.isEmpty
                ? max(measuredHeight, intrinsic.height + verticalPadding) : measuredHeight
        )
        var size =
            input.style.measured(
                parentSize: MeasuredSize(
                    width: parentWidth ?? withIntrinsic.width,
                    height: parentHeight ?? withIntrinsic.height),
                constraint: constraint
            ).width == 0 && input.style.width == .auto && input.style.height == .auto
            ? withIntrinsic
            : input.style.measured(parentSize: withIntrinsic, constraint: constraint)
        if parentWidth == nil, case .fraction = input.style.width {
            size = MeasuredSize(width: withIntrinsic.width, height: size.height)
        }
        if parentHeight == nil, case .fraction = input.style.height {
            size = MeasuredSize(width: size.width, height: withIntrinsic.height)
        }
        if input.style.width == .auto {
            let width = intrinsicSize(
                fallback: max(withIntrinsic.width, size.width),
                constraint: constraint.width,
                explicit: exactValue(constraint.width))
            size = MeasuredSize(width: width, height: size.height)
        }
        if input.style.height == .auto {
            let height = intrinsicSize(
                fallback: max(withIntrinsic.height, size.height),
                constraint: constraint.height,
                explicit: exactValue(constraint.height))
            size = MeasuredSize(width: size.width, height: height)
        }
        let result = FlexMeasureResult(
            parentSize: size, lines: lines, cacheKey: key)
        cache.store(key: key, result: result)
        return result
    }

    private static func resolvedLimit(_ axis: SizeConstraintAxis) -> Double? {
        switch axis {
        case .unspecified: return nil
        case let .atMost(value), let .exact(value): return value
        }
    }

    private static func intrinsicSize(
        fallback: Double, constraint: SizeConstraintAxis, explicit: Double?
    ) -> Double {
        if let explicit { return explicit }
        switch constraint {
        case .unspecified, .atMost: return fallback
        case let .exact(value): return value
        }
    }

    private static func exactValue(_ axis: SizeConstraintAxis) -> Double? {
        guard case let .exact(value) = axis else { return nil }
        return value
    }

    private static func resolveLines(
        input: LayoutInputSnapshot, items: [BasisItem], availableMain: Double?,
        availableCross: Double?, cache: inout FlexMeasureCache
    ) -> [FlexLine] {
        guard !items.isEmpty else { return [] }
        var groups: [[BasisItem]] = [[]]
        for item in items {
            let current = groups[groups.count - 1]
            let currentMain =
                current.reduce(0) {
                    $0 + $1.basis
                        + mainMargin($1.margin, horizontal: input.style.flexDirection.isHorizontal)
                } + input.style.gap * Double(max(0, current.count - 1))
            if input.style.flexWrap != .noWrap, let availableMain, !current.isEmpty,
                currentMain + input.style.gap + item.basis
                    + mainMargin(item.margin, horizontal: input.style.flexDirection.isHorizontal)
                    > availableMain
            {
                groups.append([item])
            } else {
                groups[groups.count - 1].append(item)
            }
        }
        return groups.map { group in
            let horizontal = input.style.flexDirection.isHorizontal
            let baseTotal =
                group.reduce(0) { $0 + $1.basis + mainMargin($1.margin, horizontal: horizontal) }
                + input.style.gap * Double(max(0, group.count - 1))
            let delta = (availableMain ?? baseTotal) - baseTotal
            let weights =
                delta >= 0
                ? group.map { input.children[$0.index].style.flexGrow }
                : group.map { input.children[$0.index].style.flexShrink * $0.basis }
            let totalWeight = weights.reduce(0, +)
            var resolvedMains = group.map(\.basis)
            if delta >= 0, totalWeight > 0 {
                for (offset, weight) in weights.enumerated() {
                    resolvedMains[offset] += delta * weight / totalWeight
                }
            } else if delta < 0, availableMain != nil {
                var active = Set(group.indices)
                var remaining = -delta
                while remaining > 0.0001, !active.isEmpty {
                    let weight = active.reduce(0) { $0 + weights[$1] }
                    guard weight > 0 else { break }
                    var consumed = 0.0
                    var frozen: [Int] = []
                    for offset in active {
                        let child = input.children[group[offset].index]
                        let minValue =
                            horizontal
                            ? child.style.minWidth.resolved(parent: availableMain)
                            : child.style.minHeight.resolved(parent: availableMain)
                        let reduction = remaining * weights[offset] / weight
                        let next = max(minValue ?? 0, resolvedMains[offset] - reduction)
                        consumed += resolvedMains[offset] - next
                        resolvedMains[offset] = next
                        if next <= (minValue ?? 0) + 0.0001 { frozen.append(offset) }
                    }
                    frozen.forEach { active.remove($0) }
                    if consumed <= 0.0001 { break }
                    remaining -= consumed
                }
            }
            let resolved = group.enumerated().map { offset, item in
                let child = input.children[item.index]
                let minValue =
                    horizontal
                    ? child.style.minWidth.resolved(parent: availableMain)
                    : child.style.minHeight.resolved(parent: availableMain)
                let maxValue =
                    horizontal
                    ? child.style.maxWidth.resolved(parent: availableMain)
                    : child.style.maxHeight.resolved(parent: availableMain)
                let main = min(
                    max(resolvedMains[offset], minValue ?? 0), maxValue ?? .greatestFiniteMagnitude)
                let measured = measure(
                    child,
                    constraint: horizontal
                        ? SizeConstraint(
                            width: .exact(main),
                            height: availableCross.map { .atMost($0) } ?? .unspecified)
                        : SizeConstraint(
                            width: availableCross.map { .atMost($0) } ?? .unspecified,
                            height: .exact(main)), cache: &cache)
                let cross = horizontal ? measured.parentSize.height : measured.parentSize.width
                return FlexLineItem(
                    identity: child.identity, mainSize: main, crossSize: cross,
                    baseline: child.content.firstBaseline)
            }
            return FlexLine(items: resolved, crossSize: resolved.map(\.crossSize).max() ?? 0)
        }
    }

    private static func mainMargin(_ margin: PhysicalEdgeInsets, horizontal: Bool) -> Double {
        horizontal ? margin.left + margin.right : margin.top + margin.bottom
    }
}

private extension FlexDirection {
    var isHorizontal: Bool {
        switch self {
        case .row, .rowReverse: return true
        case .column, .columnReverse: return false
        }
    }
}
