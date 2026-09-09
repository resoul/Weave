import Foundation
import Flux

/// WebSocket connection lifecycle.
/// Ownership: immutable snapshot. Isolation: none. Errors: failed carries a redacted reason. Cancellation: disconnected is terminal until connect.
public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
}

/// A text or binary WebSocket payload.
/// Ownership: the value owns copied payload data. Isolation: none. Errors: none. Cancellation: transport-owned.
public enum WSMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Reconnect policy with an explicit attempt limit and no implicit jitter.
/// Ownership: immutable value. Isolation: none. Errors: invalid intervals normalize to zero. Cancellation: disconnect cancels pending delay.
public enum ReconnectPolicy: Sendable, Equatable {
    case none
    case fixed(interval: TimeInterval, maxAttempts: Int?)
    case exponentialBackoff(initial: TimeInterval, max: TimeInterval, maxAttempts: Int?)

    fileprivate func delay(for attempt: Int) -> Duration {
        switch self {
        case .none: return .zero
        case let .fixed(interval, _): return .milliseconds(max(0, Int(interval * 1_000)))
        case let .exponentialBackoff(initial, maximum, _):
            let value = min(max(0, maximum), max(0, initial) * pow(2, Double(max(0, attempt - 1))))
            return .milliseconds(max(0, Int(value * 1_000)))
        }
    }

    fileprivate func allows(attempt: Int) -> Bool {
        switch self {
        case .none: return false
        case let .fixed(_, maxAttempts), let .exponentialBackoff(_, _, maxAttempts):
            return maxAttempts.map { attempt <= max(0, $0) } ?? true
        }
    }
}

/// Typed WebSocket failures without exposing credentials or payloads.
/// Ownership: immutable diagnostic value. Isolation: none. Errors: this is the send/connection error surface. Cancellation: cancellation remains separate.
public enum WebSocketError: Error, Sendable, Equatable {
    case notConnected
    case closed
    case transport(String)
    case reconnectExhausted
}

/// One injectable socket connection owned by WebSocketClient.
/// Ownership: client retains the connection. Isolation: async Sendable boundary. Errors: send and receive failures throw. Cancellation: close cancels receive delivery.
public protocol WebSocketConnection: Sendable {
    var incoming: AsyncThrowingStream<WSMessage, Error> { get }
    func send(_ message: WSMessage) async throws
    func close() async
}

/// Injectable socket factory used by deterministic tests and platform transports.
/// Ownership: client retains the factory. Isolation: Sendable async boundary. Errors: connection failures throw. Cancellation: cancelled connect aborts creation.
public protocol WebSocketTransport: Sendable {
    func connect(url: URL) async throws -> any WebSocketConnection
    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection
}

public extension WebSocketTransport {
    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        try await connect(url: url)
    }
}

/// URLSession-backed WebSocket transport.
/// Ownership: transport retains its URLSession. Isolation: Sendable value plus actor connection. Errors: URLSession failures are typed by client. Cancellation: task cancellation closes the socket.
public struct URLSessionWebSocketTransport: WebSocketTransport, Sendable {
    private let session: URLSession

    /// Creates a URLSession WebSocket transport. Ownership: session is retained. Isolation: none. Errors: none. Cancellation: none.
    public init(session: URLSession = .shared) { self.session = session }

    /// Opens one socket connection. Ownership: returned actor owns the task. Isolation: async. Errors: URLSession failures throw. Cancellation: cancellation closes the created task.
    public func connect(url: URL) async throws -> any WebSocketConnection {
        try await connect(url: url, headers: [:])
    }

    /// Opens a socket with handshake headers. Ownership: returned actor owns the task. Isolation: async. Errors: URLSession failures throw. Cancellation: cancellation closes the created task.
    public func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection
    {
        let connection = URLSessionWebSocketConnection(session: session, url: url, headers: headers)
        await connection.start()
        return connection
    }
}

