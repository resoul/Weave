import Foundation

/// Immutable text style used by measurement and display.
/// Ownership: value is copied into layout inputs. Isolation: none. Errors: invalid values normalize. Cancellation: not applicable.
public struct TextStyle: Sendable, Hashable {
    public let fontName: String
    public let pointSize: Double
    public let lineHeight: Double
    public let bold: Bool
    public let color: ThemeColor?

    /// Creates a platform-neutral style; font resolution belongs to the adapter backend.
    /// Ownership: strings and scalars are copied. Isolation: none. Errors: invalid values clamp. Cancellation: none.
    public init(
        fontName: String = "system", pointSize: Double = 17, lineHeight: Double = 0,
        bold: Bool = false
    ) {
        self.init(
            fontName: fontName, pointSize: pointSize, lineHeight: lineHeight, bold: bold, color: nil
        )
    }

    /// Creates a platform-neutral style with an optional explicit color override.
    /// Ownership: strings and scalars are copied. Isolation: none. Errors: invalid values clamp. Cancellation: none.
    public init(
        fontName: String = "system", pointSize: Double = 17, lineHeight: Double = 0,
        bold: Bool = false, color: ThemeColor?
    ) {
        self.fontName = fontName
        self.pointSize = pointSize.isFinite ? max(0, pointSize) : 0
        self.lineHeight = lineHeight.isFinite ? max(0, lineHeight) : 0
        self.bold = bold
        self.color = color
    }
}

/// MainActor-owned factory for the backend used by the convenience `TextNode` initializer.
/// Ownership: the registry owns the factory closure. Isolation: MainActor. Errors: backend
/// construction does not throw. Cancellation: not applicable.
///
/// The platform adapter replaces this factory during bootstrap. The portable backend remains the
/// fallback so `WeaveUI` stays independent from UIKit and AppKit.
@MainActor
public enum TextLayoutBackendRegistry {
    /// Creates the default text layout backend for a newly initialized text node.
    /// Ownership: each call returns a backend owned by its `TextNode`. Isolation: MainActor.
    /// Errors: none. Cancellation: not applicable.
    public static var makeDefault: () -> any TextLayoutBackend = { DefaultTextLayoutBackend() }
}

/// Immutable truncation policy.
/// Ownership: value is copied into layout inputs. Isolation: none. Errors: invalid line counts clamp. Cancellation: not applicable.
public enum TextTruncation: Sendable, Hashable {
    case clip
    case tail(ellipsis: String)
}

/// Immutable input shared by worker text layout and display.
/// Ownership: input owns copied text and style. Isolation: none. Errors: constraints are normalized by the backend. Cancellation: caller-owned task cancellation.
public struct TextLayoutInput: Sendable, Hashable {
    public let text: String
    public let style: TextStyle
    public let constraint: SizeConstraint
    public let direction: LayoutDirection
    public let localeIdentifier: String
    public let scale: Double
    public let maxLines: Int?
    public let truncation: TextTruncation

    /// Creates a complete immutable text layout request.
    /// Ownership: all values are copied. Isolation: none. Errors: scale and maxLines normalize. Cancellation: not applicable.
    public init(
        text: String,
        style: TextStyle = TextStyle(),
        constraint: SizeConstraint = SizeConstraint(),
        direction: LayoutDirection = .leftToRight,
        localeIdentifier: String = "en_US_POSIX",
        scale: Double = 1,
        maxLines: Int? = nil,
        truncation: TextTruncation = .clip
    ) {
        self.text = text
        self.style = style
        self.constraint = constraint
        self.direction = direction
        self.localeIdentifier = localeIdentifier
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.maxLines = maxLines.map { max(1, $0) }
        self.truncation = truncation
    }
}

/// Immutable measured text metrics shared by layout and accessibility.
/// Ownership: result is copied by the node. Isolation: none. Errors: dimensions are finite and non-negative. Cancellation: stale results are dropped by owner.
public struct TextMetrics: Sendable, Hashable {
    public let size: MeasuredSize
    public let firstBaseline: Double
    public let lineCount: Int
    public let didTruncate: Bool

    /// Creates normalized metrics.
    /// Ownership: values are copied. Isolation: none. Errors: invalid baseline/count normalize. Cancellation: not applicable.
    public init(
        size: MeasuredSize, firstBaseline: Double, lineCount: Int, didTruncate: Bool = false
    ) {
        self.size = size
        self.firstBaseline = firstBaseline.isFinite ? max(0, firstBaseline) : 0
        self.lineCount = max(0, lineCount)
        self.didTruncate = didTruncate
    }
}

