import Foundation
import Flux

/// HTTP methods supported by the transport boundary.
/// Ownership: the value is copied by requests. Isolation: none. Errors: none. Cancellation: none.
public enum HTTPMethod: String, Sendable, Hashable {
    case get, post, put, patch, delete
}

/// Immutable request description. Query items are encoded deterministically by key.
/// Ownership: the value owns request data. Isolation: none. Errors: invalid URLs are reported by
/// transport. Cancellation: transport cancellation is propagated.
public struct HTTPRequest: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var query: [String: String]
    public var timeout: Duration?

    /// Creates a request description without starting network work.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: none.
    public init(
        method: HTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        query: [String: String] = [:],
        timeout: Duration? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.query = query
        self.timeout = timeout
    }
}

/// Immutable response returned by a transport.
/// Ownership: the result owns copied response data. Isolation: none. Errors: none. Cancellation: none.
public struct HTTPResult: Sendable, Hashable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data

    /// Creates a transport result.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: none.
    public init(statusCode: Int, headers: [String: String] = [:], data: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.data = data
    }
}

/// Typed failures exposed by the networking boundary.
/// Ownership: values own copied diagnostics. Isolation: none. Errors: this type is the error
/// surface. Cancellation: task cancellation remains `CancellationError`.
public enum HTTPError: Error, Sendable, Hashable {
    case invalidResponse
    case unacceptableStatus(code: Int, body: Data)
    case transport(String)
    case decoding(String)
}

/// Explicit retry policy. Only idempotent methods are eligible for retries.
/// Ownership: the value is copied by HTTPClient. Isolation: none. Errors: invalid attempt counts
/// are normalized to one attempt. Cancellation: cancellation interrupts any retry delay.
public enum HTTPRetryPolicy: Sendable, Hashable {
    case none
    case fixed(delay: Duration, maxAttempts: Int)
    case exponential(initial: Duration, maximum: Duration, maxAttempts: Int)

    fileprivate var maxAttempts: Int {
        switch self {
        case .none: return 1
        case let .fixed(_, attempts), let .exponential(_, _, attempts): return max(1, attempts)
        }
    }

    fileprivate func delay(for attempt: Int) -> Duration {
        switch self {
        case .none: return .zero
        case let .fixed(delay, _): return delay
        case let .exponential(initial, maximum, _):
            var delay = initial
            if attempt > 1 {
                for _ in 1..<attempt { delay = minDuration(delay + delay, maximum) }
            }
            return minDuration(delay, maximum)
        }
    }
}

/// Request interceptor. Interceptors run in declaration order before transport.
/// Ownership: the client retains immutable interceptors. Isolation: implementations are Sendable.
/// Errors: an interceptor may reject a request. Cancellation: cancellation propagates through await.
public protocol HTTPInterceptor: Sendable {
    func intercept(_ request: HTTPRequest) async throws -> HTTPRequest

    func interceptResponse(
        _ result: HTTPResult,
        for request: HTTPRequest
    ) async throws -> HTTPResult

    func interceptError(_ error: HTTPError, for request: HTTPRequest) async throws -> HTTPError
}

public extension HTTPInterceptor {
    /// Preserves a response when an interceptor has no response behavior.
    /// Ownership: the result is returned unchanged. Isolation: implementation-defined.
    /// Errors: none. Cancellation: cancellation propagates.
    func interceptResponse(
        _ result: HTTPResult,
        for request: HTTPRequest
    ) async throws -> HTTPResult { result }

    /// Preserves an error when an interceptor has no error behavior.
    /// Ownership: the error is returned unchanged. Isolation: implementation-defined.
    /// Errors: none. Cancellation: cancellation propagates.
    func interceptError(
        _ error: HTTPError,
        for request: HTTPRequest
    ) async throws -> HTTPError { error }
}

/// Injectable transport used by HTTPClient and deterministic tests.
/// Ownership: the client retains the Sendable transport. Isolation: implementation-defined but
/// Sendable. Errors: transport errors propagate. Cancellation: implementations must cancel work.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResult
}

/// URLSession-backed production transport.
/// Ownership: the transport retains its session. Isolation: Sendable value boundary. Errors:
/// network and status failures are typed. Cancellation: cancelled URLSession tasks terminate.
public struct URLSessionHTTPTransport: HTTPTransport, Sendable {
    private let session: URLSession

    /// Creates a URLSession transport.
    /// Ownership: the session is retained. Isolation: none. Errors: none. Cancellation: none.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Sends one request through URLSession.
    /// Ownership: the result owns response data. Isolation: none. Errors: throws `HTTPError`.
    /// Cancellation: cancelling the task cancels the URLSession request.
    public func send(_ request: HTTPRequest) async throws -> HTTPResult {
        var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let queryItems = request.query.keys.sorted().map { key in
            URLQueryItem(name: key, value: request.query[key])
        }
        let existingQueryItems = components?.queryItems ?? []
        components?.queryItems = existingQueryItems + queryItems
        guard let url = components?.url else { throw HTTPError.transport("Invalid URL") }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue.uppercased()
        urlRequest.allHTTPHeaderFields = request.headers
        urlRequest.httpBody = request.body
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = max(0, timeout.timeInterval)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let response = response as? HTTPURLResponse else {
                throw HTTPError.invalidResponse
            }
            return HTTPResult(
                statusCode: response.statusCode,
                headers: response.allHeaderFields.reduce(into: [:]) { result, pair in
                    result[String(describing: pair.key)] = String(describing: pair.value)
                },
                data: data
            )
        } catch let error as HTTPError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HTTPError.transport(String(describing: error))
        }
    }
}

