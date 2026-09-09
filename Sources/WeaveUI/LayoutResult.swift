/// Pixel scale used to convert logical points into stable device pixels.
///
/// Ownership: the policy is an immutable value owned by the layout caller. Isolation: none.
/// Errors: non-positive or non-finite scales normalize to one. Cancellation: not applicable.
public struct PixelRoundingPolicy: Sendable, Hashable {
    public let scale: Double

    /// Creates a pixel rounding policy.
    ///
    /// Ownership: the returned policy is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(scale: Double = 1) {
        self.scale = scale.isFinite && scale > 0 ? scale : 1
    }
}

/// One positioned snapshot element emitted by the top-down layout pass.
///
/// Ownership: the placement owns its immutable frame. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutPlacement: Sendable, Hashable {
    public let identity: UInt64
    public let frame: LayoutFrame

    /// Creates a placement for a runtime identity.
    ///
    /// Ownership: the returned placement is owned by the result. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(identity: UInt64, frame: LayoutFrame) {
        self.identity = identity
        self.frame = frame
    }
}

/// Immutable output of a top-down layout pass.
///
/// Ownership: the result owns its placements and revisions. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct LayoutResult: Sendable, Hashable {
    public let placements: [LayoutPlacement]
    public let treeIdentity: UInt64
    public let environmentRevision: UInt64
    public let contentRevision: UInt64

    /// Creates a layout result.
    ///
    /// Ownership: the returned result is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        placements: [LayoutPlacement],
        treeIdentity: UInt64,
        environmentRevision: UInt64,
        contentRevision: UInt64
    ) {
        self.placements = placements
        self.treeIdentity = treeIdentity
        self.environmentRevision = environmentRevision
        self.contentRevision = contentRevision
    }

    /// Returns the placement for an identity, if it was emitted.
    ///
    /// Ownership: the returned placement is borrowed from this immutable result. Isolation: none.
    /// Errors: none. Cancellation: not applicable.
    public func placement(for identity: UInt64) -> LayoutPlacement? {
        placements.first { $0.identity == identity }
    }
}

extension FlexSolver {
    /// Performs a pure top-down frame pass using a measured container frame.
    ///
    /// Ownership: the returned result owns copied placements. Isolation: none; no live Node or
    /// platform object is accessed. Errors: invalid values use normalized geometry. Cancellation:
    /// cancellation is handled by the owning task between calls.
    public static func layoutContainer(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy()
    ) -> LayoutResult {
        var cache = FlexMeasureCache()
        return layoutContainer(
            input: input, frame: frame, roundingPolicy: roundingPolicy, cache: &cache)
    }

