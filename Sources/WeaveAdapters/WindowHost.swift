import WeaveUI

/// Platform-neutral lifecycle contract for a native host of one logical window.
/// Ownership: the host owns native resources and borrows the logical window. Isolation:
/// MainActor. Errors: an empty logical root is reported by `mount()`. Cancellation: `unmount()`
/// releases native callbacks and view state.
@MainActor
public protocol WindowHost: AnyObject {
    var logicalWindow: Window { get }

    /// Mounts the current logical root into the native host.
    /// - Returns: `true` when a root is mounted or was already mounted.
    @discardableResult
    func mount() -> Bool

    /// Releases native hierarchy and callbacks while retaining the logical window.
    func unmount()
}
