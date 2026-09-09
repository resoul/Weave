/// Read-only overlay entry derived from a debug node snapshot.
/// Ownership: immutable copied diagnostics. Isolation: none. Errors: missing frames are omitted by views. Cancellation: not applicable.
public struct DebugOverlayEntry: Sendable, Hashable {
    public let identity: ElementID
    public let frame: LayoutFrame
    public let label: String
    public let isFocused: Bool

    /// Creates an overlay entry.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(identity: ElementID, frame: LayoutFrame, label: String, isFocused: Bool = false) {
        self.identity = identity
        self.frame = frame
        self.label = label
        self.isFocused = isFocused
    }
}
