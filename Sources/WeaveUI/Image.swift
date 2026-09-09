import Foundation
import Storage

/// Immutable image source identity.
/// Ownership: value is copied by the node. Isolation: none. Errors: URL validation is delegated to the loader. Cancellation: loader-owned.
public struct ImageSource: Sendable, Hashable {
    public let url: URL

    /// Creates a URL image source without starting I/O.
    /// Ownership: URL is copied. Isolation: none. Errors: empty/unsupported URLs are reported by the loader. Cancellation: none.
    public init(url: URL) { self.url = url }
}

/// Content scaling policy for image presentation.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ImageContentMode: Sendable, Hashable { case fit, fill, stretch }

/// Semantic policy for accessibility exposure.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ImageSemantic: Sendable, Hashable {
    case decorative
    case content(label: String?, hint: String?)
}

/// Immutable target for downsampling and cache identity.
/// Ownership: value is copied by the loader. Isolation: none. Errors: invalid values normalize. Cancellation: caller-owned.
public struct ImageRequest: Sendable, Hashable {
    public let source: ImageSource
    public let targetSize: MeasuredSize?
    public let scale: Double
    public let priority: ImageLoadPriority

    /// Creates a bounded image request.
    /// Ownership: values are copied. Isolation: none. Errors: scale normalizes to one. Cancellation: not applicable.
    public init(
        source: ImageSource, targetSize: MeasuredSize? = nil, scale: Double = 1,
        priority: ImageLoadPriority = .visible
    ) {
        self.source = source
        self.targetSize = targetSize
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.priority = priority
    }
}

/// Decode priority used by resource policy.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: prefetch may be cancelled first.
public enum ImageLoadPriority: Sendable, Hashable { case visible, prefetch }

/// Immutable decoded payload crossing the loader boundary.
/// Ownership: data is copied/owned by the payload. Isolation: none. Errors: dimensions are normalized. Cancellation: loader-owned.
public struct LoadedImage: Sendable, Hashable {
    public let data: Data
    public let size: MeasuredSize

    /// Creates a decoded payload snapshot.
    /// Ownership: payload owns data. Isolation: none. Errors: invalid dimensions normalize. Cancellation: not applicable.
    public init(data: Data, size: MeasuredSize) { self.data = data; self.size = size }
}

/// Typed image loading failure.
/// Ownership: immutable diagnostic value. Isolation: none. Errors: message is safe to publish. Cancellation: cancellation is represented separately.
public struct ImageFailure: Error, Sendable, Hashable {
    public let message: String

    /// Creates a loader failure without retaining platform error objects.
    /// Ownership: message is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(message: String) { self.message = message }
}

/// Observable image state owned by `ImageNode`.
/// Ownership: immutable snapshot. Isolation: none. Errors: typed failure. Cancellation: cancelled work returns to idle/loading policy.
public enum ImageLoadingState: Sendable, Hashable {
    case idle
    case loading(ImageRequest)
    case loaded(LoadedImage)
    case failed(ImageFailure)
}

/// Platform boundary for download, cache lookup and image decode/downsampling.
/// Ownership: node owns the loader dependency. Isolation: async Sendable boundary. Errors: corrupt bytes and transport failures throw. Cancellation: implementation must cancel I/O/decode.
public protocol ImageLoader: Sendable {
    func load(_ request: ImageRequest) async throws -> LoadedImage
}

/// Adds the shared binary FileCacheStore to an image loader.
/// Ownership: the wrapper retains loader and cache dependencies. Isolation: async Sendable boundary.
/// Errors: cache corruption is treated as a miss; loader errors propagate. Cancellation: cancellation propagates and never publishes a partial cache value.
public struct CachedImageLoader: ImageLoader, Sendable {
    private struct Envelope: Codable, Sendable {
        let data: Data
        let width: Double
        let height: Double
    }

    private let loader: any ImageLoader
    private let cache: FileCacheStore
    private let memoryCache: ImageMemoryCache?

    /// Creates a cache wrapper without starting I/O.
    /// Ownership: wrapper retains both dependencies. Isolation: none. Errors: none. Cancellation: no work starts during init.
    public init(
        loader: any ImageLoader,
        cache: FileCacheStore,
        memoryCache: ImageMemoryCache? = nil
    ) {
        self.loader = loader
        self.cache = cache
        self.memoryCache = memoryCache
    }

    /// Loads from the shared cache or delegates to the wrapped loader on a miss.
    /// Ownership: returned image is caller-owned. Isolation: async Sendable boundary. Errors: decode/loader failures propagate; corrupt cache entries are removed. Cancellation: propagates.
    public func load(_ request: ImageRequest) async throws -> LoadedImage {
        let key = Self.cacheKey(for: request)
        if let memoryCache, let image = await memoryCache.image(for: key) { return image }
        if let data = try? await cache.getData(key),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        {
            let image = LoadedImage(
                data: envelope.data,
                size: MeasuredSize(width: envelope.width, height: envelope.height))
            await memoryCache?.insert(image, for: key)
            return image
        }
        // A missing or corrupt disk entry is a cache miss; remove corrupt bytes before refetching.
        try? await cache.remove(key)
        let loaded = try await loader.load(request)
        let envelope = Envelope(
            data: loaded.data, width: loaded.size.width, height: loaded.size.height)
        if let encoded = try? JSONEncoder().encode(envelope) {
            try? await cache.setData(key, data: encoded)
        }
        await memoryCache?.insert(loaded, for: key)
        return loaded
    }

    private static func cacheKey(for request: ImageRequest) -> String {
        let width = request.targetSize.map { String($0.width) } ?? "auto"
        let height = request.targetSize.map { String($0.height) } ?? "auto"
        return
            "image|\(request.source.url.absoluteString)|\(width)x\(height)|scale=\(request.scale)"
    }
}

