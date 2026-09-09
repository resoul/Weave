import Foundation
import Flux

/// Typed interpolation argument for localized text.
/// Ownership: the argument is copied into LocalizedText. Isolation: none. Errors: invalid numbers normalize during formatting. Cancellation: not applicable.
public enum LocalizedArgument: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case number(Double)
    case date(Date)

    /// Creates a string argument.
    /// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public static func text(_ value: String) -> Self { .string(value) }
}

/// Immutable localization resource set.
/// Ownership: the catalog owns copied resources. Isolation: none. Errors: missing keys fall back. Cancellation: not applicable.
public struct LocalizationCatalog: Sendable, Hashable {
    public let tables: [String: [String: String]]
    public let plurals: [String: [String: [String: String]]]

    /// Creates a catalog.
    /// Ownership: dictionaries are copied. Isolation: none. Errors: malformed forms fall back to `other`. Cancellation: not applicable.
    public init(
        tables: [String: [String: String]] = [:],
        plurals: [String: [String: [String: String]]] = [:]
    ) {
        self.tables = tables; self.plurals = plurals
    }
}

/// Diagnostic for a missing localization key.
/// Ownership: the diagnostic is copied by consumers. Isolation: none. Errors: represented as typed state. Cancellation: not applicable.
public struct LocalizationDiagnostic: Sendable, Hashable {
    public let key: String
    public let localeIdentifier: String
    public let table: String?

    /// Creates a diagnostic.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(key: String, localeIdentifier: String, table: String?) {
        self.key = key; self.localeIdentifier = localeIdentifier; self.table = table
    }
}

/// Resolved localized text and fallback metadata.
/// Ownership: the result owns its rendered string. Isolation: none. Errors: missing keys expose `diagnostic`. Cancellation: not applicable.
public struct ResolvedLocalizedText: Sendable, Hashable {
    public let text: String
    public let usedFallback: Bool
    public let diagnostic: LocalizationDiagnostic?

    /// Creates a resolved value.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(text: String, usedFallback: Bool, diagnostic: LocalizationDiagnostic? = nil) {
        self.text = text; self.usedFallback = usedFallback; self.diagnostic = diagnostic
    }
}

/// Immutable localization provider contract.
/// Ownership: the provider owns its catalog. Isolation: Sendable value boundary. Errors: missing keys return fallback diagnostics. Cancellation: synchronous resolution is not cancellable.
public protocol LocalizationProvider: Sendable {
    func resolve(_ value: LocalizedText, locale: Locale, pseudo: Bool) -> ResolvedLocalizedText
}

/// Deterministic catalog-backed provider with interpolation, pluralization and pseudo locale support.
/// Ownership: the provider owns an immutable catalog. Isolation: none. Errors: missing keys fall back to LocalizedText.fallback. Cancellation: no work is scheduled.
public struct CatalogLocalizationProvider: LocalizationProvider {
    public let catalog: LocalizationCatalog

    /// Creates a provider.
    /// Ownership: the catalog is copied. Isolation: none. Errors: none. Cancellation: no work starts.
    public init(catalog: LocalizationCatalog = LocalizationCatalog()) { self.catalog = catalog }

    /// Resolves a localized value.
    /// Ownership: the result owns the rendered string. Isolation: none. Errors: missing keys produce diagnostics. Cancellation: not applicable.
    public func resolve(_ value: LocalizedText, locale: Locale, pseudo: Bool = false)
        -> ResolvedLocalizedText
    {
        let table = value.table ?? "Localizable"
        let raw: String?
        if let count = value.arguments.compactMap({ argument -> Int? in
            if case let .integer(number) = argument { return number }; return nil
        }).first {
            let forms = catalog.plurals[table]?[value.key]
            raw = forms?[count == 1 ? "one" : "other"] ?? forms?["other"]
        } else {
            raw = catalog.tables[table]?[value.key]
        }
        let usedFallback = raw == nil
        let rendered = interpolate(
            raw ?? value.fallback, arguments: value.arguments, locale: locale)
        let text = pseudo ? "［" + pseudoLocalize(rendered) + "］" : rendered
        return ResolvedLocalizedText(
            text: text,
            usedFallback: usedFallback,
            diagnostic: usedFallback
                ? LocalizationDiagnostic(
                    key: value.key, localeIdentifier: locale.identifier, table: value.table)
                : nil
        )
    }

    private func interpolate(_ template: String, arguments: [LocalizedArgument], locale: Locale)
        -> String
    {
        var result = template
        for (index, argument) in arguments.enumerated() {
            let replacement: String
            switch argument {
            case let .string(value): replacement = value
            case let .integer(value): replacement = value.formatted(.number.locale(locale))
            case let .number(value): replacement = value.formatted(.number.locale(locale))
            case let .date(value):
                replacement = value.formatted(.dateTime.year().month().day().locale(locale))
            }
            result = result.replacingOccurrences(of: "%\(index + 1)$@", with: replacement)
        }
        return result
    }

    private func pseudoLocalize(_ value: String) -> String {
        let replacements: [Character: Character] = [
            "a": "à", "e": "ë", "i": "ï", "o": "ø", "u": "ü",
        ]
        return String(value.map { replacements[$0] ?? $0 })
    }
}

/// Revisioned locale update.
/// Ownership: the event is copied by bounded subscribers. Isolation: none. Errors: none. Cancellation: subscriptions cancel independently.
public struct LocalizationChange: Sendable, Hashable {
    public let locale: Locale
    public let revision: UInt64

    /// Creates a locale change.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(locale: Locale, revision: UInt64) { self.locale = locale; self.revision = revision }
}

/// MainActor locale store and typed invalidation source.
/// Ownership: the store owns provider and bounded changes. Isolation: MainActor. Errors: resolution returns typed diagnostics. Cancellation: subscribers cancel through Flux.
@MainActor
public final class LocalizationStore {
    public private(set) var locale: Locale
    public private(set) var revision: UInt64 = 0
    public var pseudoLocalization = false
    public let changes: ActionPipe<LocalizationChange>
    public let provider: any LocalizationProvider

    /// Creates a locale store.
    /// Ownership: the store retains provider and pipe. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(locale: Locale, provider: any LocalizationProvider) {
        self.locale = locale; self.provider = provider; changes = ActionPipe(capacity: 16)
    }

    /// Commits a locale and emits one revisioned change.
    /// Ownership: locale is copied. Isolation: MainActor. Errors: same-locale changes return false. Cancellation: no asynchronous work starts.
    @discardableResult
    public func setLocale(_ locale: Locale) -> Bool {
        guard locale.identifier != self.locale.identifier else { return false }
        self.locale = locale; revision &+= 1
        _ = changes.send(LocalizationChange(locale: locale, revision: revision))
        return true
    }

    /// Resolves text using the current locale snapshot.
    /// Ownership: result owns rendered text. Isolation: MainActor. Errors: missing keys return diagnostics. Cancellation: not applicable.
    public func resolve(_ value: LocalizedText) -> ResolvedLocalizedText {
        provider.resolve(value, locale: locale, pseudo: pseudoLocalization)
    }
}