    /// Performs layout using a request-local measurement cache.
    /// Ownership: cache remains owned by the caller. Isolation: none. Errors: none. Cancellation:
    /// caller discards the cache with the request.
    public static func layoutContainer(
        input: LayoutInputSnapshot,
        frame: LayoutFrame,
        roundingPolicy: PixelRoundingPolicy = PixelRoundingPolicy(),
        cache: inout FlexMeasureCache
    ) -> LayoutResult {
        var placements: [LayoutPlacement] = [
            LayoutPlacement(identity: input.identity, frame: rounded(frame, policy: roundingPolicy))
        ]
        let padding = input.style.padding.resolved(for: input.direction)
        let inner = LayoutFrame(
            origin: LayoutPoint(x: frame.origin.x + padding.left, y: frame.origin.y + padding.top),
            width: max(0, frame.width - padding.left - padding.right),
            height: max(0, frame.height - padding.top - padding.bottom)
        )
        let measured = measureContainer(
            input: input,
            constraint: SizeConstraint(width: .exact(frame.width), height: .exact(frame.height)),
            cache: &cache
        )
        let isHorizontal: Bool
        switch input.style.flexDirection {
        case .row, .rowReverse: isHorizontal = true
        case .column, .columnReverse: isHorizontal = false
        }
        let reversed =
            input.style.flexDirection.isReversed
            != (isHorizontal && input.direction == .rightToLeft)
        let gap = input.style.gap
        let availableMain = isHorizontal ? inner.width : inner.height
        let availableCross = isHorizontal ? inner.height : inner.width
        let hasExplicitCrossSize =
            isHorizontal
            ? input.style.height != .auto
            : input.style.width != .auto
        let naturalCross =
            measured.lines.reduce(0) { $0 + $1.crossSize }
            + input.style.crossGap * Double(max(0, measured.lines.count - 1))
        let crossFree = max(0, availableCross - naturalCross)
        let stretchLines =
            input.style.alignContent == .stretch && hasExplicitCrossSize
            && !measured.lines.isEmpty
        let lineCrossSizes = measured.lines.map { line in
            line.crossSize + (stretchLines ? crossFree / Double(measured.lines.count) : 0)
        }
        let distributedCrossFree = stretchLines ? 0 : crossFree
        let (crossOffset, crossSpacing) = crossDistribution(
            mode: input.style.alignContent,
            free: distributedCrossFree,
            count: measured.lines.count,
            baseSpacing: input.style.crossGap
        )
        let orderedLines: [(line: FlexLine, crossSize: Double)] =
            input.style.flexWrap == .wrapReverse
            ? zip(measured.lines, lineCrossSizes).reversed().map { (line: $0.0, crossSize: $0.1) }
            : zip(measured.lines, lineCrossSizes).map { (line: $0.0, crossSize: $0.1) }
        var crossCursor = crossOffset
        for entry in orderedLines {
            let line = entry.line
            let lineCrossSize = entry.crossSize
            let totalMain =
                line.items.reduce(0) { $0 + $1.mainSize }
                + gap * Double(max(0, line.items.count - 1))
            let (justifyOffset, justifyGap) = mainDistribution(
                mode: input.style.justifyContent,
                free: max(0, availableMain - totalMain),
                count: line.items.count,
                baseSpacing: gap
            )
            var cursor = justifyOffset
            for item in line.items {
                guard let child = input.children.first(where: { $0.identity == item.identity })
                else {
                    continue
                }
                let size =
                    isHorizontal
                    ? MeasuredSize(width: item.mainSize, height: item.crossSize)
                    : MeasuredSize(width: item.crossSize, height: item.mainSize)
                let margin = child.style.margin.resolved(for: input.direction)
                let main = isHorizontal ? size.width : size.height
                let cross: Double = isHorizontal ? size.height : size.width
                let crossAvailable: Double = lineCrossSize
                let lineBaseline = line.items.compactMap(\.baseline).max()
                let alignment: AlignItems
                switch child.style.alignSelf {
                case .auto: alignment = input.style.alignItems
                case .stretch: alignment = .stretch
                case .start: alignment = .start
                case .end: alignment = .end
                case .center: alignment = .center
                case .baseline: alignment = .baseline
                }
                let stretchedCross =
                    alignment == .stretch
                        && (isHorizontal ? child.style.height == .auto : child.style.width == .auto)
                    ? crossAvailable
                    : cross
                let resolvedSize =
                    isHorizontal
                    ? MeasuredSize(width: main, height: stretchedCross)
                    : MeasuredSize(width: stretchedCross, height: main)
                let crossOffset: Double
                switch alignment {
                case .start, .stretch: crossOffset = 0
                case .baseline:
                    crossOffset =
                        item.baseline.flatMap { baseline in
                            lineBaseline.map { max(0, $0 - baseline) }
                        } ?? 0
                case .end: crossOffset = max(0, crossAvailable - cross)
                case .center: crossOffset = max(0, (crossAvailable - cross) / 2)
                }
                let mainPosition = reversed ? availableMain - cursor - main : cursor
                var x =
                    isHorizontal
                    ? inner.origin.x + mainPosition + margin.left
                    : inner.origin.x + crossCursor + crossOffset + margin.left
                var y =
                    isHorizontal
                    ? inner.origin.y + crossCursor + crossOffset + margin.top
                    : inner.origin.y + mainPosition + margin.top
                if child.style.positionType == .absolute {
                    let offsets = child.style.offsets.resolved(for: input.direction)
                    x =
                        offsets.left.map { inner.origin.x + $0 } ?? offsets.right.map {
                            inner.origin.x + inner.width - $0 - size.width
                        } ?? inner.origin.x
                    y =
                        offsets.top.map { inner.origin.y + $0 } ?? offsets.bottom.map {
                            inner.origin.y + inner.height - $0 - size.height
                        } ?? inner.origin.y
                }
                let childFrame = LayoutFrame(
                    origin: LayoutPoint(x: x, y: y), width: resolvedSize.width,
                    height: resolvedSize.height)
                placements.append(
                    contentsOf: layoutContainer(
                        input: child, frame: childFrame, roundingPolicy: roundingPolicy,
                        cache: &cache
                    ).placements)
                cursor += main + justifyGap
            }
            crossCursor += lineCrossSize + crossSpacing
        }
        for child in input.children where child.style.positionType == .absolute {
            let childMeasure = measureContainer(
                input: child,
                constraint: SizeConstraint(
                    width: .atMost(inner.width), height: .atMost(inner.height)),
                cache: &cache
            ).parentSize
            let offsets = child.style.offsets.resolved(for: input.direction)
            let x =
                offsets.left.map { inner.origin.x + $0 } ?? offsets.right.map {
                    inner.origin.x + inner.width - $0 - childMeasure.width
                } ?? inner.origin.x
            let y =
                offsets.top.map { inner.origin.y + $0 } ?? offsets.bottom.map {
                    inner.origin.y + inner.height - $0 - childMeasure.height
                } ?? inner.origin.y
            placements.append(
                contentsOf: layoutContainer(
                    input: child,
                    frame: LayoutFrame(
                        origin: LayoutPoint(x: x, y: y), width: childMeasure.width,
                        height: childMeasure.height), roundingPolicy: roundingPolicy, cache: &cache
                ).placements)
        }
        return LayoutResult(
            placements: placements,
            treeIdentity: input.identity,
            environmentRevision: input.environmentRevision,
            contentRevision: input.contentRevision
        )
    }