/// Immutable display payload produced by a text backend.
/// Ownership: result owns copied display text and metrics. Isolation: none. Errors: backend failures are thrown. Cancellation: stale results are dropped by owner.
public struct TextDisplayResult: Sendable, Hashable {
    public let renderedText: String
    public let metrics: TextMetrics
    public let generation: UInt64

    /// Creates a display result.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: generation is checked by the owner.
    public init(renderedText: String, metrics: TextMetrics, generation: UInt64) {
        self.renderedText = renderedText
        self.metrics = metrics
        self.generation = generation
    }
}

/// Platform boundary for CoreText-backed layout and raster preparation.
/// Ownership: node owns the backend. Isolation: MainActor entry with Sendable input. Errors: backend failures throw. Cancellation: task cancellation must be observed.
@MainActor
public protocol TextLayoutBackend: AnyObject {
    /// Measures immutable text input synchronously on MainActor before snapshot submission.
    /// Ownership: result is a value owned by the caller. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func measure(_ input: TextLayoutInput) -> TextMetrics

    func display(_ input: TextLayoutInput, generation: UInt64) async throws -> TextDisplayResult
}

public extension TextLayoutBackend {
    /// Provides a deterministic fallback for custom backends that only customize display.
    /// Ownership: result is a value owned by the caller. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    func measure(_ input: TextLayoutInput) -> TextMetrics {
        DefaultTextLayoutBackend.measureFallback(input)
    }
}

/// A node that can report intrinsic metrics for a parent-provided constraint.
/// Ownership: the node owns its measurement backend. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable; measurement completes before worker submission.
@MainActor
public protocol MeasurableNode: AnyObject {
    func measure(constraint: SizeConstraint) -> MeasuredSize
    var firstBaseline: Double? { get }
}

/// Portable text measurement fallback used when a consumer does not opt into a native text backend.
/// Ownership: the backend owns no native resources. Isolation: MainActor entry with immutable
/// input. Errors: none. Cancellation: the call checks cancellation before returning.
@MainActor
public final class DefaultTextLayoutBackend: TextLayoutBackend {
    /// Creates a stateless fallback backend.
    /// Ownership: the backend owns no state. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Measures immutable text input. Ownership: the result is owned by the caller. Isolation:
    /// MainActor. Errors: none. Cancellation: not applicable.
    public func measure(_ input: TextLayoutInput) -> TextMetrics {
        Self.measureFallback(input)
    }

    /// Measures text using the portable fallback and returns its display payload.
    /// Ownership: input and result are immutable values. Isolation: MainActor. Errors: none.
    /// Cancellation: cancellation is checked before the result is produced.
    public func display(_ input: TextLayoutInput, generation: UInt64) async throws
        -> TextDisplayResult
    {
        try Task.checkCancellation()
        let metrics = Self.measureFallback(input)
        return TextDisplayResult(
            renderedText: input.text,
            metrics: metrics,
            generation: generation
        )
    }

    fileprivate static func measureFallback(_ input: TextLayoutInput) -> TextMetrics {
        let lineHeight =
            input.style.lineHeight > 0 ? input.style.lineHeight : input.style.pointSize * 1.2
        let lines = max(
            1, input.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        let longestLine =
            input.text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count).max() ?? 0
        let naturalWidth = Double(longestLine) * input.style.pointSize * 0.55
        let constrainedWidth: Double
        switch input.constraint.width {
        case let .exact(width), let .atMost(width): constrainedWidth = min(naturalWidth, width)
        case .unspecified: constrainedWidth = naturalWidth
        }
        return TextMetrics(
            size: MeasuredSize(width: constrainedWidth, height: Double(lines) * lineHeight),
            firstBaseline: lineHeight * 0.8,
            lineCount: lines
        )
    }
}

