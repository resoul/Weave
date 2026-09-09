import Foundation
import WeaveUI

/// A platform-neutral description of one application scene.
/// Ownership: the description retains only its Sendable factory. Isolation: factory execution is MainActor. Errors: factory errors are reported by AppRuntime. Cancellation: caller cancellation propagates to scene construction.
public struct SceneDescription: Sendable {
    public let id: SceneID
    public let syncFactory: (@MainActor @Sendable () throws -> WindowScene)?
    private let factory: @MainActor @Sendable () async throws -> WindowScene

    /// Creates a synchronous scene description.
    /// Ownership: the description retains the factory. Isolation: MainActor when evaluated. Errors: factory errors propagate. Cancellation: caller cancellation propagates.
    public init(
        id: SceneID,
        syncFactory: @escaping @MainActor @Sendable () throws -> WindowScene
    ) {
        self.id = id
        self.syncFactory = syncFactory
        self.factory = { try syncFactory() }
    }

    /// Creates a scene description without constructing platform objects.
    /// Ownership: the description retains the factory. Isolation: MainActor when started. Errors: factory errors propagate. Cancellation: construction observes caller cancellation.
    public init(
        id: SceneID,
        factory: @escaping @MainActor @Sendable () async throws -> WindowScene
    ) {
        self.id = id
        self.syncFactory = nil
        self.factory = factory
    }

    @MainActor
    fileprivate func make() async throws -> WindowScene { try await factory() }

    @MainActor
    fileprivate func makeSync() throws -> WindowScene {
        if let sync = syncFactory {
            return try sync()
        }
        throw ApplicationRuntimeError.sceneFailed(
            id, "Asynchronous scene description cannot be evaluated synchronously"
        )
    }
}

/// Creates a scene description for use in an ApplicationBuilder.
/// Ownership: the returned value owns its factory. Isolation: factory runs on MainActor. Errors: factory errors are reported at startup. Cancellation: startup cancellation propagates.
@MainActor
public func Scene(
    _ id: String,
    factory: @escaping @MainActor @Sendable () throws -> WindowScene
) -> SceneDescription {
    SceneDescription(id: SceneID(id), syncFactory: factory)
}

/// Creates an asynchronous scene description for use in an ApplicationBuilder.
/// Ownership: the returned value owns its factory. Isolation: factory runs on MainActor. Errors: factory errors are reported at startup. Cancellation: startup cancellation propagates.
@MainActor
public func Scene(
    _ id: String,
    factory: @escaping @MainActor @Sendable () async throws -> WindowScene
) -> SceneDescription {
    SceneDescription(id: SceneID(id), factory: factory)
}

/// A result-builder-compatible collection of scene descriptions.
/// Ownership: the value owns immutable scene descriptions. Isolation: none until runtime start. Errors: duplicate IDs are reported by AppRuntime. Cancellation: scene factories are caller-owned.
public protocol ApplicationContent: Sendable {
    var scenes: [SceneDescription] { get }
}

/// Default content produced by ApplicationBuilder.
/// Ownership: the value owns its scene descriptions. Isolation: none. Errors: invalid duplicate IDs are deferred to AppRuntime. Cancellation: factories are started only by runtime.
public struct ApplicationScenes: ApplicationContent {
    public let scenes: [SceneDescription]

    /// Creates application content from scene descriptions.
    /// Ownership: the array is copied. Isolation: none. Errors: duplicate IDs are validated at startup. Cancellation: no work starts.
    public init(scenes: [SceneDescription]) { self.scenes = scenes }
}

/// Builds Application scene content without starting runtime effects.
/// Ownership: builder methods copy immutable descriptions. Isolation: none. Errors: duplicate
/// scene IDs are validated by AppRuntime. Cancellation: builder evaluation starts no effects.
@resultBuilder
public enum ApplicationBuilder {
    /// Accepts an already assembled scene collection.
    /// Ownership: descriptions are copied. Isolation: none. Errors: none. Cancellation: none.
    public static func buildExpression(_ component: ApplicationScenes) -> ApplicationScenes {
        component
    }

