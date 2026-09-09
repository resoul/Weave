import Foundation

/// The origin of a normalized deep-link request. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum DeepLinkSource: String, Sendable, Hashable {
    case url
    case userActivity
}

/// Immutable user-activity data normalized by a platform adapter. Ownership: copied value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct UserActivityPayload: Sendable, Hashable {
    /// Activity identifier. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let activityType: String
    /// Optional universal-link URL. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let webpageURL: URL?
    /// Sanitized string metadata. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let userInfo: [String: String]

    /// Creates an immutable payload. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        activityType: String,
        webpageURL: URL? = nil,
        userInfo: [String: String] = [:]
    ) {
        self.activityType = activityType
        self.webpageURL = webpageURL
        self.userInfo = userInfo
    }
}

/// A platform-neutral deep-link request. Adapters create this value from URL and user-activity callbacks. Ownership: copied value. Isolation: none. Errors: invalid activity URL. Cancellation: not applicable.
public struct DeepLinkRequest: Sendable, Hashable {
    /// Normalized URL. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let url: URL
    /// Adapter origin. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let source: DeepLinkSource
    /// Optional originating activity. Ownership: copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public let activity: UserActivityPayload?

    /// Creates a URL request. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(url: URL, source: DeepLinkSource = .url, activity: UserActivityPayload? = nil) {
        self.url = url
        self.source = source
        self.activity = activity
    }

    /// Creates a request from an activity with a webpage URL. Ownership: payload is copied. Isolation: none. Errors: missingActivityURL. Cancellation: not applicable.
    public init(activity: UserActivityPayload) throws {
        guard let url = activity.webpageURL else { throw RouteCodecError.missingActivityURL }
        self.init(url: url, source: .userActivity, activity: activity)
    }
}

/// Errors produced before a URL is allowed into the route pipeline. Ownership: immutable error. Isolation: none. Errors: describes strict validation failure. Cancellation: not applicable.
public enum RouteCodecError: Error, Sendable, Hashable {
    case invalidURL
    case missingScheme
    case unsupportedScheme(String)
    case missingHost
    case unsupportedHost(String)
    case invalidPath
    case invalidRoute
    case missingActivityURL
}

/// Typed route codec contract. Decoding is pure and never constructs a controller. Ownership: codec owns no route or controller. Isolation: none. Errors: typed codec errors. Cancellation: caller-owned.
public protocol RouteCodec: Sendable {
    associatedtype Destination: Route
    func decode(_ url: URL) throws -> Destination?
    func encode(_ route: Destination) throws -> URL
}

/// Closure-backed strict route codec with scheme and host allow-lists. Ownership: codec owns Sendable closures. Isolation: none. Errors: strict URL validation. Cancellation: caller-owned.
public struct AnyRouteCodec<R: Route>: RouteCodec, Sendable {
    /// Destination route type. Ownership: type metadata only. Isolation: none. Errors: none. Cancellation: not applicable.
    public typealias Destination = R

    private let schemes: Set<String>
    private let hosts: Set<String>
    private let decoder: @Sendable (URL) throws -> R?
    private let encoder: @Sendable (R) throws -> URL

    /// Creates an allow-listed codec. Ownership: closures are retained. Isolation: none. Errors: callback errors propagate. Cancellation: caller-owned.
    public init(
        schemes: Set<String>,
        hosts: Set<String>,
        decode: @escaping @Sendable (URL) throws -> R?,
        encode: @escaping @Sendable (R) throws -> URL
    ) {
        self.schemes = Set(schemes.map { $0.lowercased() })
        self.hosts = Set(hosts.map { $0.lowercased() })
        self.decoder = decode
        self.encoder = encode
    }

    /// Decodes an allow-listed URL. Ownership: returned route is a value. Isolation: none. Errors: strict validation or decoder errors. Cancellation: caller-owned.
    public func decode(_ url: URL) throws -> R? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased()
        else { throw RouteCodecError.invalidURL }
        guard schemes.contains(scheme) else { throw RouteCodecError.unsupportedScheme(scheme) }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            throw RouteCodecError.missingHost
        }
        guard hosts.contains(host) else { throw RouteCodecError.unsupportedHost(host) }
        guard !components.percentEncodedPath.isEmpty,
            components.percentEncodedPath.first == "/"
        else {
            throw RouteCodecError.invalidPath
        }
        guard components.fragment == nil else { throw RouteCodecError.invalidURL }
        return try decoder(url)
    }

    /// Encodes and validates a route URL. Ownership: returned URL is a value. Isolation: none. Errors: encoder or validation errors. Cancellation: caller-owned.
    public func encode(_ route: R) throws -> URL {
        let url = try encoder(route)
        _ = try decode(url)
        return url
    }
}

/// Result of accepting a normalized deep-link request. Ownership: immutable route/result value. Isolation: none. Errors: represented by rejected or failed cases. Cancellation: caller-owned.
public enum DeepLinkOutcome<R: Route>: Sendable, Hashable {
    case queued(R)
    case duplicate(R)
    case routed(R)
    case unsupported(String)
    case rejected(DeepLinkRejection)
    case failed(String)
}

