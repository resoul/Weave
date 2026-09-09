import Foundation

public import Flux

/// Stable typed command identity. Ownership: raw value is copied. Isolation: none. Errors: empty IDs are accepted for composition.
/// Cancellation: not applicable.
public struct CommandID: RawRepresentable, Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Creates an identity. Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Creates an identity from a string literal. Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(stringLiteral value: String) { self.init(rawValue: value) }
}

/// Command execution scope. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum CommandScope: Sendable, Hashable {
    case application
    case scene(SceneID)
    case controller(String)
}

/// Keyboard modifier set shared by adapters. Ownership: immutable option set. Isolation: none. Errors: none. Cancellation: not applicable.
public struct CommandModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public static let command = Self(rawValue: 1 << 0)
    public static let shift = Self(rawValue: 1 << 1)
    public static let option = Self(rawValue: 1 << 2)
    public static let control = Self(rawValue: 1 << 3)

    /// Creates modifiers from a stable raw representation. Ownership: value is copied. Isolation: none. Errors: unknown bits are retained. Cancellation: not applicable.
    public init(rawValue: UInt8) { self.rawValue = rawValue }
}

/// Platform-neutral keyboard shortcut. Ownership: values are copied. Isolation: none. Errors: empty key is allowed for commands without a shortcut. Cancellation: not applicable.
public struct CommandShortcut: Sendable, Hashable {
    public let key: String
    public let modifiers: CommandModifiers

    /// Creates a shortcut. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(key: String, modifiers: CommandModifiers = []) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }
}

/// Declarative command metadata. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: action owns its work.
public struct CommandDefinition: Sendable, Hashable {
    public let id: CommandID
    public let title: LocalizedText
    public let scope: CommandScope
    public let shortcut: CommandShortcut?

    /// Creates command metadata. Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        id: CommandID,
        title: LocalizedText,
        scope: CommandScope = .application,
        shortcut: CommandShortcut? = nil
    ) {
        self.id = id
        self.title = title
        self.scope = scope
        self.shortcut = shortcut
    }
}

/// A command execution event. Ownership: immutable snapshot. Isolation: none. Errors: failures are typed by registry result. Cancellation: not applicable.
public struct CommandEvent: Sendable, Hashable {
    public let id: CommandID
    public let scope: CommandScope

    /// Creates an execution event. Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: CommandID, scope: CommandScope) {
        self.id = id
        self.scope = scope
    }
}

/// Result of command dispatch. Ownership: immutable value. Isolation: none. Errors: represented by cases. Cancellation: caller-owned.
public enum CommandDispatchResult: Sendable, Hashable {
    case executed
    case disabled
    case unavailable
    case noFocusedScope
}

/// Capability advertised by a platform command presenter. Ownership: immutable value. Isolation: none. Errors: unsupported capabilities use fallback. Cancellation: not applicable.
public enum CommandCapability: Sendable, Hashable {
    case menu
    case toolbar
    case keyboard
    case remote
}

/// Registration handle used to remove commands at lifecycle disposal. Ownership: handle borrows registry weakly. Isolation: MainActor. Errors: dispose is idempotent. Cancellation: disposal unregisters the command.
@MainActor
public final class CommandRegistration {
    private weak var registry: CommandRegistry?
    private let id: CommandID
    private var disposed = false

    fileprivate init(registry: CommandRegistry, id: CommandID) {
        self.registry = registry
        self.id = id
    }

    /// Removes the command registration. Ownership: registry releases action and metadata. Isolation: MainActor. Errors: repeated calls are ignored. Cancellation: pending execution is not started again.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        registry?.unregister(id)
    }
}

/// Main-actor command registry with scope arbitration, reactive enablement and bounded events.
/// Ownership: registry owns definitions/actions and registrations. Isolation: MainActor. Errors: disabled/unavailable results are typed. Cancellation: lifecycle disposal removes actions.
@MainActor
public final class CommandRegistry {
    private struct Entry {
        let definition: CommandDefinition
        var enabled: Bool
        let action: @MainActor @Sendable () async -> Void
    }

