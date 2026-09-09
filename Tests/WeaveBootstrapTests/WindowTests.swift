import Testing
import Weave

@Test
@MainActor
func windowsIsolateRootEnvironmentAndActivation() {
    let firstScope = EnvironmentScope()
    let secondScope = EnvironmentScope()
    let first = Controller<Node, Never, Never>(node: Node(), environment: firstScope)
    let second = Controller<Node, Never, Never>(node: Node(), environment: secondScope)
    let firstWindow = Window(environment: firstScope, rootController: first)
    let secondWindow = Window(environment: secondScope, rootController: second)

    #expect(firstWindow.present())
    #expect(secondWindow.present())
    #expect(firstWindow.activationState == .active)
    #expect(secondWindow.activationState == .active)
    #expect(firstWindow.environment.snapshot.revision != secondWindow.environment.snapshot.revision)
    firstWindow.close()
    #expect(first.isDisposed)
    #expect(!second.isDisposed)
}

@Test
@MainActor
func windowRootReplacementDisposesPreviousExactlyOnceAndSceneCloseClosesWindows() {
    let scene = WindowScene(id: "main")
    let window = Window()
    #expect(scene.add(window))
    let first = Controller<Node, Never, Never>(node: Node())
    let second = Controller<Node, Never, Never>(node: Node())
    #expect(window.setRootController(first))
    #expect(window.setRootController(second))
    #expect(first.isDisposed)
    #expect(window.present())
    scene.close()
    #expect(second.isDisposed)
    #expect(scene.windows.isEmpty)
    #expect(!window.present())
}
