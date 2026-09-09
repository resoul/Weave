import Foundation

/// Shared HTTP and WebSocket facade for one service endpoint.
/// Ownership: the value owns HTTP and WebSocket clients. Isolation: Sendable value; WebSocket is actor-owned. Errors: underlying typed client errors propagate. Cancellation: shutdown cancels owned WebSocket work.
public struct APIClient: Sendable {
    public let http: HTTPClient
    public let ws: WebSocketClient
    public let baseURL: URL

    /// Creates both clients with one interceptor chain. Interceptors may read an actor-backed
    /// credential provider, so refreshed credentials apply to later HTTP requests and WS handshakes.
    /// Ownership: clients retain immutable interceptor references. Isolation: none. Errors: invalid endpoint values are reported by request construction. Cancellation: no work starts during init.
    public init(
        baseURL: URL,
        wsURL: URL,
        sharedInterceptors: [any HTTPInterceptor] = [],
        reconnectPolicy: ReconnectPolicy = .exponentialBackoff(
            initial: 1, max: 30, maxAttempts: nil)
    ) {
        self.baseURL = baseURL
        self.http = HTTPClient(interceptors: sharedInterceptors)
        self.ws = WebSocketClient(
            url: wsURL, reconnectPolicy: reconnectPolicy, interceptors: sharedInterceptors)
    }

    internal init(
        baseURL: URL,
        wsURL: URL,
        sharedInterceptors: [any HTTPInterceptor],
        httpTransport: any HTTPTransport,
        wsTransport: any WebSocketTransport,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.baseURL = baseURL
        self.http = HTTPClient(transport: httpTransport, interceptors: sharedInterceptors)
        self.ws = WebSocketClient(
            url: wsURL, reconnectPolicy: .none, transport: wsTransport,
            interceptors: sharedInterceptors, sleep: sleep)
    }

    /// Builds a request relative to `baseURL` without starting I/O.
    /// Ownership: returned request owns copied URL/path data. Isolation: none. Errors: malformed paths return nil. Cancellation: none.
    public func request(
        method: HTTPMethod,
        path: String,
        headers: [String: String] = [:],
        body: Data? = nil,
        query: [String: String] = [:]
    ) -> HTTPRequest? {
        guard !path.contains("://") else { return nil }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return nil }
        return HTTPRequest(method: method, url: url, headers: headers, body: body, query: query)
    }

    /// Shuts down the shared WebSocket client and its reconnect work.
    /// Ownership: facade releases socket work. Isolation: async actor boundary. Errors: none. Cancellation: shutdown is terminal until the next explicit connect.
    public func shutdown() async { await ws.disconnect() }
}