/// Progress and terminal values emitted by the cold request stream.
/// Ownership: values own copied payloads. Isolation: none. Errors: failures are typed values.
/// Cancellation: cancelling the subscription cancels the request task.
public enum HTTPProgress: Sendable, Hashable {
    case uploadProgress(Double)
    case downloadProgress(Double)
    case completed(HTTPResult)
    case failed(HTTPError)
}

/// Async HTTP facade with injectable transport and ordered request interceptors.
/// Ownership: the client retains Sendable dependencies. Isolation: none. Errors: typed failures
/// are thrown or emitted. Cancellation: async calls and Flux subscriptions are cancellable.
public struct HTTPClient: Sendable {
    private let transport: any HTTPTransport
    private let interceptors: [any HTTPInterceptor]
    private let retryPolicy: HTTPRetryPolicy

    /// Creates an HTTP client without starting network work.
    /// Ownership: dependencies are retained. Isolation: none. Errors: none. Cancellation: none.
    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        interceptors: [any HTTPInterceptor] = [],
        retryPolicy: HTTPRetryPolicy = .none
    ) {
        self.transport = transport
        self.interceptors = interceptors
        self.retryPolicy = retryPolicy
    }

    /// Sends a request and validates its 2xx status.
    /// Ownership: the result owns response data. Isolation: none. Errors: throws `HTTPError`.
    /// Cancellation: cancelling the task cancels transport work.
    public func send(_ request: HTTPRequest) async throws -> HTTPResult {
        let intercepted = try await intercept(request)
        var attempt = 1
        while true {
            do {
                var result = try await transport.send(intercepted)
                for interceptor in interceptors {
                    result = try await interceptor.interceptResponse(result, for: intercepted)
                }
                guard (200..<300).contains(result.statusCode) else {
                    throw HTTPError.unacceptableStatus(code: result.statusCode, body: result.data)
                }
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let typedError: HTTPError
                if let error = error as? HTTPError {
                    typedError = error
                } else {
                    typedError = .transport(String(describing: error))
                }
                var interceptedError = typedError
                for interceptor in interceptors {
                    interceptedError = try await interceptor.interceptError(
                        interceptedError,
                        for: intercepted
                    )
                }
                let retryable = shouldRetry(interceptedError, method: intercepted.method)
                if !retryable || attempt >= retryPolicy.maxAttempts { throw interceptedError }
                let delay = retryPolicy.delay(for: attempt)
                if delay > .zero { try await Task.sleep(for: delay) }
                try Task.checkCancellation()
                attempt += 1
            }
        }
    }

    /// Sends a request and decodes its response as `T`.
    /// Ownership: the decoded value is returned to the caller. Isolation: none. Errors: throws
    /// transport, status, or decoding errors. Cancellation: cancelling the task cancels work.
    public func send<T: Decodable & Sendable>(
        _ request: HTTPRequest,
        decode: T.Type
    ) async throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: try await send(request).data)
        } catch let error as HTTPError {
            throw error
        } catch {
            throw HTTPError.decoding(String(describing: error))
        }
    }

    /// Creates a cold progress stream for one request.
    /// Ownership: each subscription owns one transport task. Isolation: none. Errors: failures
    /// are emitted as typed values. Cancellation: cancelling the subscription cancels that task.
    public func send(_ request: HTTPRequest) -> Flux<HTTPProgress> {
        Flux { emitter in
            let task = Task {
                do {
                    emitter.send(.downloadProgress(0))
                    emitter.send(.completed(try await self.send(request)))
                    emitter.finish()
                } catch is CancellationError {
                    emitter.finish()
                } catch let error as HTTPError {
                    emitter.send(.failed(error))
                    emitter.finish()
                } catch {
                    emitter.send(.failed(.transport(String(describing: error))))
                    emitter.finish()
                }
            }
            emitter.onCancellation { task.cancel() }
        }
    }

    private func intercept(_ request: HTTPRequest) async throws -> HTTPRequest {
        var current = request
        for interceptor in interceptors {
            current = try await interceptor.intercept(current)
        }
        return current
    }

    private func shouldRetry(_ error: Error, method: HTTPMethod) -> Bool {
        guard retryPolicy != .none, method.isIdempotent else { return false }
        if case let HTTPError.unacceptableStatus(code, _) = error {
            return code == 408 || code == 429 || (500...599).contains(code)
        }
        return error is HTTPError
    }
}

private extension HTTPMethod {
    var isIdempotent: Bool { self == .get || self == .put || self == .delete }
}

private func minDuration(_ lhs: Duration, _ rhs: Duration) -> Duration { lhs < rhs ? lhs : rhs }

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
