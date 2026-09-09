import Foundation
import Testing
import Weave
import Flux

private enum ScreenAction: Action, Equatable {
    case refresh
    case retry
}

private actor TestViewModel: ViewModel {
    typealias State = ScreenState<Int>
    typealias Intent = ScreenAction
    typealias Output = String

    nonisolated let state = CurrentValueDistinct<State>(.loading)
    nonisolated let outputs = Flux<String>.empty()
    private var received: [ScreenAction] = []

    func send(_ intent: ScreenAction) async {
        received.append(intent)
        await state.set(.content(received.count))
    }

    func receivedCount() -> Int { received.count }

    func waitForCount(_ expected: Int) async -> Bool {
        for _ in 0..<2000 {
            if received.count >= expected { return true }
            await Task.yield()
        }
        return received.count >= expected
    }
}

@Test
@MainActor
func controllerConnectionsForwardActionsAndRenderViewModelState() async {
    let actions = ActionPipe<ScreenAction>()
    let routes = RoutePipe<Never>()
    let scope = ConnectionScope()
    let connections = ControllerConnections(actions: actions, routes: routes, scope: scope)
    let viewModel = TestViewModel()
    #expect(connections.forward(actions, to: viewModel))
    let renderSubscription = connections.render(viewModel.state) { _ in }
    _ = actions.send(.refresh)
    _ = actions.send(.retry)
    #expect(await viewModel.waitForCount(2))
    #expect(await viewModel.state.value == .content(2))
    renderSubscription.cancel()
    scope.cancelAll()
    #expect(scope.isCancelled)
}

@Test
@MainActor
func controllerConnectionsDisposeCancelsIntentForwarding() async {
    let actions = ActionPipe<ScreenAction>()
    let routes = RoutePipe<Never>()
    let scope = ConnectionScope()
    let connections = ControllerConnections(actions: actions, routes: routes, scope: scope)
    let viewModel = TestViewModel()

    #expect(connections.forward(actions, to: viewModel))
    scope.cancelAll()
    _ = actions.send(.refresh)
    await Task.yield()
    #expect(await viewModel.receivedCount() == 0)
}

@Test
@MainActor
func controllerConnectionsSubscribeBeforeReturningFromForward() async {
    let actions = ActionPipe<ScreenAction>()
    let routes = RoutePipe<Never>()
    let scope = ConnectionScope()
    let connections = ControllerConnections(actions: actions, routes: routes, scope: scope)
    let viewModel = TestViewModel()

    #expect(connections.forward(actions, to: viewModel))
    _ = actions.send(.refresh)
    #expect(await viewModel.waitForCount(1))
    scope.cancelAll()
}

@Test
@MainActor
func controllerIntentForwardingSurvivesTemporaryDeactivation() async {
    let actions = ActionPipe<ScreenAction>()
    let routes = RoutePipe<Never>()
    let scope = ConnectionScope()
    let connections = ControllerConnections(actions: actions, routes: routes, scope: scope)
    let viewModel = TestViewModel()

    #expect(connections.forward(actions, to: viewModel))
    scope.cancelEffectsOnDeactivate()
    _ = actions.send(.refresh)
    #expect(await viewModel.waitForCount(1))
    scope.cancelAll()
}
