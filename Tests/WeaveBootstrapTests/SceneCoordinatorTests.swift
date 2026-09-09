import Foundation
import Testing
import Weave

private enum SceneRoute: String, Route {
    case home
    case detail
    var path: String { rawValue }
}

private struct SceneFactory: ScreenFactory {
    func make(route: SceneRoute, environment: EnvironmentValues) async throws -> any AnyController {
        Controller<Node, Never, SceneRoute>(node: Node())
    }
}

@Test
@MainActor
func sceneCoordinatorKeepsWindowsAndNavigationIndependent() async throws {
    let registry = ScreenRegistry()
    registry.register(SceneFactory(), for: SceneRoute.self)
    let coordinator = SceneCoordinator(idGenerator: {
        SceneID("generated-\(UUID().uuidString)")
    })
    let first = try await coordinator.open(
        SceneRequest<SceneRoute>(route: .home, preferredSceneID: SceneID("one"), policy: .newScene)
        { id, _ in
            let flow = NavigationCoordinator<SceneRoute>(registry: registry)
            _ = flow.start()
            let scene = WindowScene(id: id, coordinator: flow)
            _ = scene.add(Window(environment: scene.environment))
            return scene
        })
    let second = try await coordinator.open(
        SceneRequest<SceneRoute>(
            route: .detail, preferredSceneID: SceneID("two"), policy: .newScene
        ) { id, _ in
            let flow = NavigationCoordinator<SceneRoute>(registry: registry)
            _ = flow.start()
            let scene = WindowScene(id: id, coordinator: flow)
            _ = scene.add(Window(environment: scene.environment))
            return scene
        })

    #expect(first == SceneID("one"))
    #expect(second == SceneID("two"))
    #expect(coordinator.sceneValues.count == 2)
    #expect(
        coordinator.scene(for: first)?.environment !== coordinator.scene(for: second)?.environment)
    #expect(coordinator.scene(for: first)?.coordinator?.isRunning == true)
    try await coordinator.close(first)
    #expect(coordinator.scene(for: first) == nil)
    #expect(coordinator.scene(for: second)?.coordinator?.isRunning == true)
}

@Test
@MainActor
func deepLinkStyleRequestReusesExistingSceneBeforeCreatingAnother() async throws {
    let coordinator = SceneCoordinator(idGenerator: { SceneID("new") })
    let scene = WindowScene(id: SceneID("main"))
    _ = scene.add(Window(environment: scene.environment))
    let request = SceneRequest<SceneRoute>(
        route: SceneRoute.detail,
        preferredSceneID: SceneID("main"),
        policy: .reuseOrCreate
    ) { id, _ in WindowScene(id: id) }

    let first = try await coordinator.open(
        SceneRequest<SceneRoute>(route: .home, preferredSceneID: SceneID("main"), policy: .newScene)
        { id, _ in
            let created = WindowScene(id: id)
            _ = created.add(Window(environment: created.environment))
            return created
        })
    #expect(first == SceneID("main"))
    _ = scene
    let reused = try await coordinator.open(request)
    #expect(reused == first)
    #expect(coordinator.sceneValues.count == 1)
}

@Test
@MainActor
func unavailableMultiWindowReusesExistingOrReportsCapabilityError() async throws {
    let coordinator = SceneCoordinator(availability: .unavailable, idGenerator: { SceneID("new") })
    let request = SceneRequest<SceneRoute>(route: SceneRoute.home, policy: .newScene) { id, _ in
        WindowScene(id: id)
    }
    do {
        _ = try await coordinator.open(request)
        Issue.record("expected multi-window capability error")
    } catch let error as SceneCoordinatorError {
        #expect(error == .multiWindowUnavailable)
    }
}
