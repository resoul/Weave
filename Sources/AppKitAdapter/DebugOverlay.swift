#if canImport(AppKit)
    import AppKit
    import WeaveUI

    /// Non-interactive AppKit debug overlay. It draws diagnostics and passes all input through.
    /// Ownership: the view owns drawing state. Isolation: MainActor. Errors: invalid frames are skipped. Cancellation: no work starts.
    @MainActor
    public final class AppKitDebugOverlayView: NSView {
        private var entries: [DebugOverlayEntry] = []

        /// Creates a transparent, input-pass-through overlay.
        /// Ownership: the view owns its drawing state. Isolation: MainActor. Errors: none. Cancellation: no work starts.
        public override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        /// Creates an overlay from an archive.
        /// Ownership: AppKit owns decoded storage. Isolation: MainActor. Errors: decoding follows AppKit. Cancellation: not applicable.
        public required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }

        /// Replaces diagnostics and redraws the overlay.
        /// Ownership: entries are copied. Isolation: MainActor. Errors: invalid frames are skipped at draw time. Cancellation: not applicable.
        public func update(_ entries: [DebugOverlayEntry]) {
            self.entries = entries; needsDisplay = true
        }

        public override func draw(_ dirtyRect: NSRect) {
            for entry in entries {
                let frame = NSRect(
                    x: entry.frame.origin.x, y: entry.frame.origin.y, width: entry.frame.width,
                    height: entry.frame.height)
                (entry.isFocused ? NSColor.systemOrange : NSColor.systemBlue).setStroke()
                NSBezierPath(rect: frame).stroke()
                (entry.label as NSString).draw(
                    at: frame.origin,
                    withAttributes: [
                        .foregroundColor: NSColor.systemRed, .font: NSFont.systemFont(ofSize: 10),
                    ])
            }
        }

        public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
#endif
