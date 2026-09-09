public import Flux

/// Platform-neutral RGBA color token.
///
/// Ownership: the value is immutable and owned by its theme. Isolation: none. Errors: components
/// normalize channels to `0...1`. Cancellation: not applicable.
public struct ThemeColor: Sendable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// Creates a normalized color token.
    ///
    /// Ownership: the returned token is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = Self.channel(red)
        self.green = Self.channel(green)
        self.blue = Self.channel(blue)
        self.alpha = Self.channel(alpha)
    }

    private static func channel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

/// Named semantic colors used by components.
///
/// Ownership: colors are immutable theme values. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ThemeColors: Sendable, Hashable {
    public let background: ThemeColor
    public let surface: ThemeColor
    public let primary: ThemeColor
    public let secondary: ThemeColor
    public let accent: ThemeColor
    public let text: ThemeColor
    public let textSecondary: ThemeColor
    public let border: ThemeColor
    public let error: ThemeColor
    public let success: ThemeColor
    public let warning: ThemeColor

    /// Creates semantic color tokens.
    ///
    /// Ownership: the returned tokens are owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    /// Creates an immutable palette.
    /// Ownership: the palette copies all token values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        background: ThemeColor, surface: ThemeColor, primary: ThemeColor, secondary: ThemeColor,
        accent: ThemeColor, text: ThemeColor, textSecondary: ThemeColor, border: ThemeColor,
        error: ThemeColor, success: ThemeColor, warning: ThemeColor
    ) {
        self.background = background; self.surface = surface; self.primary = primary
        self.secondary = secondary; self.accent = accent; self.text = text
        self.textSecondary = textSecondary; self.border = border; self.error = error
        self.success = success; self.warning = warning
    }
}

/// Typography token with explicit measure/display impact.
///
/// Ownership: the value is immutable and owned by its theme. Isolation: none. Errors: invalid
/// sizes normalize to zero. Cancellation: not applicable.
public struct Typography: Sendable, Hashable {
    public let fontName: String
    public let pointSize: Double
    public let lineHeight: Double
    public let affectsMeasure: Bool

    /// Creates a typography token.
    ///
    /// Ownership: the returned token is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        fontName: String = "system", pointSize: Double = 17, lineHeight: Double = 0,
        affectsMeasure: Bool = true
    ) {
        self.fontName = fontName
        self.pointSize = pointSize.isFinite ? max(0, pointSize) : 0
        self.lineHeight = lineHeight.isFinite ? max(0, lineHeight) : 0
        self.affectsMeasure = affectsMeasure
    }
}

/// Spacing tokens in logical points.
///
/// Ownership: values are immutable and owned by the theme. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct ThemeSpacing: Sendable, Hashable {
    public let xs: Double; public let sm: Double; public let md: Double; public let lg: Double;
    public let xl: Double
    /// Creates spacing tokens.
    ///
    /// Ownership: the returned tokens are owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(xs: Double = 4, sm: Double = 8, md: Double = 16, lg: Double = 24, xl: Double = 32) {
        self.xs = xs; self.sm = sm; self.md = md; self.lg = lg; self.xl = xl
    }
}

/// Corner radius tokens.
///
/// Ownership: values are immutable and owned by the theme. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct ThemeRadius: Sendable, Hashable {
    public let sm: Double; public let md: Double; public let lg: Double
    /// Creates radius tokens.
    ///
    /// Ownership: the returned tokens are owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(sm: Double = 4, md: Double = 8, lg: Double = 16) {
        self.sm = max(0, sm); self.md = max(0, md); self.lg = max(0, lg)
    }
}

/// Shadow and motion display-only tokens.
///
/// Ownership: values are immutable and owned by the theme. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct ThemeMotion: Sendable, Hashable {
    public let reduceMotion: Bool
    /// Creates motion policy.
    ///
    /// Ownership: the returned policy is owned by the caller. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(reduceMotion: Bool = false) { self.reduceMotion = reduceMotion }
}

/// Immutable theme snapshot propagated through Environment.
///
/// Ownership: the theme owns all token values. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Theme: Sendable, Hashable {
    public let id: String
    public let colors: ThemeColors
    public let typography: Typography
    public let spacing: ThemeSpacing
    public let radius: ThemeRadius
    public let motion: ThemeMotion

    /// Creates a theme snapshot with a stable identifier.
    ///
    /// Ownership: the returned theme owns copied token values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        id: String,
        colors: ThemeColors,
        typography: Typography = Typography(),
        spacing: ThemeSpacing = ThemeSpacing(),
        radius: ThemeRadius = ThemeRadius(),
        motion: ThemeMotion = ThemeMotion()
    ) {
        self.id = id; self.colors = colors; self.typography = typography
        self.spacing = spacing; self.radius = radius; self.motion = motion
    }
}

/// Platform-independent resolved color scheme.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ColorScheme: Sendable, Hashable {
    case light
    case dark
    case unspecified
}

