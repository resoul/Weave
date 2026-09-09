import Foundation
import Testing
import Networking

private struct FakeTransport: HTTPTransport {
    let result: HTTPResult

    func send(_ request: HTTPRequest) async throws -> HTTPResult { result }
}

private actor AttemptRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor RequestRecorder {
    private(set) var headers: [String: String] = [:]
    func record(_ request: HTTPRequest) { headers = request.headers }
}

private struct RecordingTransport: HTTPTransport {
    let recorder: RequestRecorder

    func send(_ request: HTTPRequest) async throws -> HTTPResult {
        await recorder.record(request)
        return HTTPResult(statusCode: 204)
    }
}

private struct CancellationTransport: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResult {
        try await Task.sleep(for: .seconds(3600))
        return HTTPResult(statusCode: 204)
    }
}

private struct RetryingTransport: HTTPTransport {
    let recorder: AttemptRecorder

    func send(_ request: HTTPRequest) async throws -> HTTPResult {
        await recorder.record()
        if await recorder.count < 3 {
            return HTTPResult(statusCode: 503, data: Data("busy".utf8))
        }
        return HTTPResult(statusCode: 204)
    }
}

private struct HeaderInterceptor: HTTPInterceptor {
    func intercept(_ request: HTTPRequest) async throws -> HTTPRequest {
        var request = request
        request.headers["X-Test"] = "intercepted"
        return request
    }
}

private struct DependentHeaderInterceptor: HTTPInterceptor {
    let key: String
    let dependency: String?

    func intercept(_ request: HTTPRequest) async throws -> HTTPRequest {
        var request = request
        request.headers[key] = dependency.map { request.headers[$0] ?? "missing" } ?? "first"
        return request
    }
}

@Test
func httpClientMapsSuccessfulResponseAndRunsInterceptors() async throws {
    let payload = Data(#"{"value":42}"#.utf8)
    let transport = FakeTransport(result: HTTPResult(statusCode: 200, data: payload))
    let client = HTTPClient(transport: transport, interceptors: [HeaderInterceptor()])
    let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)

    struct Payload: Decodable, Sendable, Equatable { let value: Int }
    #expect(try await client.send(request, decode: Payload.self) == Payload(value: 42))
}

@Test
func httpClientRunsRequestInterceptorsInDeclarationOrder() async throws {
    let recorder = RequestRecorder()
    let client = HTTPClient(
        transport: RecordingTransport(recorder: recorder),
        interceptors: [
            DependentHeaderInterceptor(key: "A", dependency: nil),
            DependentHeaderInterceptor(key: "B", dependency: "A"),
        ]
    )
    let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)
    _ = try await client.send(request)

    #expect(await recorder.headers["A"] == "first")
    #expect(await recorder.headers["B"] == "first")
}

@Test
func httpClientMapsUnsuccessfulStatusToTypedError() async {
    let client = HTTPClient(
        transport: FakeTransport(result: HTTPResult(statusCode: 503, data: Data("busy".utf8)))
    )
    let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)

    do {
        _ = try await client.send(request)
        Issue.record("Expected an unacceptable status error")
    } catch let error as HTTPError {
        #expect(error == .unacceptableStatus(code: 503, body: Data("busy".utf8)))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func httpClientRetriesOnlyIdempotentMethods() async throws {
    let recorder = AttemptRecorder()
    let client = HTTPClient(
        transport: RetryingTransport(recorder: recorder),
        retryPolicy: .fixed(delay: .zero, maxAttempts: 3)
    )
    let get = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)
    _ = try await client.send(get)
    #expect(await recorder.count == 3)

    let postRecorder = AttemptRecorder()
    let postClient = HTTPClient(
        transport: RetryingTransport(recorder: postRecorder),
        retryPolicy: .fixed(delay: .zero, maxAttempts: 3)
    )
    let post = HTTPRequest(method: .post, url: URL(string: "https://example.com")!)
    do {
        _ = try await postClient.send(post)
        Issue.record("Expected POST to fail without an implicit retry")
    } catch let error as HTTPError {
        #expect(error == .unacceptableStatus(code: 503, body: Data("busy".utf8)))
    }
    #expect(await postRecorder.count == 1)
}

@Test
func httpClientReportsMalformedJSONAsDecodingError() async {
    let client = HTTPClient(
        transport: FakeTransport(result: HTTPResult(statusCode: 200, data: Data("nope".utf8)))
    )
    let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)

    do {
        struct Payload: Decodable, Sendable { let value: Int }
        _ = try await client.send(request, decode: Payload.self)
        Issue.record("Expected malformed JSON to fail")
    } catch let error as HTTPError {
        guard case .decoding = error else {
            Issue.record("Expected a decoding error")
            return
        }
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@Test
func httpClientPropagatesTaskCancellation() async {
    let client = HTTPClient(transport: CancellationTransport())
    let request = HTTPRequest(method: .get, url: URL(string: "https://example.com")!)
    let task = Task { try await client.send(request) }
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        #expect(Bool(true))
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
