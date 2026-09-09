import Foundation
public import Flux

/// Immutable media source identity used by a video node.
/// Ownership: value is copied by the node. Isolation: none. Errors: empty URLs are accepted by the contract. Cancellation: not applicable.
public struct VideoSource: Sendable, Hashable {
    public let url: URL

    /// Creates a source without allocating a player.
    /// Ownership: URL value is copied. Isolation: none. Errors: validation is delegated to the backend. Cancellation: none.
    public init(url: URL) { self.url = url }
}

/// Immutable metadata returned after a source is prepared.
/// Ownership: value is copied by the node. Isolation: none. Errors: duration may be unknown. Cancellation: load cancellation is owner-controlled.
public struct VideoMetadata: Sendable, Hashable {
    public let duration: Double?

    /// Creates metadata with an optional duration in seconds.
    /// Ownership: value is copied. Isolation: none. Errors: negative durations clamp to nil. Cancellation: none.
    public init(duration: Double? = nil) { self.duration = duration.map { max(0, $0) } }
}

/// Typed backend failure safe to publish through a UI state stream.
/// Ownership: immutable value. Isolation: none. Errors: contains diagnostic text only. Cancellation: cancellation is represented separately.
public struct VideoFailure: Error, Sendable, Hashable {
    public let message: String

    /// Creates a backend failure without retaining a platform error object.
    /// Ownership: message is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(message: String) { self.message = message }
}

/// Playback state owned by `VideoNode`.
/// Ownership: immutable snapshot. Isolation: none. Errors: failure is typed. Cancellation: cancelled loads return to idle.
public enum VideoPlaybackState: Sendable, Hashable {
    case idle
    case loading(VideoSource)
    case ready(VideoMetadata)
    case playing
    case paused
    case failed(VideoFailure)
}

/// Events emitted by a platform media backend.
/// Ownership: immutable snapshots. Isolation: MainActor through the backend. Errors: failures are typed. Cancellation: stream ends when backend is unloaded.
public enum VideoBackendEvent: Sendable, Hashable {
    case progress(seconds: Double)
    case ended
    case failed(VideoFailure)
}

/// Platform-neutral media contract. UIKit/AppKit implementations may wrap AVPlayer, but Core never imports AVFoundation.
/// Ownership: node owns the backend for its lifetime. Isolation: MainActor. Errors: load failures throw. Cancellation: unload cancels owned work and observations.
@MainActor
public protocol VideoBackend: AnyObject {
    var events: AsyncStream<VideoBackendEvent> { get }
    func load(_ source: VideoSource) async throws -> VideoMetadata
    func play()
    func pause()
    func unload()
    func dispose()
}

extension VideoBackend {
    /// Permanently releases backend resources. The default delegates to unload for lightweight fakes.
    /// Ownership: backend releases its resources. Isolation: MainActor. Errors: none. Cancellation: owned work is cancelled.
    public func dispose() { unload() }
}

/// Typed controls emitted by a video node's platform adapter.
/// Ownership: immutable action. Isolation: MainActor at dispatch. Errors: unsupported controls are ignored. Cancellation: disposal drops actions.
public enum VideoControl: Sendable, Hashable {
    case play
    case pause
    case toggle
}

/// MainActor video node with explicit viewport and activation policy.
/// Ownership: node owns backend, load task and event observation. Isolation: MainActor. Errors: backend failures become `.failed`. Cancellation: source replacement, unmount and disposal cancel load/observation.
@MainActor
public final class VideoNode: Node {
    public private(set) var source: VideoSource?
    public private(set) var playbackState: VideoPlaybackState = .idle {
        didSet {
            guard playbackState != oldValue else { return }
            let s = playbackState
            Task { [state] in await state.set(s) }
            setNeedsDisplay()
        }
    }
    public private(set) var progress: Double = 0 {
        didSet {
            guard progress != oldValue else { return }
            setNeedsDisplay()
        }
    }
    public private(set) var metadata: VideoMetadata? {
        didSet {
            guard metadata != oldValue else { return }
            setNeedsDisplay()
        }
    }

    /// Actor-isolated distinct state storage for playback state.
    /// Ownership: the node owns the state holder. Isolation: nonisolated actor. Errors: none. Cancellation: not applicable.
    public nonisolated let state = CurrentValueDistinct<VideoPlaybackState>(.idle)

    /// Replayable reactive playback state stream.
    /// Ownership: the stream is borrowed. Isolation: nonisolated. Errors: none. Cancellation: subscriptions can be cancelled.
    public nonisolated var stateFlux: Flux<VideoPlaybackState> { state.flux }

    public let controls = ActionPipe<VideoControl>(capacity: 32)
    public let events = ActionPipe<VideoBackendEvent>(capacity: 64)

    public var autoplay: Bool
    public var pausesWhenInactive: Bool

    /// Platform media backend instance owned by this node.
    /// Ownership: node owns the backend for its lifetime. Isolation: MainActor. Errors: none. Cancellation: backend unloads on node disposal.
    public let backend: any VideoBackend
    private var loadTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var mounted = false
    private var visible = false
    private var active = false

