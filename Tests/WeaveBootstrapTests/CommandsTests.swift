import Testing
import Weave

@MainActor
private final class CommandCounter {
    var count = 0
}

@Test
@MainActor
func disabledCommandsDoNotExecuteAndRegistrationDisposalRemovesThem() async {
    let registry = CommandRegistry()
    let counter = CommandCounter()
    let id: CommandID = "save"
    let registration = registry.register(
        CommandDefinition(id: id, title: LocalizedText(key: "save", fallback: "Save")),
        enabled: false
    ) { counter.count += 1 }
    #expect(await registry.execute(id) == .disabled)
    #expect(counter.count == 0)
    registration.dispose()
    #expect(await registry.execute(id) == .unavailable)
}

@Test
@MainActor
func shortcutUsesActiveSceneAndControllerScopeWinsConflict() async {
    let registry = CommandRegistry()
    let counter = CommandCounter()
    let shortcut = CommandShortcut(key: "k", modifiers: [.command])
    _ = registry.register(
        CommandDefinition(
            id: "global", title: LocalizedText(key: "global", fallback: "Global"),
            scope: .application, shortcut: shortcut)
    ) { counter.count += 1 }
    _ = registry.register(
        CommandDefinition(
            id: "scene", title: LocalizedText(key: "scene", fallback: "Scene"),
            scope: .scene(SceneID("main")), shortcut: shortcut)
    ) { counter.count += 10 }
    _ = registry.register(
        CommandDefinition(
            id: "controller", title: LocalizedText(key: "controller", fallback: "Controller"),
            scope: .controller("editor"), shortcut: shortcut)
    ) { counter.count += 100 }

    registry.setFocus(scene: SceneID("main"), controller: "editor")
    #expect(await registry.execute(shortcut) == .executed)
    #expect(counter.count == 100)
    registry.setFocus(scene: SceneID("other"), controller: nil)
    #expect(await registry.execute(shortcut) == .executed)
    #expect(counter.count == 101)
}

@Test
@MainActor
func sceneCommandDoesNotRunWithoutMatchingFocusAndEnablementCanChange() async {
    let registry = CommandRegistry()
    let counter = CommandCounter()
    let id: CommandID = "refresh"
    _ = registry.register(
        CommandDefinition(
            id: id, title: LocalizedText(key: "refresh", fallback: "Refresh"),
            scope: .scene(SceneID("main")), shortcut: nil)
    ) { counter.count += 1 }
    #expect(await registry.execute(id) == .noFocusedScope)
    registry.setFocus(scene: SceneID("main"))
    registry.setEnabled(false, for: id)
    #expect(await registry.execute(id) == .disabled)
    registry.setEnabled(true, for: id)
    #expect(await registry.execute(id) == .executed)
    #expect(counter.count == 1)
}