/// Environment key containing the raw effective color scheme.
/// Ownership: the environment owns the immutable value. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum ColorSchemeKey: EnvironmentKey {
    public static let defaultValue: ColorScheme = .unspecified
    public static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

/// A light/dark source from which an immutable `Theme` is resolved.
/// Ownership: the palette owns immutable token values. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public struct ThemePalette: Sendable, Hashable {
    public let id: String
    public let light: ThemeColors
    public let dark: ThemeColors
    public let typography: Typography
    public let spacing: ThemeSpacing
    public let radius: ThemeRadius
    public let motion: ThemeMotion

    /// Creates an immutable light/dark palette.
    /// Ownership: the palette copies all token values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(
        id: String,
        light: ThemeColors,
        dark: ThemeColors,
        typography: Typography = Typography(),
        spacing: ThemeSpacing = ThemeSpacing(),
        radius: ThemeRadius = ThemeRadius(),
        motion: ThemeMotion = ThemeMotion()
    ) {
        self.id = id; self.light = light; self.dark = dark
        self.typography = typography; self.spacing = spacing
        self.radius = radius; self.motion = motion
    }

    /// Creates a palette using mutable builder values.
    /// Ownership: the resulting palette copies builder values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public init(id: String, _ configure: (inout Builder) -> Void) {
        var builder = Builder()
        configure(&builder)
        self.init(
            id: id, light: builder.light, dark: builder.dark,
            typography: builder.typography, spacing: builder.spacing,
            radius: builder.radius, motion: builder.motion)
    }

    /// Mutable construction values for a theme palette.
    /// Ownership: the caller owns the draft. Isolation: none. Errors: none. Cancellation: none.
    public struct Builder: Sendable {
        public var light: ThemeColors = Theme.defaultValue.colors
        public var dark: ThemeColors = ThemeColors.standardDark
        public var typography = Typography()
        public var spacing = ThemeSpacing()
        public var radius = ThemeRadius()
        public var motion = ThemeMotion()

        /// Creates builder defaults.
        /// Ownership: the caller owns the draft. Isolation: none. Errors: none.
        /// Cancellation: not applicable.
        public init() {}
    }

    /// Resolves the palette into a theme snapshot.
    /// Ownership: the returned theme owns copied values. Isolation: none. Errors: none.
    /// Cancellation: not applicable.
    public func resolved(for scheme: ColorScheme) -> Theme {
        Theme(
            id: "\(id).\(scheme)", colors: scheme == .dark ? dark : light,
            typography: typography, spacing: spacing, radius: radius, motion: motion)
    }
}

/// Inherited theme environment key.
///
/// Ownership: the key provides an immutable default snapshot. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public enum ThemeKey: EnvironmentKey {
    public static let defaultValue = Theme.defaultValue
    public static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

public extension ThemeColors {
    /// Standard dark semantic colors used by `ThemePalette.standard`.
    static let standardDark = ThemeColors(
        background: ThemeColor(red: 0.05, green: 0.05, blue: 0.07),
        surface: ThemeColor(red: 0.12, green: 0.12, blue: 0.15),
        primary: ThemeColor(red: 0.45, green: 0.55, blue: 1),
        secondary: ThemeColor(red: 0.65, green: 0.65, blue: 0.7),
        accent: ThemeColor(red: 0.3, green: 0.65, blue: 1),
        text: ThemeColor(red: 1, green: 1, blue: 1),
        textSecondary: ThemeColor(red: 0.72, green: 0.72, blue: 0.76),
        border: ThemeColor(red: 0.3, green: 0.3, blue: 0.35),
        error: ThemeColor(red: 1, green: 0.35, blue: 0.35),
        success: ThemeColor(red: 0.3, green: 0.8, blue: 0.45),
        warning: ThemeColor(red: 1, green: 0.7, blue: 0.25))
}

public extension ThemePalette {
    /// Standard light/dark palette.
    static let standard = ThemePalette(
        id: "standard", light: Theme.defaultValue.colors, dark: .standardDark)
}

/// Content size categories used by typography resolution.
///
/// Ownership: the value is immutable and owned by its environment snapshot. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public enum ContentSizeCategory: Sendable, Hashable {
    case small, medium, large, extraLarge, accessibilityLarge
}

/// Environment key for Dynamic Type/content-size resolution.
///
/// Ownership: the key provides an immutable default. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ContentSizeCategoryKey: EnvironmentKey {
    public static let defaultValue: ContentSizeCategory = .large
    public static let invalidation: EnvironmentInvalidation = .layout
}

