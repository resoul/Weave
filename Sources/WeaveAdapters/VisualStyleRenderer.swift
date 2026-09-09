import CoreGraphics
import QuartzCore
import WeaveUI

/// Applies paint-only presentation to a CALayer.
///
/// Ownership: the layer remains owned by its adapter; the style is read by value. Isolation:
/// MainActor is required by callers because CALayer is a native object. Errors: unsupported
/// presentation is represented by cleared layer properties. Cancellation: not applicable.
public func applyVisualStyle(
    _ appearance: VisualStyle,
    to layer: CALayer,
    theme: Theme = .defaultValue
) {
    switch appearance.background {
    case .none:
        layer.backgroundColor = nil
    case let .color(color):
        layer.backgroundColor = cgColor(color)
    case let .theme(role):
        layer.backgroundColor = cgColor(theme.color(for: role))
    }

    layer.cornerRadius = CGFloat(appearance.cornerRadius)
    if let border = appearance.border {
        layer.borderWidth = CGFloat(border.width)
        layer.borderColor = cgColor(border.color)
    } else {
        layer.borderWidth = 0
        layer.borderColor = nil
    }

    if let shadow = appearance.shadow {
        layer.shadowColor = cgColor(shadow.color)
        layer.shadowOpacity = Float(shadow.opacity)
        layer.shadowRadius = CGFloat(shadow.radius)
        layer.shadowOffset = CGSize(width: shadow.offset.x, height: shadow.offset.y)
    } else {
        layer.shadowColor = nil
        layer.shadowOpacity = 0
        layer.shadowRadius = 0
        layer.shadowOffset = .zero
    }
}

/// Resolves a semantic theme role for adapter-owned presentation layers.
/// Ownership: the returned color is value-owned. Isolation: none. Errors: roles are exhaustive.
/// Cancellation: not applicable.
public func resolveThemeColor(_ role: ThemeColorRole, in theme: Theme) -> ThemeColor {
    switch role {
    case .background: theme.colors.background
    case .surface: theme.colors.surface
    case .primary: theme.colors.primary
    case .secondary: theme.colors.secondary
    case .accent: theme.colors.accent
    case .text: theme.colors.text
    case .textSecondary: theme.colors.textSecondary
    case .border: theme.colors.border
    case .error: theme.colors.error
    case .success: theme.colors.success
    case .warning: theme.colors.warning
    }
}

private extension Theme {
    func color(for role: ThemeColorRole) -> ThemeColor {
        switch role {
        case .background: colors.background
        case .surface: colors.surface
        case .primary: colors.primary
        case .secondary: colors.secondary
        case .accent: colors.accent
        case .text: colors.text
        case .textSecondary: colors.textSecondary
        case .border: colors.border
        case .error: colors.error
        case .success: colors.success
        case .warning: colors.warning
        }
    }
}

private func cgColor(_ color: ThemeColor) -> CGColor {
    CGColor(
        red: CGFloat(color.red),
        green: CGFloat(color.green),
        blue: CGFloat(color.blue),
        alpha: CGFloat(color.alpha)
    )
}
