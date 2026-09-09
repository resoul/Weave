#if canImport(UIKit)
    import UIKit
    import WeaveUI

    /// Non-interactive UIKit debug overlay. It draws diagnostics and passes all input through.
    /// Ownership: the view owns drawing state. Isolation: MainActor. Errors: invalid frames are skipped. Cancellation: no work starts.
    @MainActor
    public final class UIKitDebugOverlayView: UIView {
        private var entries: [DebugOverlayEntry] = []

        /// Creates a transparent, input-pass-through overlay.
        /// Ownership: the view owns its drawing state. Isolation: MainActor. Errors: none. Cancellation: no work starts.
        public override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
        }

        /// Creates an overlay from an archive.
        /// Ownership: UIKit owns decoded storage. Isolation: MainActor. Errors: decoding follows UIKit. Cancellation: not applicable.
        public required init?(coder: NSCoder) {
            super.init(coder: coder); isUserInteractionEnabled = false
        }

        /// Replaces diagnostics and redraws the overlay.
        /// Ownership: entries are copied. Isolation: MainActor. Errors: invalid frames are skipped at draw time. Cancellation: not applicable.
        public func update(_ entries: [DebugOverlayEntry]) {
            self.entries = entries; setNeedsDisplay()
        }

        public override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            for entry in entries {
                let frame = CGRect(
                    x: entry.frame.origin.x, y: entry.frame.origin.y, width: entry.frame.width,
                    height: entry.frame.height)
                context.setStrokeColor(
                    (entry.isFocused ? UIColor.systemOrange : UIColor.systemBlue).cgColor)
                context.setLineWidth(entry.isFocused ? 2 : 1)
                context.stroke(frame)
                (entry.label as NSString).draw(
                    at: frame.origin,
                    withAttributes: [
                        .foregroundColor: UIColor.systemRed, .font: UIFont.systemFont(ofSize: 10),
                    ])
            }
        }
    }
#endif