extension Theme {
    /// Stable neutral default theme.
    public static let defaultValue = Theme(
        id: "default",
        colors: ThemeColors(
            background: ThemeColor(red: 1, green: 1, blue: 1),
            surface: ThemeColor(red: 0.96, green: 0.96, blue: 0.98),
            primary: ThemeColor(red: 0.1, green: 0.2, blue: 0.8),
            secondary: ThemeColor(red: 0.3, green: 0.3, blue: 0.35),
            accent: ThemeColor(red: 0.2, green: 0.5, blue: 1),
            text: ThemeColor(red: 0, green: 0, blue: 0),
            textSecondary: ThemeColor(red: 0.3, green: 0.3, blue: 0.3),
            border: ThemeColor(red: 0.8, green: 0.8, blue: 0.8),
            error: ThemeColor(red: 0.8, green: 0.1, blue: 0.1),
            success: ThemeColor(red: 0.1, green: 0.6, blue: 0.2),
            warning: ThemeColor(red: 0.8, green: 0.5, blue: 0.1)
        )
    )
}

public extension EnvironmentValues {
    /// Effective inherited theme snapshot.
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
    /// Raw effective color scheme; resolution into colors is performed by `ThemePalette`.
    var colorScheme: ColorScheme {
        get { self[ColorSchemeKey.self] }
        set { self[ColorSchemeKey.self] = newValue }
    }
    /// Effective Dynamic Type category.
    var contentSizeCategory: ContentSizeCategory {
        get { self[ContentSizeCategoryKey.self] }
        set { self[ContentSizeCategoryKey.self] = newValue }
    }
}

/// Actor-owned source of themes backed by the same NodeState/Flux runtime.
///
/// Ownership: the store owns its actor state. Isolation: actor isolation. Errors: none.
/// Cancellation: awaiting callers may cancel without corrupting the current theme.
public actor ThemeStore {
    private let state: NodeState<Theme>
    private let paletteState: NodeState<ThemePalette>
    private let schemeState: NodeState<ColorScheme>
    /// Creates a theme source.
    ///
    /// Ownership: the store owns its state actor. Isolation: actor isolation. Errors: none.
    /// Cancellation: not applicable.
    public init(initial: Theme = .defaultValue) {
        state = NodeState(initial)
        paletteState = NodeState(
            ThemePalette(
                id: initial.id,
                light: initial.colors,
                dark: initial.colors,
                typography: initial.typography,
                spacing: initial.spacing,
                radius: initial.radius,
                motion: initial.motion))
        schemeState = NodeState(.unspecified)
    }

    /// Creates a store backed by a light/dark palette.
    /// Ownership: the store owns immutable actor state. Isolation: actor isolation. Errors: none.
    /// Cancellation: not applicable.
    public init(palette: ThemePalette, scheme: ColorScheme = .unspecified) {
        paletteState = NodeState(palette)
        schemeState = NodeState(scheme)
        state = NodeState(palette.resolved(for: scheme))
    }
    /// Current theme stream with replay and distinct updates.
    public nonisolated var flux: Flux<Theme> { state.flux }
    /// Applies a theme and optionally commits it to a MainActor environment scope.
    ///
    /// Ownership: the store copies the theme. Isolation: actor isolation with MainActor scope apply.
    /// Errors: none. Cancellation: task cancellation stops awaiting work.
    public func apply(_ theme: Theme, to scope: EnvironmentScope? = nil) async {
        _ = await state.set(theme)
        _ = await paletteState.set(
            ThemePalette(
                id: theme.id,
                light: theme.colors,
                dark: theme.colors,
                typography: theme.typography,
                spacing: theme.spacing,
                radius: theme.radius,
                motion: theme.motion))
        if let scope { _ = await MainActor.run { scope.set(ThemeKey.self, theme) } }
    }

    /// Applies a palette and/or scheme and optionally commits the resolved theme.
    /// Ownership: the store copies immutable values. Isolation: actor isolation with MainActor
    /// scope commit. Errors: none. Cancellation: awaiting callers may cancel safely.
    public func apply(
        palette: ThemePalette? = nil,
        scheme: ColorScheme? = nil,
        to scope: EnvironmentScope? = nil
    ) async {
        let nextPalette: ThemePalette
        if let palette {
            nextPalette = palette
        } else {
            nextPalette = await paletteState.value
        }
        let nextScheme: ColorScheme
        if let scheme {
            nextScheme = scheme
        } else {
            nextScheme = await schemeState.value
        }
        _ = await paletteState.set(nextPalette)
        _ = await schemeState.set(nextScheme)
        let resolved = nextPalette.resolved(for: nextScheme)
        _ = await state.set(resolved)
        if let scope {
            _ = await MainActor.run {
                scope.commitTheme(colorScheme: nextScheme, theme: resolved)
            }
        }
    }

    /// Current palette snapshot.
    public var currentPalette: ThemePalette { get async { await paletteState.value } }

    /// Current color scheme.
    public var currentScheme: ColorScheme { get async { await schemeState.value } }
    /// Reads the latest theme.
    ///
    /// Ownership: the returned theme is copied from actor state. Isolation: actor isolation. Errors:
    /// none. Cancellation: not applicable.
    public var current: Theme { get async { await state.value } }
}