    private static func mainDistribution(
        mode: JustifyContent, free: Double, count: Int, baseSpacing: Double
    ) -> (offset: Double, spacing: Double) {
        guard count > 0 else { return (0, baseSpacing) }
        switch mode {
        case .start: return (0, baseSpacing)
        case .end: return (free, baseSpacing)
        case .center: return (free / 2, baseSpacing)
        case .spaceBetween:
            return (0, count > 1 ? baseSpacing + free / Double(count - 1) : 0)
        case .spaceAround:
            let spacing = baseSpacing + free / Double(count)
            return (spacing / 2, spacing)
        case .spaceEvenly:
            let spacing = baseSpacing + free / Double(count + 1)
            return (spacing, spacing)
        }
    }

    private static func crossDistribution(
        mode: AlignContent, free: Double, count: Int, baseSpacing: Double
    ) -> (offset: Double, spacing: Double) {
        guard count > 0 else { return (0, baseSpacing) }
        switch mode {
        case .start, .stretch: return (0, baseSpacing)
        case .end: return (free, baseSpacing)
        case .center: return (free / 2, baseSpacing)
        case .spaceBetween:
            return (0, count > 1 ? baseSpacing + free / Double(count - 1) : 0)
        case .spaceAround:
            let spacing = baseSpacing + free / Double(count)
            return (spacing / 2, spacing)
        case .spaceEvenly:
            let spacing = baseSpacing + free / Double(count + 1)
            return (spacing, spacing)
        }
    }

    private static func rounded(_ frame: LayoutFrame, policy: PixelRoundingPolicy) -> LayoutFrame {
        let scale = policy.scale
        func snap(_ value: Double) -> Double { (value * scale).rounded() / scale }
        return LayoutFrame(
            origin: LayoutPoint(x: snap(frame.origin.x), y: snap(frame.origin.y)),
            width: snap(frame.width), height: snap(frame.height))
    }
}

private extension FlexDirection {
    var isReversed: Bool {
        switch self {
        case .rowReverse, .columnReverse: return true
        case .row, .column: return false
        }
    }
}
