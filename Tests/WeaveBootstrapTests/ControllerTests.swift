import Testing
import Weave

private enum TestAction: Action, Equatable {
    case refresh
}

private enum TestRoute: String, Route {
    case detail
    var path: String { rawValue }
}

private func deliverable<T>(_ result: AsyncStream<T>.Continuation.YieldResult) -> Bool {
    if case .terminated = result { return false }
    return true
}

@MainActor
private final class RecordingController: Controller<Node, TestAction, TestRoute> {
    var composeCount = 0
    var connectCount = 0
    var disposeCount = 0

    override func compose() { composeCount += 1 }
    override func connect(_ connections: ControllerConnections<TestAction, TestRoute>) {
        connectCount += 1
    }
    override func disposed() { disposeCount += 1 }
}

@Test
@MainActor
func controllerOwnsTypedNodeOutputsAndLifecycleIsIdempotent() {
    let controller = RecordingController(node: Node())
    #expect(controller.connect())
    #expect(!controller.connect())
    #expect(controller.composeCount == 1)
    #expect(controller.connectCount == 1)
    #expect(controller.activate())
    #expect(!controller.activate())
    #expect(deliverable(controller.dispatch(.refresh)))
    #expect(deliverable(controller.navigate(to: .detail)))
    controller.dispose()
    controller.dispose()
    #expect(controller.disposeCount == 1)
    #expect(controller.isDisposed)
    #expect(!controller.activate())
}

@Test
@MainActor
func controllerAliasesCompileWithNeverContracts() {
    let screen: Screen<Node> = Screen(node: Node())
    let flow: FlowController<Node, TestRoute> = FlowController(node: Node())
    let action: ActionController<Node, TestAction> = ActionController(node: Node())
    #expect(screen.connect())
    #expect(flow.connect())
    #expect(action.connect())
    screen.dispose()
    flow.dispose()
    action.dispose()
}