    private var entries: [CommandID: Entry] = [:]
    private var focusedScene: SceneID?
    private var focusedController: String?
    private let eventsPipe = Pipe<CommandEvent>(bufferingPolicy: .bufferingNewest(32))

    /// Creates an empty command registry. Ownership: registry owns its bounded event pipe. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {}

    /// Execution events for analytics/tooling. Ownership: subscriber owns the stream. Isolation: MainActor publication. Errors: bounded overflow is coalesced. Cancellation: subscription-owned.
    public var events: Flux<CommandEvent> { eventsPipe.flux }

    /// Registers or replaces a command action. Ownership: registry retains the action. Isolation: MainActor. Errors: duplicate IDs replace previous entries. Cancellation: registration disposal removes the entry.
    @discardableResult
    public func register(
        _ definition: CommandDefinition,
        enabled: Bool = true,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> CommandRegistration {
        entries[definition.id] = Entry(definition: definition, enabled: enabled, action: action)
        return CommandRegistration(registry: self, id: definition.id)
    }

    /// Changes reactive enablement. Ownership: no value escapes. Isolation: MainActor. Errors: unknown IDs are ignored. Cancellation: not applicable.
    public func setEnabled(_ enabled: Bool, for id: CommandID) {
        guard var entry = entries[id] else { return }
        entry.enabled = enabled
        entries[id] = entry
    }

    /// Sets the active scene/controller scope used for conflict arbitration. Ownership: IDs are copied. Isolation: MainActor. Errors: nil clears that scope. Cancellation: not applicable.
    public func setFocus(scene: SceneID?, controller: String? = nil) {
        focusedScene = scene
        focusedController = controller
    }

    /// Executes the command that wins scope arbitration. Ownership: action remains registry-owned. Isolation: MainActor. Errors: disabled/unavailable are returned. Cancellation: action observes caller task policy.
    public func execute(_ id: CommandID) async -> CommandDispatchResult {
        guard let entry = entries[id] else { return .unavailable }
        guard isInFocusedScope(entry.definition.scope) else { return .noFocusedScope }
        guard entry.enabled else { return .disabled }
        await entry.action()
        eventsPipe.send(CommandEvent(id: id, scope: entry.definition.scope))
        return .executed
    }

    /// Executes a shortcut in the active scope. Ownership: shortcut is borrowed. Isolation: MainActor. Errors: no matching shortcut returns unavailable. Cancellation: action policy applies.
    public func execute(_ shortcut: CommandShortcut) async -> CommandDispatchResult {
        let matching = entries.values.filter {
            $0.definition.shortcut == shortcut && isInFocusedScope($0.definition.scope)
        }
        guard
            let id =
                matching
                .sorted(by: { scopeRank($0.definition.scope) > scopeRank($1.definition.scope) })
                .first?.definition.id
        else { return .unavailable }
        return await execute(id)
    }

    /// Removes one command. Ownership: registry releases its action. Isolation: MainActor. Errors: unknown IDs are ignored. Cancellation: subsequent execution is unavailable.
    fileprivate func unregister(_ id: CommandID) { entries.removeValue(forKey: id) }

    /// Returns metadata for native menu/toolbar presenters. Ownership: returned values are copied. Isolation: MainActor. Errors: unavailable IDs are omitted. Cancellation: not applicable.
    public func definitions(capability: CommandCapability) -> [CommandDefinition] {
        _ = capability
        return entries.values.map(\.definition).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func isInFocusedScope(_ scope: CommandScope) -> Bool {
        switch scope {
        case .application: return true
        case let .scene(scene): return focusedScene == scene
        case let .controller(controller): return focusedController == controller
        }
    }

    private func scopeRank(_ scope: CommandScope) -> Int {
        switch scope {
        case .application: return 0
        case .scene: return 1
        case .controller: return 2
        }
    }
}