/// MainActor text node that schedules one coherent measure/display result per text generation.
/// Ownership: node owns backend and latest result. Isolation: MainActor. Errors: failures are retained as typed text errors. Cancellation: replacing text cancels stale display work.
@MainActor
public final class TextNode: Node, MeasurableNode {
    public private(set) var text: String
    public var textStyle: TextStyle {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
            scheduleDisplay()
        }
    }
    public var maxLines: Int? {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
            scheduleDisplay()
        }
    }
    public var truncation: TextTruncation {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
            scheduleDisplay()
        }
    }
    public private(set) var metrics: TextMetrics?
    public private(set) var displayResult: TextDisplayResult?
    public private(set) var displayError: String?
    public private(set) var textRevision: UInt64 = 0

    private let backend: any TextLayoutBackend
    private var displayTask: Task<Void, Never>?
    private var direction: LayoutDirection = .leftToRight
    private var localeIdentifier = "en_US_POSIX"
    private var scale = 1.0
    private var constraint = SizeConstraint()

    /// Creates a text node using the backend currently registered by the host platform.
    /// Ownership: the node owns its backend and text state. Isolation: MainActor. Errors: none.
    /// Cancellation: disposal cancels pending display work.
    public convenience init(text: String, style: TextStyle = TextStyle()) {
        self.init(text: text, style: style, backend: TextLayoutBackendRegistry.makeDefault())
    }

    /// Creates a text node without allocating a platform text object.
    /// Ownership: node retains backend and immutable style policy. Isolation: MainActor. Errors: no work starts until text/layout is requested. Cancellation: disposal cancels display work.
    public init(text: String, style: TextStyle = TextStyle(), backend: any TextLayoutBackend) {
        self.text = text
        self.textStyle = style
        self.backend = backend
        self.maxLines = nil
        self.truncation = .clip
        super.init()
        accessibility = AccessibilityProperties(
            isElement: true, value: text, role: .text, state: AccessibilityState(value: text))
    }

    /// Supplies an intrinsic size for the synchronous layout snapshot.
    /// Ownership: the returned metrics are immutable. Isolation: MainActor. Errors: none.
    /// Cancellation: not applicable.
    public override var layoutContentMetrics: LayoutContentMetrics {
        layoutContentMetrics(for: SizeConstraint())
    }

    public override func layoutContentMetrics(for constraint: SizeConstraint)
        -> LayoutContentMetrics
    {
        let metrics = measuredTextMetrics(for: constraint)
        return LayoutContentMetrics(intrinsic: metrics.size, firstBaseline: metrics.firstBaseline)
    }

    /// Measures the node for a parent constraint. Ownership: the result is owned by the caller.
    /// Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func measure(constraint: SizeConstraint) -> MeasuredSize {
        measuredTextMetrics(for: constraint).size
    }

    public var firstBaseline: Double? {
        measuredTextMetrics(for: self.constraint).firstBaseline
    }

    private func measuredTextMetrics(for constraint: SizeConstraint) -> TextMetrics {
        backend.measure(
            TextLayoutInput(
                text: text, style: textStyle, constraint: constraint, direction: direction,
                localeIdentifier: localeIdentifier, scale: scale, maxLines: maxLines,
                truncation: truncation))
    }

    /// Replaces text and cancels the previous display generation.
    /// Ownership: text is copied. Isolation: MainActor. Errors: stale display results are ignored. Cancellation: previous task is cancelled.
    public func setText(_ text: String) {
        self.text = text
        textRevision &+= 1
        setNeedsLayout()
        setNeedsDisplay()
        scheduleDisplay()
    }

    /// Updates environment inputs used by the next text layout pass.
    /// Ownership: values are copied. Isolation: MainActor. Errors: invalid scale normalizes. Cancellation: previous display is cancelled.
    public func setLayoutInputs(
        constraint: SizeConstraint, direction: LayoutDirection, localeIdentifier: String,
        scale: Double
    ) {
        self.constraint = constraint; self.direction = direction;
        self.localeIdentifier = localeIdentifier
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        scheduleDisplay()
    }

    /// Starts one cancellable display request for the latest immutable input.
    /// Ownership: node owns the task and result. Isolation: MainActor. Errors: displayError stores a diagnostic. Cancellation: replacement/disposal cancels the task.
    public func scheduleDisplay() {
        displayTask?.cancel()
        let generation = textRevision
        let input = TextLayoutInput(
            text: text, style: textStyle, constraint: constraint, direction: direction,
            localeIdentifier: localeIdentifier, scale: scale, maxLines: maxLines,
            truncation: truncation)
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await backend.display(input, generation: generation)
                guard !Task.isCancelled, self.textRevision == generation else { return }
                self.metrics = result.metrics
                self.displayResult = result
                self.displayError = nil
                self.accessibility = AccessibilityProperties(
                    isElement: true, value: text, role: .text,
                    state: AccessibilityState(value: text))
            } catch is CancellationError {
            } catch {
                guard self.textRevision == generation else { return }
                self.displayError = String(describing: error)
            }
        }
    }

    public override func dispose() { displayTask?.cancel(); displayTask = nil; super.dispose() }
}
