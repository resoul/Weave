import CoreGraphics
import CoreText
import Foundation
import WeaveUI

/// Immutable parameters describing a CoreText rasterization job.
/// Ownership: request is copied across concurrency boundaries. Isolation: Sendable. Errors: none. Cancellation: not applicable.
public struct TextRenderRequest: Sendable, Hashable {
    public let nodeID: ElementID
    public let text: String
    public let style: TextStyle
    public let color: ThemeColor
    public let bounds: LayoutFrame
    public let scale: Double
    public let direction: LayoutDirection
    public let localeIdentifier: String
    public let maxLines: Int?
    public let truncation: TextTruncation
    public let generation: UInt64
    public let geometryGeneration: UInt64
    public let contentRevision: UInt64

    /// Creates an immutable text render request.
    /// Ownership: values are copied. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        text: String,
        style: TextStyle,
        color: ThemeColor = ThemeColor(red: 0, green: 0, blue: 0),
        bounds: LayoutFrame,
        scale: Double,
        direction: LayoutDirection,
        localeIdentifier: String,
        maxLines: Int?,
        truncation: TextTruncation,
        generation: UInt64,
        geometryGeneration: UInt64,
        contentRevision: UInt64
    ) {
        self.nodeID = nodeID
        self.text = text
        self.style = style
        self.color = color
        self.bounds = bounds
        self.scale = scale
        self.direction = direction
        self.localeIdentifier = localeIdentifier
        self.maxLines = maxLines
        self.truncation = truncation
        self.generation = generation
        self.geometryGeneration = geometryGeneration
        self.contentRevision = contentRevision
    }
}

/// Thread-safe CoreText shaping, measurement, and raster rendering engine.
/// Ownership: engine owns no platform views or persistent caches. Isolation: Sendable; safe to invoke from background workers.
/// Errors: invalid inputs fall back to safe typography without throwing; raster failures produce empty artifacts.
/// Cancellation: cooperatively checks Task cancellation before expensive shaping and drawing stages.
public enum CoreTextRasterRenderer: Sendable {
    /// Measures text metrics using CoreText.
    /// Ownership: values are copied. Isolation: Sendable. Errors: none. Cancellation: not applicable.
    public static func measure(
        text: String,
        style: TextStyle,
        constraint: SizeConstraint,
        direction: LayoutDirection = .leftToRight,
        localeIdentifier: String = "en_US_POSIX",
        maxLines: Int? = nil,
        truncation: TextTruncation = .clip
    ) -> TextMetrics {
        _ = localeIdentifier
        guard !text.isEmpty else {
            let lineHeight = style.lineHeight > 0 ? style.lineHeight : style.pointSize * 1.2
            return TextMetrics(
                size: MeasuredSize(width: 0, height: lineHeight),
                firstBaseline: lineHeight * 0.8,
                lineCount: 1,
                didTruncate: false
            )
        }

        let isSingleLine = maxLines == 1
        let attributed = makeAttributedString(
            text: text,
            style: style,
            color: style.color ?? ThemeColor(red: 0, green: 0, blue: 0),
            direction: direction,
            truncation: truncation,
            wrapWords: !isSingleLine
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        let maxWidth: CGFloat
        switch constraint.width {
        case let .exact(value), let .atMost(value):
            maxWidth = CGFloat(value)
        case .unspecified:
            maxWidth = .greatestFiniteMagnitude
        }

        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            nil
        )

        let lineHeight = style.lineHeight > 0 ? style.lineHeight : Double(style.pointSize * 1.2)
        let rawLines = max(1, Int(ceil(Double(suggested.height) / max(lineHeight, 1))))
        let lineCount = min(rawLines, maxLines ?? rawLines)
        let didTruncate = maxLines.map { rawLines > $0 } ?? false
        let height = lineHeight * Double(lineCount)
        let width = min(Double(suggested.width), Double(maxWidth))

        return TextMetrics(
            size: MeasuredSize(width: width, height: height),
            firstBaseline: lineHeight * 0.8,
            lineCount: lineCount,
            didTruncate: didTruncate
        )
    }

    /// Renders text into an immutable bitmap artifact using CoreText.
    /// Ownership: returned artifact owns the rendered CGImage. Isolation: Sendable; executes on background workers.
    /// Errors: throws CancellationError if cancelled. Cancellation: checked cooperatively before and after raster operations.
    public static func render(request: TextRenderRequest) throws -> DisplayArtifact {
        try Task.checkCancellation()

        guard !request.text.isEmpty,
            request.bounds.width > 0,
            request.bounds.height > 0,
            request.scale > 0
        else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        let isSingleLine = request.maxLines == 1
        let attributed = makeAttributedString(
            text: request.text,
            style: request.style,
            color: request.color,
            direction: request.direction,
            truncation: request.truncation,
            wrapWords: !isSingleLine
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        try Task.checkCancellation()

        let pixelWidth = max(1, Int(ceil(request.bounds.width * request.scale)))
        let pixelHeight = max(1, Int(ceil(request.bounds.height * request.scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        context.scaleBy(x: CGFloat(request.scale), y: CGFloat(request.scale))
        context.textMatrix = .identity

        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: request.bounds.width, height: request.bounds.height))

        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)

        try Task.checkCancellation()
        CTFrameDraw(frame, context)
        try Task.checkCancellation()

        guard let image = context.makeImage() else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        return DisplayArtifact(
            nodeID: request.nodeID,
            generation: request.generation,
            geometryGeneration: request.geometryGeneration,
            contentRevision: request.contentRevision,
            payload: .image(image),
            size: CGSize(width: request.bounds.width, height: request.bounds.height),
            scale: request.scale
        )
    }

    private static func makeAttributedString(
        text: String,
        style: TextStyle,
        color: ThemeColor,
        direction: LayoutDirection,
        truncation: TextTruncation,
        wrapWords: Bool = true
    ) -> CFAttributedString {
        let fontName: String =
            (style.fontName == "system" || style.fontName.isEmpty) ? "Helvetica" : style.fontName
        let font = CTFontCreateWithName(fontName as CFString, CGFloat(style.pointSize), nil)
        let textColor = CGColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )

        var alignment: CTTextAlignment = direction == .rightToLeft ? .right : .left
        var lineBreak: CTLineBreakMode =
            wrapWords ? .byWordWrapping : (truncation == .clip ? .byClipping : .byTruncatingTail)
        var baseWritingDirection: CTWritingDirection =
            direction == .rightToLeft ? .rightToLeft : .leftToRight

        let paragraphStyle: CTParagraphStyle = withUnsafePointer(to: &alignment) { alignPtr in
            withUnsafePointer(to: &lineBreak) { lineBreakPtr in
                withUnsafePointer(to: &baseWritingDirection) { dirPtr in
                    let settings = [
                        CTParagraphStyleSetting(
                            spec: .alignment,
                            valueSize: MemoryLayout<CTTextAlignment>.size,
                            value: alignPtr
                        ),
                        CTParagraphStyleSetting(
                            spec: .lineBreakMode,
                            valueSize: MemoryLayout<CTLineBreakMode>.size,
                            value: lineBreakPtr
                        ),
                        CTParagraphStyleSetting(
                            spec: .baseWritingDirection,
                            valueSize: MemoryLayout<CTWritingDirection>.size,
                            value: dirPtr
                        ),
                    ]
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: textColor,
            kCTParagraphStyleAttributeName: paragraphStyle,
        ]

        return CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, attributes as CFDictionary)
    }
}
