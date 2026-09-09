import Foundation
import Storage
import Testing
import Weave

private enum RestoreRoute: String, Route, Codable {
    case root
    case detail
    case settings
    var path: String { rawValue }
}

private struct RestoreFactory: ScreenFactory {
    func make(
        route: RestoreRoute,
        environment: EnvironmentValues
    ) async throws -> any AnyController {
        Controller<Node, Never, RestoreRoute>(node: Node())
    }
}

private actor MemoryRestoreStore: Store {
    private var values: [String: Data] = [:]
    nonisolated let changes: AsyncStream<StoreChange>
    private let continuation: AsyncStream<StoreChange>.Continuation

    init() {
        let pair = AsyncStream<StoreChange>.makeStream(bufferingPolicy: .bufferingNewest(32))
        changes = pair.stream
        continuation = pair.continuation
    }

    func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T? {
        guard let data = values[key] else { return nil }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func set<T: Codable & Sendable>(_ key: String, value: T) async throws {
        values[key] = try JSONEncoder().encode(value)
        continuation.yield(StoreChange(key: key, operation: .set))
    }

    func remove(_ key: String) async throws {
        values.removeValue(forKey: key)
        continuation.yield(StoreChange(key: key, operation: .remove))
    }

    func removeAll() async throws {
        values.removeAll()
        continuation.yield(StoreChange(key: nil, operation: .removeAll))
    }
}

@Test
@MainActor
func navigationRestorationRoundTripsSceneStateAndUsesRegistry() async throws {
    let store = MemoryRestoreStore()
    let registry = ScreenRegistry()
    registry.register(RestoreFactory(), for: RestoreRoute.self)
    let navigation = NavigationController<RestoreRoute>()
    let state = NavigationState<RestoreRoute>(
        selectedTab: "main",
        stacks: [NavigationStackState<RestoreRoute>(identifier: "main", routes: [.root, .detail])],
        presentedRoute: .settings,
        schemaVersion: 1)
    let restorer = NavigationRestorer(
        sceneID: SceneID("scene-a"),
        store: store,
        currentSchemaVersion: 1,
        provider: { state },
        rootRoute: .root,
        registry: registry,
        navigation: navigation)

    let data = try await restorer.capture()
    #expect(!data.isEmpty)
    let result = try await restorer.restore(from: data)
    #expect(result == .restored(routeCount: 3))
    #expect(navigation.stack.count == 3)
}

@Test
@MainActor
func navigationRestorationMigratesOldSchemaAndSeparatesScenes() async throws {
    let registry = ScreenRegistry()
    registry.register(RestoreFactory(), for: RestoreRoute.self)
    let store = MemoryRestoreStore()
    let oldState = NavigationState<RestoreRoute>(
        stacks: [NavigationStackState<RestoreRoute>(identifier: "main", routes: [.root, .detail])],
        schemaVersion: 1)
    let oldRestorer = NavigationRestorer(
        sceneID: SceneID("scene-old"), store: store, currentSchemaVersion: 1,
        provider: { oldState }, rootRoute: .root, registry: registry,
        navigation: NavigationController<RestoreRoute>())
    let oldData = try await oldRestorer.capture()
    let navigation = NavigationController<RestoreRoute>()
    let restorer = NavigationRestorer<RestoreRoute>(
        sceneID: SceneID("scene-old"), store: store, currentSchemaVersion: 2,
        provider: { oldState }, rootRoute: .root, registry: registry, navigation: navigation,
        migrations: [
            NavigationStateMigration(fromVersion: 1, toVersion: 2) { value in
                NavigationState(
                    selectedTab: value.selectedTab, stacks: value.stacks,
                    presentedRoute: .settings, schemaVersion: 2)
            }
        ])
    let migrated = try await restorer.restore(from: oldData)
    #expect(migrated == .restored(routeCount: 3))

    let otherScene = NavigationRestorer<RestoreRoute>(
        sceneID: SceneID("scene-new"), store: store, currentSchemaVersion: 2,
        provider: { oldState }, rootRoute: .root, registry: registry,
        navigation: NavigationController<RestoreRoute>())
    let separated = try await otherScene.restore(from: oldData)
    #expect(separated == .rootFallback(reason: "scene mismatch"))
}

@Test
@MainActor
func corruptedNavigationEnvelopeFallsBackToRootAndCancellationIsTyped() async throws {
    let registry = ScreenRegistry()
    registry.register(RestoreFactory(), for: RestoreRoute.self)
    let navigation = NavigationController<RestoreRoute>()
    let restorer = NavigationRestorer<RestoreRoute>(
        sceneID: SceneID("scene"), store: MemoryRestoreStore(), currentSchemaVersion: 1,
        provider: { NavigationState<RestoreRoute>(stacks: []) }, rootRoute: .root,
        registry: registry, navigation: navigation)

    let fallback = try await restorer.restore(from: Data("bad".utf8))
    #expect(fallback == .rootFallback(reason: "corrupt envelope"))
    #expect(navigation.stack.count == 1)
}