    /// Creates a video node without allocating a native player.
    /// Ownership: node retains the backend and source policy. Isolation: MainActor. Errors: no work starts until `mount()`. Cancellation: disposal cancels all owned work.
    public init(
        source: VideoSource? = nil,
        backend: any VideoBackend,
        autoplay: Bool = true,
        pausesWhenInactive: Bool = true
    ) {
        self.source = source
        self.backend = backend
        self.autoplay = autoplay
        self.pausesWhenInactive = pausesWhenInactive
        super.init()
    }

    /// Replaces the source and cancels the previous load before starting the new generation.
    /// Ownership: source is copied. Isolation: MainActor. Errors: backend errors publish `.failed`. Cancellation: prior load is cancelled and stale results are ignored.
    public func setSource(_ source: VideoSource?) {
        generation &+= 1
        loadTask?.cancel()
        backend.unload()
        metadata = nil
        progress = 0
        self.source = source
        guard mounted, let source else {
            playbackState = .idle
            return
        }
        beginLoad(source, generation: generation)
    }

    /// Mounts the node's backend observation exactly once.
    /// Ownership: node owns the observation until unmount/dispose. Isolation: MainActor. Errors: repeated mount is idempotent. Cancellation: unmount cancels observation and load.
    public func mount() {
        guard !mounted, lifecycleState != .disposed else { return }
        mounted = true
        observeBackendIfNeeded()
        if let source { beginLoad(source, generation: generation) }
    }

    /// Unmounts the node and releases backend work while retaining source state.
    /// Ownership: backend work is released. Isolation: MainActor. Errors: repeated unmount is idempotent. Cancellation: load and observations are cancelled.
    public func unmount() {
        guard mounted else { return }
        mounted = false
        generation &+= 1
        loadTask?.cancel(); loadTask = nil
        observationTask?.cancel(); observationTask = nil
        backend.unload()
        playbackState = source == nil ? .idle : .paused
    }

    /// Updates viewport visibility and applies autoplay policy.
    /// Ownership: visibility is a node-owned value. Isolation: MainActor. Errors: no-op when disposed. Cancellation: leaving viewport pauses playback.
    public func setViewportVisible(_ visible: Bool) {
        self.visible = visible
        applyPlaybackPolicy()
    }

    /// Updates app/scene activation and applies background playback policy.
    /// Ownership: activation is a node-owned value. Isolation: MainActor. Errors: no-op when disposed. Cancellation: inactive policy pauses playback.
    public func setActive(_ active: Bool) {
        self.active = active
        applyPlaybackPolicy()
    }

    /// Applies a typed playback control.
    /// Ownership: control is copied. Isolation: MainActor. Errors: unavailable backend state is ignored. Cancellation: disposal drops controls.
    @discardableResult
    public func apply(_ control: VideoControl) -> Bool {
        guard lifecycleState != .disposed, mounted else { return false }
        switch control {
        case .play: backend.play(); playbackState = .playing
        case .pause: backend.pause(); playbackState = .paused
        case .toggle:
            if case .playing = playbackState {
                backend.pause(); playbackState = .paused
            } else {
                backend.play(); playbackState = .playing
            }
        }
        _ = controls.send(control)
        return true
    }

    public override func dispose() {
        unmount()
        backend.dispose()
        controls.finish(); events.finish()
        super.dispose()
    }

    private func beginLoad(_ source: VideoSource, generation expected: UInt64) {
        loadTask?.cancel()
        playbackState = .loading(source)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let metadata = try await backend.load(source)
                guard !Task.isCancelled, self.generation == expected, self.source == source,
                    self.mounted
                else { return }
                self.metadata = metadata
                self.playbackState = .ready(metadata)
                self.applyPlaybackPolicy()
            } catch is CancellationError {
            } catch {
                guard self.generation == expected else { return }
                let failure =
                    error as? VideoFailure ?? VideoFailure(message: String(describing: error))
                self.playbackState = .failed(failure)
                _ = self.events.send(.failed(failure))
            }
        }
    }

    private func observeBackendIfNeeded() {
        guard observationTask == nil else { return }
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in backend.events {
                guard !Task.isCancelled, self.mounted else { return }
                switch event {
                case let .progress(seconds): progress = max(0, seconds)
                case .ended: playbackState = .paused
                case let .failed(failure): playbackState = .failed(failure)
                }
                _ = events.send(event)
            }
        }
    }

    private func applyPlaybackPolicy() {
        guard mounted else { return }
        switch playbackState {
        case .ready, .paused, .playing: break
        default: return
        }
        let shouldPlay = autoplay && visible && (active || !pausesWhenInactive)
        if shouldPlay, playbackState != .playing { backend.play(); playbackState = .playing }
        if !shouldPlay, playbackState == .playing { backend.pause(); playbackState = .paused }
    }
}