private actor URLSessionWebSocketConnection: WebSocketConnection {
    private let task: URLSessionWebSocketTask
    private let continuation: AsyncThrowingStream<WSMessage, Error>.Continuation
    let incoming: AsyncThrowingStream<WSMessage, Error>
    private var receiveTask: Task<Void, Never>?

    init(session: URLSession, url: URL, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = headers
        task = session.webSocketTask(with: request)
        let pair = AsyncThrowingStream<WSMessage, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        incoming = pair.stream
        continuation = pair.continuation
        task.resume()
    }

    func start() {
        guard receiveTask == nil else { return }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    switch message {
                    case let .string(value): continuation.yield(.text(value))
                    case let .data(value): continuation.yield(.data(value))
                    @unknown default: break
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func send(_ message: WSMessage) async throws {
        switch message {
        case let .text(value): try await task.send(.string(value))
        case let .data(value): try await task.send(.data(value))
        }
    }

    func close() async {
        receiveTask?.cancel()
        receiveTask = nil
        task.cancel(with: .goingAway, reason: nil)
        continuation.finish()
    }
}

/// Actor-owned WebSocket lifecycle with one receive loop and bounded message fan-out.
/// Ownership: actor owns connection, tasks and state. Isolation: actor. Errors: state and send expose typed failures. Cancellation: disconnect is explicit and terminal until a later connect.
public actor WebSocketClient: Sendable {
    public nonisolated let state: CurrentValueDistinct<ConnectionState>
    private let messagesPipe = Pipe<WSMessage>(bufferingPolicy: .bufferingNewest(256))
    private let url: URL
    private let reconnectPolicy: ReconnectPolicy
    private let interceptors: [any HTTPInterceptor]
    private let transport: any WebSocketTransport
    private let sleep: @Sendable (Duration) async throws -> Void
    private var connection: (any WebSocketConnection)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var explicitDisconnect = true

    /// Incoming messages are hot and bounded per subscriber; a new subscriber receives no history.
    public nonisolated var messages: Flux<WSMessage> { messagesPipe.flux }

    /// Creates a URLSession-backed client without starting a connection.
    /// Ownership: client retains URL, policy and transport. Isolation: actor. Errors: none. Cancellation: no work starts during init.
    public init(
        url: URL,
        reconnectPolicy: ReconnectPolicy = .exponentialBackoff(
            initial: 1, max: 30, maxAttempts: nil),
        interceptors: [any HTTPInterceptor] = []
    ) {
        self.init(
            url: url, reconnectPolicy: reconnectPolicy, transport: URLSessionWebSocketTransport(),
            interceptors: interceptors)
    }

    internal init(
        url: URL,
        reconnectPolicy: ReconnectPolicy,
        transport: any WebSocketTransport,
        interceptors: [any HTTPInterceptor] = [],
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.url = url
        self.reconnectPolicy = reconnectPolicy
        self.transport = transport
        self.interceptors = interceptors
        self.sleep = sleep
        self.state = CurrentValueDistinct(.disconnected)
    }

    /// Starts one connection attempt; repeated calls are idempotent while active.
    /// Ownership: actor owns connection tasks. Isolation: actor. Errors: failures enter reconnect policy/state. Cancellation: disconnect cancels this attempt.
    public func connect() {
        guard
            explicitDisconnect || (connection == nil && connectTask == nil && reconnectTask == nil)
        else { return }
        explicitDisconnect = false
        generation &+= 1
        let expected = generation
        connectTask = Task { [weak self] in
            guard let self else { return }
            await self.open(expectedGeneration: expected)
        }
    }

    /// Sends one message on the current connection.
    /// Ownership: connection copies payload. Isolation: actor. Errors: throws `notConnected` or typed transport failure. Cancellation: propagates.
    public func send(_ message: WSMessage) async throws {
        guard let connection else { throw WebSocketError.notConnected }
        do { try await connection.send(message) } catch is CancellationError {
            throw CancellationError()
        } catch { throw WebSocketError.transport(String(describing: error)) }
    }

    /// Explicitly closes the socket and cancels reconnect attempts.
    /// Ownership: actor releases owned tasks. Isolation: actor. Errors: none. Cancellation: all pending connection work is cancelled.
    public func disconnect() async {
        explicitDisconnect = true
        generation &+= 1
        connectTask?.cancel(); connectTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        receiveTask?.cancel(); receiveTask = nil
        await connection?.close()
        connection = nil
        await state.set(.disconnected)
    }

    private func open(expectedGeneration: UInt64) async {
        defer { connectTask = nil }
        guard expectedGeneration == generation, !explicitDisconnect else { return }
        await state.set(connection == nil ? .connecting : .reconnecting(attempt: 1))
        do {
            let request = try await handshakeRequest()
            let opened = try await transport.connect(url: request.url, headers: request.headers)
            guard expectedGeneration == generation, !explicitDisconnect else {
                await opened.close(); return
            }
            connection = opened
            await state.set(.connected)
            receiveTask = Task { [weak self] in
                guard let self else { return }
                await self.receive(from: opened, generation: expectedGeneration)
            }
        } catch is CancellationError {
        } catch {
            await failure(generation: expectedGeneration)
        }
    }

    private func receive(from connection: any WebSocketConnection, generation expected: UInt64)
        async
    {
        do {
            for try await message in connection.incoming {
                guard expected == generation, !explicitDisconnect else { return }
                messagesPipe.send(message)
            }
            await failure(generation: expected)
        } catch is CancellationError {
        } catch {
            await failure(generation: expected)
        }
    }

    private func failure(generation expected: UInt64) async {
        guard expected == generation, !explicitDisconnect else { return }
        self.connection = nil
        receiveTask = nil
        var attempt = 1
        while expected == generation, !explicitDisconnect, reconnectPolicy.allows(attempt: attempt)
        {
            await state.set(.reconnecting(attempt: attempt))
            do { try await sleep(reconnectPolicy.delay(for: attempt)) } catch { return }
            guard expected == generation, !explicitDisconnect else { return }
            do {
                let request = try await handshakeRequest()
                let opened = try await transport.connect(url: request.url, headers: request.headers)
                guard expected == generation, !explicitDisconnect else {
                    await opened.close(); return
                }
                connection = opened
                await state.set(.connected)
                receiveTask = Task { [weak self] in
                    guard let self else { return }
                    await self.receive(from: opened, generation: expected)
                }
                return
            } catch is CancellationError { return } catch { attempt += 1 }
        }
        if expected == generation, !explicitDisconnect {
            await state.set(.failed("reconnect exhausted"))
        }
    }

    private func handshakeRequest() async throws -> HTTPRequest {
        var request = HTTPRequest(method: .get, url: url)
        for interceptor in interceptors { request = try await interceptor.intercept(request) }
        return request
    }
}
