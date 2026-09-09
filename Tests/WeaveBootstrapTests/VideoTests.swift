import Foundation
import Testing
import Weave

@MainActor
private final class FakeVideoBackend: VideoBackend {
    private let stream: AsyncStream<VideoBackendEvent>
    private let continuation: AsyncStream<VideoBackendEvent>.Continuation
    private var pending: [VideoSource: CheckedContinuation<VideoMetadata, Error>] = [:]
    private(set) var cancelled: [VideoSource] = []
    private(set) var playCount = 0
    private(set) var pauseCount = 0
    private(set) var eventAccessCount = 0

    init() {
        var continuation: AsyncStream<VideoBackendEvent>.Continuation!
        stream = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    var events: AsyncStream<VideoBackendEvent> {
        eventAccessCount += 1
        return stream
    }

    func load(_ source: VideoSource) async throws -> VideoMetadata {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[source] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let continuation = self.pending.removeValue(forKey: source) else {
                    return
                }
                cancelled.append(source)
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    func complete(_ source: VideoSource, duration: Double) {
        pending.removeValue(forKey: source)?.resume(returning: VideoMetadata(duration: duration))
    }

    func play() { playCount += 1 }
    func pause() { pauseCount += 1 }
    func unload() {}

    func emit(_ event: VideoBackendEvent) { continuation.yield(event) }
}

@MainActor
private func settleTasks() async {
    for _ in 0..<4 { await Task.yield() }
}

@Test
@MainActor
func videoNodeReplacesSourceAndCancelsStaleLoad() async {
    let backend = FakeVideoBackend()
    let first = VideoSource(url: URL(string: "https://example.com/first.mp4")!)
    let second = VideoSource(url: URL(string: "https://example.com/second.mp4")!)
    let node = VideoNode(backend: backend)
    node.mount()
    node.setSource(first)
    await settleTasks()
    node.setSource(second)
    await settleTasks()
    #expect(backend.cancelled == [first])
    backend.complete(second, duration: 12)
    await settleTasks()
    #expect(node.source == second)
    #expect(node.metadata?.duration == 12)
}

@Test
@MainActor
func videoNodeMountObservationAndPlaybackPolicyAreIdempotent() async {
    let backend = FakeVideoBackend()
    let source = VideoSource(url: URL(string: "https://example.com/video.mp4")!)
    let node = VideoNode(source: source, backend: backend)
    node.mount(); node.mount()
    await settleTasks()
    #expect(backend.eventAccessCount == 1)
    backend.complete(source, duration: 4)
    await settleTasks()
    node.setActive(true)
    node.setViewportVisible(true)
    #expect(backend.playCount == 1)
    node.setActive(false)
    #expect(backend.pauseCount == 1)
    node.unmount(); node.unmount()
}

@Test
@MainActor
func videoNodePropagatesProgressAndStopsAfterUnmount() async {
    let backend = FakeVideoBackend()
    let node = VideoNode(backend: backend)
    node.mount()
    await settleTasks()
    backend.emit(.progress(seconds: 3.5))
    await settleTasks()
    #expect(node.progress == 3.5)
    node.unmount()
    backend.emit(.progress(seconds: 9))
    await settleTasks()
    #expect(node.progress == 3.5)
}

#if canImport(QuartzCore)
    import QuartzCore
    import WeaveAdapters

    @MainActor
    private final class FakeAttachingVideoBackend: NSObject, VideoBackend,
        CALayerAttachingVideoBackend
    {
        private let stream: AsyncStream<VideoBackendEvent>
        private let continuation: AsyncStream<VideoBackendEvent>.Continuation
        private(set) var attachedToLayer: CALayer?
        private(set) var updatedBounds: CGRect?
        private(set) var detachCount = 0

        override init() {
            var continuation: AsyncStream<VideoBackendEvent>.Continuation!
            stream = AsyncStream { continuation = $0 }
            self.continuation = continuation
            super.init()
        }

        var events: AsyncStream<VideoBackendEvent> { stream }
        func load(_ source: VideoSource) async throws -> VideoMetadata {
            VideoMetadata(duration: 10)
        }
        func play() {}
        func pause() {}
        func unload() { detachVideoLayer() }

        func attachVideoLayer(to hostLayer: CALayer) {
            attachedToLayer = hostLayer
        }

        func detachVideoLayer() {
            detachCount += 1
            attachedToLayer = nil
        }

        func updateVideoLayerBounds(_ bounds: CGRect) {
            updatedBounds = bounds
        }
    }
#endif

@Test
@MainActor
func videoNodeEmitsReactiveStateFluxAndInvalidatesDisplay() async {
    let backend = FakeVideoBackend()
    let source = VideoSource(url: URL(string: "https://example.com/movie.mp4")!)
    let node = VideoNode(source: source, backend: backend)

    var observedStates: [VideoPlaybackState] = []
    let subscription = node.stateFlux.sinkOnMain { observedStates.append($0) }
    _ = subscription

    var invalidationCount = 0
    node.onInvalidate = { _ in invalidationCount += 1 }

    let initialRevision = node.displayRevision
    node.mount()
    await settleTasks()

    #expect(node.displayRevision > initialRevision)
    #expect(invalidationCount > 0)
    let revAfterMount = node.displayRevision

    backend.complete(source, duration: 10)
    await settleTasks()

    #expect(node.displayRevision > revAfterMount)
    #expect(node.metadata?.duration == 10)

    let revAfterMetadata = node.displayRevision
    backend.emit(.progress(seconds: 2.0))
    await settleTasks()

    #expect(node.displayRevision > revAfterMetadata)
    #expect(node.progress == 2.0)

    #expect(observedStates.contains(.idle))
    #expect(
        observedStates.contains(where: {
            if case .loading = $0 { return true }
            return false
        }))
    #expect(
        observedStates.contains(where: {
            if case .ready = $0 { return true }
            return false
        }))
}

#if canImport(QuartzCore)
    @Test
    @MainActor
    func videoNodeCALayerAttachingBackendProtocolWorks() async {
        let backend = FakeAttachingVideoBackend()
        let node = VideoNode(backend: backend)
        let hostLayer = CALayer()

        guard let attaching = node.backend as? (any CALayerAttachingVideoBackend) else {
            #expect(Bool(false), "backend must conform to CALayerAttachingVideoBackend")
            return
        }

        attaching.attachVideoLayer(to: hostLayer)
        #expect(backend.attachedToLayer === hostLayer)

        attaching.updateVideoLayerBounds(CGRect(x: 0, y: 0, width: 320, height: 240))
        #expect(backend.updatedBounds == CGRect(x: 0, y: 0, width: 320, height: 240))

        attaching.detachVideoLayer()
        #expect(backend.attachedToLayer == nil)
        #expect(backend.detachCount == 1)
    }
#endif
