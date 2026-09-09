import Foundation
import Testing
import Weave

private struct TestApplication: Application {
    let content: ApplicationScenes

    init() {
        content = ApplicationScenes(scenes: [])
    }

    init(content: ApplicationScenes) {
        self.content = content
    }

    @MainActor
    func compose() -> ApplicationScenes { content }
}

private struct StartupFailure: Error, Sendable {}

@Test
@MainActor
func appRuntimeSeparatesCompositionConstructionAndStart() async throws {
    var composed = false
    let application = TestApplication(
        content: ApplicationScenes(scenes: [
            SceneDescription(id: SceneID("main")) {
                WindowScene(id: SceneID("main"))
            }
        ]))
    let runtime = AppRuntime(application: application)
    #expect(!runtime.isStarted)
    #expect(runtime.scenes.isEmpty)
    let report = try await runtime.start()
    composed = true
    #expect(composed)
    #expect(runtime.isStarted)
    #expect(report.scenes.count == 1)
    #expect(report.scenes[0].windows.isEmpty)
    runtime.stop()
    #expect(!runtime.isStarted)
    #expect(runtime.scenes.isEmpty)
}

@Test
@MainActor
func appRuntimeContinuesAfterTypedSceneFailureWhenPolicyAllows() async throws {
    let application = TestApplication(
        content: ApplicationScenes(scenes: [
            SceneDescription(id: SceneID("broken")) { throw StartupFailure() },
            SceneDescription(id: SceneID("main")) { WindowScene(id: SceneID("main")) },
        ]))
    let runtime = AppRuntime(application: application, failurePolicy: .continueLaunching)
    let report = try await runtime.start()
    #expect(report.scenes.count == 1)
    #expect(report.failures.count == 1)
    #expect(runtime.scenes[SceneID("main")] != nil)
    runtime.stop()
}

@Test
@MainActor
func appRuntimeRejectsDuplicateSceneBeforeConstruction() async throws {
    let application = TestApplication(
        content: ApplicationScenes(scenes: [
            SceneDescription(id: SceneID("main")) { WindowScene(id: SceneID("main")) },
            SceneDescription(id: SceneID("main")) { WindowScene(id: SceneID("main")) },
        ]))
    let runtime = AppRuntime(application: application)
    await #expect(throws: ApplicationRuntimeError.duplicateScene(SceneID("main"))) {
        try await runtime.start()
    }
    #expect(!runtime.isStarted)
    #expect(runtime.scenes.isEmpty)
}