    /// Accepts one scene expression.
    /// Ownership: the description is copied. Isolation: none. Errors: none. Cancellation: none.
    public static func buildExpression(_ component: SceneDescription) -> ApplicationScenes {
        ApplicationScenes(scenes: [component])
    }

    /// Combines scene expressions in source order.
    /// Ownership: descriptions are copied into the result. Isolation: none. Errors: duplicate IDs are deferred to startup. Cancellation: none.
    public static func buildBlock(_ components: ApplicationScenes...) -> ApplicationScenes {
        ApplicationScenes(scenes: components.flatMap(\.scenes))
    }

    /// Supports conditional scene content.
    /// Ownership: descriptions are copied. Isolation: none. Errors: none. Cancellation: none.
    public static func buildOptional(_ component: ApplicationScenes?) -> ApplicationScenes {
        component ?? ApplicationScenes(scenes: [])
    }

    /// Supports the true branch of conditional scene content.
    /// Ownership: descriptions are copied. Isolation: none. Errors: none. Cancellation: none.
    public static func buildEither(first component: ApplicationScenes) -> ApplicationScenes {
        component
    }

    /// Supports the false branch of conditional scene content.
    /// Ownership: descriptions are copied. Isolation: none. Errors: none. Cancellation: none.
    public static func buildEither(second component: ApplicationScenes) -> ApplicationScenes {
        component
    }
}

/// Shared application entry-point contract for iOS, macOS and tvOS consumers.
/// Ownership: the application owns immutable construction dependencies. Isolation: compose runs on MainActor. Errors: scene factory errors are handled by AppRuntime. Cancellation: runtime owns started scene work.
public protocol Application: Sendable {
    associatedtype Content: ApplicationContent

    /// Creates the application description without composing scenes or starting effects.
    /// Ownership: the returned value owns immutable construction dependencies. Isolation: none.
    /// Errors: none. Cancellation: no work starts during initialization.
    init()

    /// Describes scenes without allocating native views or starting subscriptions.
    @MainActor @ApplicationBuilder
    func compose() -> Content
}

extension Application {
    /// Framework-owned application entry point shared by all supported Apple platforms.
    /// Ownership: the entry point creates one runtime and transfers native lifecycle ownership
    /// to the platform boundary. Isolation: startup is MainActor. Errors: startup failures are
    /// reported by the platform boundary. Cancellation: platform termination stops the runtime.
    @MainActor
    public static func main() {
        ApplicationEntryPoint.run(application: Self())
    }
}

/// Startup behavior when one scene factory fails.
/// Ownership: the value is copied by runtime. Isolation: none. Errors: `.failFast` returns the first typed failure; `.continueLaunching` records failures. Cancellation: caller cancellation remains terminal.
public enum ApplicationStartupFailurePolicy: Sendable, Hashable {
    case failFast
    case continueLaunching
}

/// Typed application startup failures.
/// Ownership: associated values are copied. Isolation: none. Errors: identifies duplicate or failed scenes. Cancellation: cancellation is reported separately by the thrown operation.
public enum ApplicationRuntimeError: Error, Sendable, Hashable {
    case alreadyStarted
    case duplicateScene(SceneID)
    case sceneFailed(SceneID, String)
}

/// A non-platform startup report for diagnostics and tests.
/// Ownership: the report owns successful scenes and failure snapshots. Isolation: MainActor. Errors: failures are values. Cancellation: a cancelled startup produces no partial report.
@MainActor
public struct ApplicationStartReport {
    public let scenes: [WindowScene]
    public let failures: [ApplicationRuntimeError]

    /// Creates a startup report.
    /// Ownership: arrays are copied. Isolation: MainActor. Errors: failures are preserved. Cancellation: none.
    public init(scenes: [WindowScene], failures: [ApplicationRuntimeError]) {
        self.scenes = scenes
        self.failures = failures
    }
}

/// MainActor runtime that separates scene description, construction and activation.
/// Ownership: runtime owns started scenes. Isolation: MainActor. Errors: typed startup failures are thrown or recorded by policy. Cancellation: stop closes every started scene and startup observes task cancellation.
@MainActor
public final class AppRuntime<App: Application> {
    public let application: App
    public let failurePolicy: ApplicationStartupFailurePolicy
    public private(set) var isStarted = false
    public private(set) var scenes: [SceneID: WindowScene] = [:]

