import Foundation
import Storage

/// Serializable state for one navigation stack. Ownership: routes and screen state are copied.
/// Isolation: none. Errors: encoding errors are reported by the restorer. Cancellation: caller-owned.
public struct NavigationStackState<R: Route & Codable>: Codable, Sendable, Hashable {
    public let identifier: String
    public let routes: [R]
    public let screenState: [String: String]

    /// Creates a stack snapshot without runtime controllers or nodes. Ownership: arguments are copied.
    /// Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        identifier: String,
        routes: [R],
        screenState: [String: String] = [:]
    ) {
        self.identifier = identifier
        self.routes = routes
        self.screenState = screenState
    }
}

/// Versioned serializable navigation state. Ownership: the value owns copied route snapshots.
/// Isolation: none. Errors: malformed data is reported during decoding. Cancellation: not applicable.
public struct NavigationState<R: Route & Codable>: Codable, Sendable, Hashable {
    public let selectedTab: String?
    public let stacks: [NavigationStackState<R>]
    public let presentedRoute: R?
    public let schemaVersion: Int

    /// Creates a navigation snapshot. Ownership: arguments are copied. Isolation: none. Errors: version is clamped to one. Cancellation: not applicable.
    public init(
        selectedTab: String? = nil,
        stacks: [NavigationStackState<R>],
        presentedRoute: R? = nil,
        schemaVersion: Int = 1
    ) {
        self.selectedTab = selectedTab
        self.stacks = stacks
        self.presentedRoute = presentedRoute
        self.schemaVersion = max(1, schemaVersion)
    }
}

/// Policy for routes that cannot be restored. Ownership: immutable value. Isolation: none.
/// Errors: represented by policy cases. Cancellation: not applicable.
public enum NavigationRestorePolicy: Sendable, Hashable {
    case skipUnknownRoutes
    case fallbackToRoot
}

/// Errors raised by navigation restoration. Ownership: immutable diagnostic value. Isolation: none.
/// Errors: this is the typed restoration error surface. Cancellation: cancellation remains separate.
public enum NavigationRestorationError: Error, Sendable, Hashable {
    case invalidScene
    case corruptEnvelope
    case unsupportedSchema(Int)
    case missingMigration(from: Int, to: Int)
    case missingRoot
    case factoryFailed(String)
}

/// Result of applying a restoration snapshot. Ownership: immutable result value. Isolation: none.
/// Errors: fallback reasons are represented in the result. Cancellation: cancelled restores throw.
public enum NavigationRestoreResult: Sendable, Hashable {
    case restored(routeCount: Int)
    case rootFallback(reason: String)
}

/// Version migration for a decoded navigation state. Ownership: migration retains its Sendable closure.
/// Isolation: none. Errors: closure errors propagate. Cancellation: caller-owned.
public struct NavigationStateMigration<R: Route & Codable>: Sendable {
    public let fromVersion: Int
    public let toVersion: Int
    private let transform: @Sendable (NavigationState<R>) throws -> NavigationState<R>

    /// Creates one explicit version step. Ownership: closure is retained. Isolation: none.
    /// Errors: transform errors propagate. Cancellation: caller-owned.
    public init(
        fromVersion: Int,
        toVersion: Int,
        transform: @escaping @Sendable (NavigationState<R>) throws -> NavigationState<R>
    ) {
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.transform = transform
    }

    fileprivate func apply(_ state: NavigationState<R>) throws -> NavigationState<R> {
        try transform(state)
    }
}

/// Async capture/restore contract for a scene-local navigation state. Ownership: conformer owns its persistence boundary. Isolation: MainActor. Errors: typed capture/restore errors. Cancellation: caller-owned.
@MainActor
public protocol NavigationStateRestoring: AnyObject {
    /// Captures routes and allowed serializable screen state. Ownership: returned bytes are caller-owned.
    /// Isolation: MainActor with async storage boundary. Errors: storage/encoding failures throw. Cancellation: propagates.
    func capture() async throws -> Data

    /// Restores state and reconstructs controllers through the registry. Ownership: runtime graph remains restorer-owned.
    /// Isolation: MainActor. Errors: corruption and factory failures follow policy or throw. Cancellation: propagates.
    func restore(from data: Data) async throws -> NavigationRestoreResult
}

/// Main-actor scene restorer that persists a versioned, scene-keyed envelope and rebuilds controllers through ScreenRegistry.
/// Ownership: restorer owns policy and navigation references and borrows the registry/storage. Isolation: MainActor.
/// Errors: typed restoration and storage errors. Cancellation: restore stops before the next controller when cancelled.
@MainActor
public final class NavigationRestorer<R: Route & Codable>: NavigationStateRestoring {
    /// Provider for immutable scene state. Ownership: restorer retains the closure. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public typealias StateProvider = @MainActor @Sendable () -> NavigationState<R>
    /// Validator for routes allowed by the current product. Ownership: restorer retains the closure. Isolation: none. Errors: false marks unknown routes. Cancellation: not applicable.
    public typealias RouteValidator = @Sendable (R) -> Bool

    private struct Envelope: Codable, Sendable {
        let sceneKey: String
        let schemaVersion: Int
        let state: NavigationState<R>
    }

    private let sceneID: SceneID
    private let storageKey: String
    private let store: any Store
    private let provider: StateProvider
    private let rootRoute: R
    private let registry: ScreenRegistry
    private let navigation: NavigationController<R>
    private let migrations: [NavigationStateMigration<R>]
    private let policy: NavigationRestorePolicy
    private let validator: RouteValidator
    private let currentSchemaVersion: Int

