import Testing
import Weave

private struct FlowRoute: Route {
    let path: String
    init(_ path: String) { self.path = path }
}

private struct FlowFactory: ScreenFactory {
    func make(route: FlowRoute, environment: EnvironmentValues) async throws -> any AnyController {
        Controller<Node, Never, FlowRoute>(node: Node())
    }
}

@MainActor
private final class RouteEmittingController: Controller<Node, Never, FlowRoute> {}

private struct RouteEmittingFactory: ScreenFactory {
    func make(route: FlowRoute, environment: EnvironmentValues) async throws -> any AnyController {
        RouteEmittingController(node: Node())
    }
}

private func isDropped<T>(_ result: AsyncStream<T>.Continuation.YieldResult) -> Bool {
    if case .dropped = result { return true }
    return false
}

@Test
@MainActor
func screenRegistryBuildsTypedControllerAndReportsMissingFactory() async {
    let registry = ScreenRegistry()
    registry.register(FlowFactory(), for: FlowRoute.self)
    let controller = try? await registry.make(for: FlowRoute("home"))
    #expect(controller != nil)
    let missing = try? await ScreenRegistry().make(for: FlowRoute("missing"))
    #expect(missing == nil)
}

@Test
@MainActor
func coordinatorStartStopAndChildWiringAreIdempotent() async {
    let registry = ScreenRegistry()
    registry.register(FlowFactory(), for: FlowRoute.self)
    let parent = NavigationCoordinator<FlowRoute>(registry: registry)
    let child = NavigationCoordinator<FlowRoute>(registry: registry)
    #expect(parent.start())
    #expect(!parent.start())
    #expect(parent.wire(child))
    #expect(!parent.wire(child))
    await Task.yield()
    #expect(!isDropped(child.emit(FlowRoute("detail"))))
    for _ in 0..<8 where parent.navigation.stack.isEmpty { await Task.yield() }
    #expect(parent.navigation.stack.count == 1)
    parent.stop()
    #expect(!parent.isRunning)
    #expect(!child.isRunning)
    #expect(isDropped(child.emit(FlowRoute("ignored"))))
}

@Test
@MainActor
func navigationRouterAndFactoryFailureKeepExistingStack() async {
    let registry = ScreenRegistry()
    registry.register(FlowFactory(), for: FlowRoute.self)
    let coordinator = NavigationCoordinator<FlowRoute>(registry: registry)
    #expect(coordinator.start())
    #expect(await coordinator.handle(FlowRoute("root")))
    #expect(coordinator.navigation.stack.count == 1)

    let missingRegistry = ScreenRegistry()
    let failing = NavigationCoordinator<FlowRoute>(registry: missingRegistry)
    #expect(failing.start())
    let handled = await failing.handle(FlowRoute("missing"))
    #expect(!handled)
    #expect(failing.navigation.stack.isEmpty)

    let router = NavigationRouter(coordinator: coordinator)
    router.dismiss(animated: false)
    #expect(coordinator.navigation.stack.isEmpty)
}

@Test
@MainActor
func coordinatorAutomaticallyHandlesControllerRouteOutputs() async {
    let registry = ScreenRegistry()
    registry.register(RouteEmittingFactory(), for: FlowRoute.self)
    let coordinator = NavigationCoordinator<FlowRoute>(registry: registry)
    #expect(coordinator.start())
    #expect(await coordinator.handle(FlowRoute("root")))
    guard let controller = coordinator.navigation.stack.last as? RouteEmittingController else {
        Issue.record("Expected the registered route-emitting controller")
        return
    }

    _ = controller.navigate(to: FlowRoute("detail"), animated: false)
    for _ in 0..<32 where coordinator.navigation.stack.count < 2 { await Task.yield() }
    #expect(coordinator.navigation.stack.count == 2)
}