    /// Creates a runtime without composing or starting scenes.
    /// Ownership: runtime retains the application and policy. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        application: App,
        failurePolicy: ApplicationStartupFailurePolicy = .failFast
    ) {
        self.application = application
        self.failurePolicy = failurePolicy
    }

    /// Composes, constructs and presents all application scenes once.
    /// Ownership: runtime retains successful scenes. Isolation: MainActor orchestration; factories may suspend. Errors: typed startup failures follow policy. Cancellation: cancellation closes partial scenes and rethrows.
    public func start() async throws -> ApplicationStartReport {
        guard !isStarted else { throw ApplicationRuntimeError.alreadyStarted }
        let descriptions = application.compose().scenes
        var seen: Set<SceneID> = []
        var successful: [WindowScene] = []
        var failures: [ApplicationRuntimeError] = []

        do {
            for description in descriptions {
                try Task.checkCancellation()
                guard seen.insert(description.id).inserted else {
                    let failure = ApplicationRuntimeError.duplicateScene(description.id)
                    if failurePolicy == .failFast { throw failure }
                    failures.append(failure)
                    continue
                }
                do {
                    let scene = try await description.make()
                    guard scene.id == description.id else {
                        let failure = ApplicationRuntimeError.duplicateScene(description.id)
                        if failurePolicy == .failFast { throw failure }
                        failures.append(failure)
                        continue
                    }
                    successful.append(scene)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ApplicationRuntimeError {
                    if failurePolicy == .failFast { throw error }
                    failures.append(error)
                } catch {
                    let failure = ApplicationRuntimeError.sceneFailed(
                        description.id, String(describing: error))
                    if failurePolicy == .failFast { throw failure }
                    failures.append(failure)
                }
            }
        } catch {
            successful.forEach { $0.close() }
            throw error
        }

        scenes = Dictionary(uniqueKeysWithValues: successful.map { ($0.id, $0) })
        successful.flatMap(\.windows).forEach { _ = $0.present() }
        isStarted = true
        return ApplicationStartReport(scenes: successful, failures: failures)
    }

    /// Synchronously composes and presents application scenes without async suspension.
    /// Ownership: runtime retains successful scenes. Isolation: MainActor. Errors: typed startup failures follow policy. Cancellation: synchronous execution is atomic and does not suspend.
    @discardableResult
    public func startSync() throws -> ApplicationStartReport {
        guard !isStarted else { throw ApplicationRuntimeError.alreadyStarted }
        let descriptions = application.compose().scenes
        var seen: Set<SceneID> = []
        var successful: [WindowScene] = []
        var failures: [ApplicationRuntimeError] = []

        do {
            for description in descriptions {
                guard seen.insert(description.id).inserted else {
                    let failure = ApplicationRuntimeError.duplicateScene(description.id)
                    if failurePolicy == .failFast { throw failure }
                    failures.append(failure)
                    continue
                }
                do {
                    let scene = try description.makeSync()
                    guard scene.id == description.id else {
                        let failure = ApplicationRuntimeError.duplicateScene(description.id)
                        if failurePolicy == .failFast { throw failure }
                        failures.append(failure)
                        continue
                    }
                    scenes[description.id] = scene
                    successful.append(scene)
                } catch let error as ApplicationRuntimeError {
                    if failurePolicy == .failFast { throw error }
                    failures.append(error)
                } catch {
                    let failure = ApplicationRuntimeError.sceneFailed(
                        description.id, String(describing: error))
                    if failurePolicy == .failFast { throw failure }
                    failures.append(failure)
                }
            }
        } catch {
            successful.forEach { $0.close() }
            throw error
        }

        successful.flatMap(\.windows).forEach { _ = $0.present() }
        isStarted = true
        return ApplicationStartReport(scenes: successful, failures: failures)
    }

    /// Stops the runtime and closes all started scenes exactly once.
    /// Ownership: runtime releases its scenes. Isolation: MainActor. Errors: none. Cancellation: scene windows and controllers are disposed.
    public func stop() {
        guard isStarted || !scenes.isEmpty else { return }
        scenes.values.forEach { $0.close() }
        scenes.removeAll()
        isStarted = false
    }
}
