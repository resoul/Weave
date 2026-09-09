import Foundation

public import Flux

/// Policy for resolving a route to an existing or new scene. Ownership: immutable value. Isolation: none. Errors: unavailable capability is reported by coordinator. Cancellation: caller-owned.
public enum SceneOpenPolicy: Sendable, Hashable {
    case reuseExisting
    case newScene
    case reuseOrCreate
}

/// Multi-window capability state. Ownership: immutable value. Isolation: none. Errors: unavailable means only one scene is supported. Cancellation: not applicable.
public enum SceneAvailability: Sendable, Hashable {
    case available
    case unavailable
}

/// Typed request used by deep links and route outputs to open a scene. Ownership: request owns route and factory closure.
/// Isolation: MainActor factory. Errors: factory failures propagate. Cancellation: caller cancellation cancels creation.
public struct SceneRequest<R: Route>: Sendable {
    public let route: R
    public let preferredSceneID: SceneID?
    public let policy: SceneOpenPolicy
    public let makeScene: @MainActor @Sendable (SceneID, R) async throws -> WindowScene

    /// Creates a scene request. Ownership: route and factory are copied/retained. Isolation: factory runs on MainActor. Errors: factory errors propagate. Cancellation: caller-owned.
    public init(
        route: R,
        preferredSceneID: SceneID? = nil,
        policy: SceneOpenPolicy = .reuseOrCreate,
        makeScene: @escaping @MainActor @Sendable (SceneID, R) async throws -> WindowScene
    ) {
        self.route = route
        self.preferredSceneID = preferredSceneID
        self.policy = policy
        self.makeScene = makeScene
    }
}

/// Immutable scene registry snapshot. Ownership: IDs are copied. Isolation: none. Errors: none. Cancellation: not applicable.
public struct SceneRegistrySnapshot: Sendable, Hashable {
    public let sceneIDs: [SceneID]

    /// Creates a registry snapshot. Ownership: IDs are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(sceneIDs: [SceneID]) { self.sceneIDs = sceneIDs }
}

/// Scene lifecycle failures. Ownership: immutable error. Isolation: none. Errors: this is the typed scene error surface. Cancellation: cancellation remains separate.
public enum SceneCoordinatorError: Error, Sendable, Hashable {
    case multiWindowUnavailable
    case sceneNotFound(SceneID)
    case duplicateScene(SceneID)
    case creationCancelled(SceneID)
    case sceneFactoryReturnedWrongID(expected: SceneID, actual: SceneID)
}

/// Main-actor owner of independent scene windows and their lifecycle tasks.
/// Ownership: coordinator owns registered scenes and pending creation IDs. Isolation: MainActor.
/// Errors: typed open/close failures. Cancellation: close cancels only that scene's creation/work.
@MainActor
public final class SceneCoordinator {
    private var sceneStorage: [SceneID: WindowScene] = [:]
    private var pending: Set<SceneID> = []
    private let snapshotPipe = Pipe<SceneRegistrySnapshot>(bufferingPolicy: .bufferingNewest(1))
    private let idGenerator: @MainActor @Sendable () -> SceneID
    private let availability: SceneAvailability

    /// Creates an empty scene registry. Ownership: coordinator owns the registry and generator. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        availability: SceneAvailability = .available,
        idGenerator: @escaping @MainActor @Sendable () -> SceneID = {
            SceneID(UUID().uuidString)
        }
    ) {
        self.availability = availability
        self.idGenerator = idGenerator
    }

    /// Observable registry snapshot. Ownership: subscriber owns the stream. Isolation: MainActor publication. Errors: bounded updates coalesce. Cancellation: subscription-owned.
    public var scenes: Flux<SceneRegistrySnapshot> { snapshotPipe.flux }

    /// Current scene objects for adapter inspection. Ownership: returned array is a borrowed snapshot. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var sceneValues: [WindowScene] { Array(sceneStorage.values) }

    /// Opens a route in an existing scene or creates an isolated new scene according to policy.
    /// Ownership: registry retains the resulting scene. Isolation: MainActor. Errors: typed scene errors and factory errors. Cancellation: caller cancellation cancels creation.
    public func open<R: Route>(_ request: SceneRequest<R>) async throws -> SceneID {
        if let preferred = request.preferredSceneID,
            let existing = sceneStorage[preferred], request.policy != .newScene
        {
            existing.router.navigate(to: request.route, animated: false)
            return preferred
        }
        if request.policy == .reuseExisting,
            let first = sceneStorage.keys.sorted(by: { $0.rawValue < $1.rawValue }).first,
            let existing = sceneStorage[first]
        {
            existing.router.navigate(to: request.route, animated: false)
            return first
        }
        guard availability == .available else {
            if request.policy == .reuseOrCreate,
                let first = sceneStorage.keys.sorted(by: { $0.rawValue < $1.rawValue }).first,
                let existing = sceneStorage[first]
            {
                existing.router.navigate(to: request.route, animated: false)
                return first
            }
            throw SceneCoordinatorError.multiWindowUnavailable
        }
        let id = request.preferredSceneID ?? idGenerator()
        guard sceneStorage[id] == nil, pending.insert(id).inserted else {
            throw SceneCoordinatorError.duplicateScene(id)
        }
        defer { pending.remove(id) }
        guard !Task.isCancelled else { throw CancellationError() }
        let scene: WindowScene
        do { scene = try await request.makeScene(id, request.route) } catch is CancellationError {
            throw CancellationError()
        } catch { throw error }
        guard !Task.isCancelled, pending.contains(id) else {
            scene.close()
            throw SceneCoordinatorError.creationCancelled(id)
        }
        guard scene.id == id else {
            scene.close()
            throw SceneCoordinatorError.sceneFactoryReturnedWrongID(expected: id, actual: scene.id)
        }
        sceneStorage[id] = scene
        if let window = scene.windows.first { _ = window.present() }
        publish()
        return id
    }

    /// Closes one scene and releases only its coordinator/router/environment work. Ownership: registry releases the scene.
    /// Isolation: MainActor. Errors: unknown IDs throw. Cancellation: close is terminal for that scene.
    public func close(_ id: SceneID) async throws {
        if pending.remove(id) != nil { throw SceneCoordinatorError.creationCancelled(id) }
        guard let scene = sceneStorage.removeValue(forKey: id) else {
            throw SceneCoordinatorError.sceneNotFound(id)
        }
        scene.close()
        publish()
    }

    /// Returns one scene by stable identity. Ownership: returned scene is borrowed. Isolation: MainActor. Errors: unknown IDs return nil. Cancellation: not applicable.
    public func scene(for id: SceneID) -> WindowScene? { sceneStorage[id] }

    private func publish() {
        snapshotPipe.send(
            SceneRegistrySnapshot(sceneIDs: sceneStorage.keys.sorted { $0.rawValue < $1.rawValue }))
    }
}
