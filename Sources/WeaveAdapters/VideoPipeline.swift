#if canImport(QuartzCore)
    import CoreGraphics
    import Foundation
    import QuartzCore
    import WeaveUI

    /// Platform adapter protocol for video backends capable of directly attaching a CALayer
    /// (such as AVPlayerLayer) to the node's backing CALayer without allocating a native view host.
    ///
    /// Ownership: the backend owns its player layer; the host CALayer borrows the sublayer.
    /// Isolation: MainActor. Errors: none. Cancellation: `detachVideoLayer()` releases the sublayer.
    @MainActor
    public protocol CALayerAttachingVideoBackend: VideoBackend {
        /// Attaches the backend's video layer as a sublayer of the provided host CALayer.
        /// Ownership: hostLayer borrows player layer. Isolation: MainActor. Errors: none. Cancellation: detach removes sublayer.
        func attachVideoLayer(to hostLayer: CALayer)

        /// Detaches the video sublayer from its superlayer.
        /// Ownership: player layer is unlinked from hierarchy. Isolation: MainActor. Errors: none. Cancellation: idempotent.
        func detachVideoLayer()

        /// Updates the video layer's frame within the host layer.
        /// Ownership: frame is copied. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        func updateVideoLayerBounds(_ bounds: CGRect)
    }
#endif