    /// Creates a scene-local restorer. Ownership: dependencies are retained or borrowed as documented.
    /// Isolation: MainActor. Errors: invalid schema configuration is reported during capture/restore. Cancellation: no work starts.
    public init(
        sceneID: SceneID,
        store: any Store,
        storageKey: String = "Weave.Navigation",
        currentSchemaVersion: Int,
        provider: @escaping StateProvider,
        rootRoute: R,
        registry: ScreenRegistry,
        navigation: NavigationController<R>,
        migrations: [NavigationStateMigration<R>] = [],
        policy: NavigationRestorePolicy = .fallbackToRoot,
        validator: @escaping RouteValidator = { _ in true }
    ) {
        self.sceneID = sceneID
        self.storageKey = storageKey
        self.store = store
        self.provider = provider
        self.rootRoute = rootRoute
        self.registry = registry
        self.navigation = navigation
        self.migrations = migrations
        self.policy = policy
        self.validator = validator
        self.currentSchemaVersion = max(1, currentSchemaVersion)
    }

    /// Captures and persists this scene's current state. Ownership: returned bytes are caller-owned.
    /// Isolation: MainActor. Errors: encoding/storage failures throw. Cancellation: propagates.
    public func capture() async throws -> Data {
        let state = provider()
        let envelope = Envelope(
            sceneKey: sceneID.rawValue,
            schemaVersion: currentSchemaVersion,
            state: NavigationState(
                selectedTab: state.selectedTab,
                stacks: state.stacks,
                presentedRoute: state.presentedRoute,
                schemaVersion: currentSchemaVersion))
        let data: Data
        do { data = try JSONEncoder().encode(envelope) } catch {
            throw NavigationRestorationError.corruptEnvelope
        }
        try await store.set(storageKeyForScene, value: envelope)
        return data
    }

    /// Restores a supplied envelope without constructing controllers in the parser.
    /// Ownership: restored controllers are owned by navigation. Isolation: MainActor. Errors: policy handles unknown routes; cancellation throws.
    /// Restores a supplied envelope without constructing controllers in the parser. Ownership: restored controllers are owned by navigation. Isolation: MainActor. Errors: policy handles corruption and factory failures. Cancellation: propagates.
    public func restore(from data: Data) async throws -> NavigationRestoreResult {
        guard !Task.isCancelled else { throw CancellationError() }
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) } catch {
            return try await fallback("corrupt envelope")
        }
        guard envelope.sceneKey == sceneID.rawValue, !sceneID.rawValue.isEmpty else {
            return try await fallback("scene mismatch")
        }
        do {
            let migrated = try migrate(envelope.state, from: envelope.schemaVersion)
            return try await apply(migrated)
        } catch is CancellationError { throw CancellationError() } catch {
            return try await fallback(String(describing: error))
        }
    }

    /// Loads the scene envelope from storage and restores it, falling back to root when no value exists.
    /// Ownership: storage bytes are decoded and consumed. Isolation: MainActor. Errors: storage errors throw; invalid data follows policy.
    /// Loads and restores this scene's persisted envelope. Ownership: decoded state is consumed by navigation. Isolation: MainActor. Errors: storage failures throw; invalid data follows policy. Cancellation: propagates.
    public func restoreStored() async throws -> NavigationRestoreResult {
        guard let envelope = try await store.get(storageKeyForScene, as: Envelope.self) else {
            return try await fallback("no saved state")
        }
        let data = try JSONEncoder().encode(envelope)
        return try await restore(from: data)
    }

    private var storageKeyForScene: String { "\(storageKey).\(sceneID.rawValue)" }

    private func migrate(
        _ initial: NavigationState<R>,
        from version: Int
    ) throws -> NavigationState<R> {
        var state = initial
        var version = version
        guard version <= currentSchemaVersion else {
            throw NavigationRestorationError.unsupportedSchema(version)
        }
        while version < currentSchemaVersion {
            guard
                let migration = migrations.first(where: {
                    $0.fromVersion == version && $0.toVersion > version
                        && $0.toVersion <= currentSchemaVersion
                })
            else {
                throw NavigationRestorationError.missingMigration(
                    from: version, to: currentSchemaVersion)
            }
            state = try migration.apply(state)
            version = migration.toVersion
        }
        return NavigationState(
            selectedTab: state.selectedTab,
            stacks: state.stacks,
            presentedRoute: state.presentedRoute,
            schemaVersion: currentSchemaVersion)
    }

    private func apply(_ state: NavigationState<R>) async throws -> NavigationRestoreResult {
        let presented = state.presentedRoute.map { [$0] } ?? []
        let routes = state.stacks.flatMap(\.routes) + presented
        let validRoutes = routes.filter(validator)
        guard !validRoutes.isEmpty else { return try await fallback("no valid routes") }
        if policy == .fallbackToRoot, validRoutes.count != routes.count {
            return try await fallback("unknown route")
        }
        guard validRoutes.count == routes.count || policy == .skipUnknownRoutes else {
            return try await fallback("unknown route")
        }
        resetNavigation()
        var count = 0
        for route in validRoutes {
            guard !Task.isCancelled else { throw CancellationError() }
            do {
                let controller = try await registry.make(for: route)
                guard navigation.push(controller, animated: false) else {
                    throw NavigationRestorationError.factoryFailed("navigation rejected route")
                }
                count += 1
            } catch is CancellationError { throw CancellationError() } catch {
                return try await fallback("factory failed")
            }
        }
        return .restored(routeCount: count)
    }

    private func fallback(_ reason: String) async throws -> NavigationRestoreResult {
        resetNavigation()
        guard !Task.isCancelled else { throw CancellationError() }
        let controller = try await registry.make(for: rootRoute)
        guard navigation.push(controller, animated: false) else {
            throw NavigationRestorationError.missingRoot
        }
        return .rootFallback(reason: reason)
    }

    private func resetNavigation() {
        while navigation.pop(animated: false) != nil {}
    }
}