/// Bounded decode permit owner shared by image nodes.
/// Ownership: actor owns permits and waiters. Isolation: actor. Errors: cancellation propagates. Cancellation: permit is released exactly once after the operation.
public actor ImageDecodeLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Creates a limiter with a bounded concurrency.
    /// Ownership: limiter owns permits. Isolation: actor. Errors: values below one clamp to one. Cancellation: no work starts during initialization.
    public init(maxConcurrent: Int) { available = max(1, maxConcurrent) }

    /// Runs one decode while holding exactly one permit.
    /// Ownership: limiter owns permit for operation duration. Isolation: actor coordination plus caller operation. Errors: operation errors propagate. Cancellation: queued/running cancellation releases capacity.
    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws
        -> T
    {
        try await acquire()
        do {
            let value = try await operation()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func acquire() async throws {
        if available > 0 { available -= 1; return }
        try await withCheckedThrowingContinuation { continuation in waiters.append(continuation) }
    }

    private func release() {
        if let waiter = waiters.first {
            waiters.removeFirst(); waiter.resume()
        } else {
            available += 1
        }
    }
}

/// MainActor image node with generation-safe loading and semantic defaults.
/// Ownership: node owns load task and latest payload. Isolation: MainActor. Errors: state exposes typed failure. Cancellation: source replacement, unmount and dispose cancel stale load.
@MainActor
public final class ImageNode: Node {
    public private(set) var source: ImageSource?
    public private(set) var loadingState: ImageLoadingState = .idle
    public private(set) var image: LoadedImage?
    public private(set) var imageRevision: UInt64 = 0
    public var targetSize: MeasuredSize? {
        didSet {
            setNeedsLayout()
            setNeedsDisplay()
            reload()
        }
    }
    public var scale: Double {
        didSet {
            scale = scale.isFinite && scale > 0 ? scale : 1
            setNeedsDisplay()
            reload()
        }
    }
    public var contentMode: ImageContentMode {
        didSet {
            setNeedsDisplay()
        }
    }
    public var semantic: ImageSemantic { didSet { updateAccessibility() } }

    private let loader: any ImageLoader
    private let limiter: ImageDecodeLimiter
    private var loadTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var visible = true

    /// Creates an image node without allocating platform image objects.
    /// Ownership: node retains loader/limiter and source policy. Isolation: MainActor. Errors: no I/O starts until source is set. Cancellation: disposal cancels owned work.
    public init(
        source: ImageSource? = nil, loader: any ImageLoader,
        limiter: ImageDecodeLimiter = ImageDecodeLimiter(maxConcurrent: 2),
        contentMode: ImageContentMode = .fit,
        semantic: ImageSemantic = .content(label: nil, hint: nil)
    ) {
        self.source = source
        self.loader = loader
        self.limiter = limiter
        self.targetSize = nil
        self.scale = 1
        self.contentMode = contentMode
        self.semantic = semantic
        super.init()
        updateAccessibility()
    }

    /// Replaces source and cancels the previous request generation.
    /// Ownership: source is copied. Isolation: MainActor. Errors: stale image is cleared before loading. Cancellation: old task is cancelled and cannot apply.
    public func setSource(_ source: ImageSource?) {
        self.source = source
        self.image = nil
        setNeedsLayout()
        setNeedsDisplay()
        reload()
    }

    /// Updates target size to match the accepted layout bounds for downsampled decoding.
    /// Ownership: size is copied. Isolation: MainActor. Errors: none. Cancellation: triggers reload only when size changes.
    public func updateLayoutBounds(_ bounds: LayoutFrame) {
        let newTarget = MeasuredSize(width: bounds.width, height: bounds.height)
        if targetSize != newTarget {
            self.targetSize = newTarget
        }
    }

    /// Controls whether the node should spend decode resources while visible.
    /// Ownership: visibility is node-owned. Isolation: MainActor. Errors: none. Cancellation: hidden work is cancelled.
    public func setVisible(_ visible: Bool) {
        self.visible = visible; if visible { reload() } else { cancelLoad() }
    }

    /// Starts one generation-safe load for the current source.
    /// Ownership: node owns the task and payload. Isolation: MainActor. Errors: loadingState becomes failed. Cancellation: replacement/disposal cancels the task.
    public func reload() {
        cancelLoad()
        generation &+= 1
        setNeedsDisplay()
        guard visible, let source else {
            image = nil
            loadingState = .idle
            return
        }
        let request = ImageRequest(source: source, targetSize: targetSize, scale: scale)
        let expected = generation
        loadingState = .loading(request)
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let loaded = try await limiter.withPermit { try await loader.load(request) }
                guard !Task.isCancelled, self.generation == expected, self.source == source else {
                    return
                }
                self.image = loaded
                self.imageRevision &+= 1
                self.loadingState = .loaded(loaded)
                self.setNeedsDisplay()
            } catch is CancellationError {
            } catch {
                guard self.generation == expected else { return }
                self.image = nil
                self.loadingState = .failed(
                    error as? ImageFailure ?? ImageFailure(message: String(describing: error)))
                self.setNeedsDisplay()
            }
        }
    }

    public override func dispose() { cancelLoad(); super.dispose() }

    private func cancelLoad() { loadTask?.cancel(); loadTask = nil }

    private func updateAccessibility() {
        switch semantic {
        case .decorative: accessibility = AccessibilityProperties(isElement: false)
        case let .content(label, hint):
            accessibility = AccessibilityProperties(
                isElement: true, label: label, value: nil, hint: hint, role: .image)
        }
    }
}
