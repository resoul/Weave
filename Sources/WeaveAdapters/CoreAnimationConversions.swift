import QuartzCore
import WeaveUI

extension AnimationCurve {
    /// Converts to the `CAMediaTimingFunction` `CATransaction` expects.
    /// Ownership: returned value is caller-owned. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public var mediaTimingFunction: CAMediaTimingFunction {
        switch self {
        case .linear: return CAMediaTimingFunction(name: .linear)
        case .easeIn: return CAMediaTimingFunction(name: .easeIn)
        case .easeOut: return CAMediaTimingFunction(name: .easeOut)
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        case .spring: return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }
}

extension LayoutTransform {
    /// Converts to the `CGAffineTransform` `CALayer.setAffineTransform(_:)` expects.
    /// Ownership: returned value is caller-owned. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public var affineTransform: CGAffineTransform {
        CGAffineTransform(
            a: CGFloat(scaleX), b: 0, c: 0, d: CGFloat(scaleY),
            tx: CGFloat(translationX), ty: CGFloat(translationY)
        ).rotated(by: CGFloat(rotationRadians))
    }
}
