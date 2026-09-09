import Foundation

/// Provides the locale inherited by a Weave tree.
///
/// Ownership: the key exposes an immutable value copied into environment snapshots. Isolation:
/// none. Errors: none. Cancellation: not applicable.
public enum LocaleKey: EnvironmentKey {
    public static let defaultValue = Locale(identifier: "en_US_POSIX")
    public static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

/// Provides an optional explicit direction override for a Weave tree.
///
/// Ownership: the key exposes an immutable optional value copied into environment snapshots.
/// Isolation: none. Errors: none. Cancellation: not applicable.
public enum LayoutDirectionKey: EnvironmentKey {
    public static let defaultValue: LayoutDirection? = nil
    public static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

/// Resolves a deterministic logical direction from an explicit override or locale.
///
/// Ownership: the returned direction is a value owned by the caller. Isolation: none. Errors:
/// unknown languages resolve to left-to-right. Cancellation: not applicable.
public enum LayoutDirectionResolver {
    /// Resolves direction without reading platform globals or shared mutable state.
    ///
    /// Ownership: inputs are borrowed values; the result is an immutable value. Isolation: none.
    /// Errors: none. Cancellation: not applicable.
    public static func resolve(
        locale: Locale, override: LayoutDirection? = nil
    ) -> LayoutDirection {
        if let override { return override }
        let language = (locale.language.languageCode?.identifier ?? "und").lowercased()
        return rtlLanguages.contains(language) ? .rightToLeft : .leftToRight
    }

    private static let rtlLanguages: Set<String> = ["ar", "fa", "he", "iw", "ps", "ur", "yi"]
}

/// Adds typed locale and direction accessors to an environment value snapshot.
///
/// Ownership: values are copied through the enclosing snapshot. Isolation: none. Errors: none.
/// Cancellation: not applicable.
public extension EnvironmentValues {
    /// The inherited locale used by localization and text measurement.
    var locale: Locale {
        get { self[LocaleKey.self] }
        set { self[LocaleKey.self] = newValue }
    }

    /// An optional inherited direction override; nil means resolve from locale.
    var layoutDirectionOverride: LayoutDirection? {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }

    /// The effective direction for this snapshot.
    var layoutDirection: LayoutDirection {
        LayoutDirectionResolver.resolve(locale: locale, override: layoutDirectionOverride)
    }
}