/// Policy rejection after decoding. Ownership: immutable value. Isolation: none. Errors: represented by cases. Cancellation: not applicable.
public enum DeepLinkRejection: Sendable, Hashable {
    case authenticationRequired
    case featureDisabled
}

/// Main-actor pipeline that gates typed routes before handing them to the ordinary router. Ownership: pipeline owns queue and closures. Isolation: MainActor. Errors: represented in outcomes. Cancellation: awaiting caller cancellation is propagated.
@MainActor
public final class DeepLinkPipeline<R: Route> {
    /// Codec used by this pipeline. Ownership: type metadata only. Isolation: MainActor owner. Errors: codec errors are outcomes. Cancellation: caller-owned.
    public typealias Codec = AnyRouteCodec<R>
    /// Authentication/feature gate closure. Ownership: pipeline retains closure. Isolation: MainActor. Errors: false rejects. Cancellation: caller-owned.
    public typealias Gate = @MainActor @Sendable (R) async -> Bool
    /// Ordinary router closure. Ownership: pipeline retains closure. Isolation: MainActor. Errors: throws become failed outcomes. Cancellation: caller-owned.
    public typealias Router = @MainActor @Sendable (R) async throws -> Bool

    private let codec: Codec
    private let authenticationGate: Gate
    private let featureGate: Gate
    private let router: Router
    private let capacity: Int
    private var pending: [R] = []
    private var seen: Set<R> = []
    private var ready = false

    /// Creates a cold-start capable pipeline. Ownership: pipeline retains closures. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        codec: Codec,
        capacity: Int = 32,
        authenticationGate: @escaping Gate = { _ in true },
        featureGate: @escaping Gate = { _ in true },
        router: @escaping Router
    ) {
        self.codec = codec
        self.capacity = max(1, capacity)
        self.authenticationGate = authenticationGate
        self.featureGate = featureGate
        self.router = router
    }

    /// Whether warm-start delivery is open. Ownership: borrowed snapshot. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var isReady: Bool { ready }
    /// Number of queued cold-start routes. Ownership: borrowed snapshot. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var pendingCount: Int { pending.count }

    /// Opens warm-start delivery and drains the cold-start queue in arrival order. Ownership: queue entries are consumed. Isolation: MainActor. Errors: routed outcomes retain failures. Cancellation: caller cancellation stops draining.
    public func start() async {
        guard !ready else { return }
        ready = true
        let queued = pending
        pending.removeAll(keepingCapacity: true)
        for route in queued { _ = await process(route) }
    }

    /// Decodes and accepts one adapter-normalized request. Ownership: request is borrowed and route is copied. Isolation: MainActor. Errors: validation becomes unsupported outcome. Cancellation: caller cancellation propagates.
    public func receive(_ request: DeepLinkRequest) async -> DeepLinkOutcome<R> {
        do {
            guard let route = try codec.decode(request.url) else {
                return .unsupported("route codec returned no destination")
            }
            guard seen.insert(route).inserted else { return .duplicate(route) }
            if !ready {
                if pending.count == capacity { pending.removeFirst() }
                pending.append(route)
                return .queued(route)
            }
            return await process(route)
        } catch {
            return .unsupported(String(describing: error))
        }
    }

    private func process(_ route: R) async -> DeepLinkOutcome<R> {
        guard await authenticationGate(route) else { return .rejected(.authenticationRequired) }
        guard await featureGate(route) else { return .rejected(.featureDisabled) }
        do {
            guard try await router(route) else { return .failed("router rejected route") }
            return .routed(route)
        } catch {
            return .failed(String(describing: error))
        }
    }
}

/// Coordinator integration that sends accepted routes through the ordinary navigation handler.
/// Ownership: the returned pipeline owns its gates and borrows the coordinator weakly. Isolation: MainActor.
/// Errors: navigation failures are represented by pipeline outcomes. Cancellation: coordinator stop invalidates routing.
@MainActor
public extension Coordinator {
    /// Creates a deep-link pipeline backed by this coordinator's router. Ownership: pipeline retains closures and does not retain the coordinator.
    /// Isolation: MainActor. Errors: codec and navigation failures become typed outcomes. Cancellation: caller-owned.
    func makeDeepLinkPipeline(
        codec: AnyRouteCodec<R>,
        capacity: Int = 32,
        authenticationGate: @escaping DeepLinkPipeline<R>.Gate = { _ in true },
        featureGate: @escaping DeepLinkPipeline<R>.Gate = { _ in true },
        animated: Bool = true
    ) -> DeepLinkPipeline<R> {
        DeepLinkPipeline(
            codec: codec,
            capacity: capacity,
            authenticationGate: authenticationGate,
            featureGate: featureGate,
            router: { [weak self] route in
                guard let self else { return false }
                return await self.handle(route, animated: animated)
            }
        )
    }
}
