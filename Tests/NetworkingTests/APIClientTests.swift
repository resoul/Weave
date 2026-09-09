import Foundation
import Testing
@testable import Networking

private struct AuthInterceptor: HTTPInterceptor {
    func intercept(_ request: HTTPRequest) async throws -> HTTPRequest {
        var request = request
        request.headers["Authorization"] = "Bearer test"
        return request
    }
}

private actor RecordingHTTPTransport: HTTPTransport {
    private(set) var headers: [String: String] = [:]
    func send(_ request: HTTPRequest) async throws -> HTTPResult {
        headers = request.headers
        return HTTPResult(statusCode: 204)
    }
}

private actor IdleConnection: WebSocketConnection {
    let incoming: AsyncThrowingStream<WSMessage, Error>
    private let continuation: AsyncThrowingStream<WSMessage, Error>.Continuation

    init() {
        let pair = AsyncThrowingStream<WSMessage, Error>.makeStream()
        incoming = pair.stream
        continuation = pair.continuation
    }

    func send(_ message: WSMessage) async throws {}
    func close() async { continuation.finish() }
}

private actor RecordingWebSocketTransport: WebSocketTransport {
    private(set) var headers: [String: String] = [:]
    func connect(url: URL) async throws -> any WebSocketConnection { IdleConnection() }
    func connect(url: URL, headers: [String: String]) async throws -> any WebSocketConnection {
        self.headers = headers
        return IdleConnection()
    }
}

@Test
func apiClientSharesInterceptorsAcrossHTTPAndWebSocketHandshake() async throws {
    let httpTransport = RecordingHTTPTransport()
    let wsTransport = RecordingWebSocketTransport()
    let api = APIClient(
        baseURL: URL(string: "https://api.example.com/v1/")!,
        wsURL: URL(string: "wss://api.example.com/socket")!,
        sharedInterceptors: [AuthInterceptor()],
        httpTransport: httpTransport,
        wsTransport: wsTransport,
        sleep: { _ in })

    let request = try #require(api.request(method: .get, path: "users"))
    _ = try await api.http.send(request)
    await api.ws.connect()
    for _ in 0..<100 { await Task.yield() }
    #expect(await httpTransport.headers["Authorization"] == "Bearer test")
    #expect(await wsTransport.headers["Authorization"] == "Bearer test")
    await api.shutdown()
}

@Test
func apiClientResolvesRelativeRequestsAndShutdownIsIdempotent() async {
    let api = APIClient(
        baseURL: URL(string: "https://api.example.com/v1/")!,
        wsURL: URL(string: "wss://api.example.com/socket")!)
    #expect(
        api.request(method: .get, path: "users")?.url.absoluteString
            == "https://api.example.com/v1/users")
    #expect(api.request(method: .get, path: "://bad") == nil)
    await api.shutdown()
    await api.shutdown()
}
