import Foundation
import Logging
import Networking
import NetworkingLogging
import Testing

private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    var joined: String { lock.withLock { values.joined(separator: "\n") } }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }
    func set(_ value: Date) { lock.withLock { self.value = value } }
    func get() -> Date { lock.withLock { value } }
}

@Test
func loggingInterceptorRedactsHeadersAndOmitsBodyByDefault() async throws {
    let output = LockedStrings()
    let logger = Logger(clock: { Date(timeIntervalSince1970: 0) })
    let subscription = logger.stream.sink { entry in
        output.append("\(entry.message) \(entry.metadata)")
    }
    let interceptor = LoggingInterceptor(logger: logger, clock: { Date(timeIntervalSince1970: 1) })
    let request = HTTPRequest(
        method: .post,
        url: URL(string: "https://example.com?token=secret")!,
        headers: ["Authorization": "Bearer secret", "X-Test": "ok"],
        body: Data("password=secret".utf8))
    let intercepted = try await interceptor.intercept(request)
    _ = try await interceptor.interceptResponse(HTTPResult(statusCode: 201), for: intercepted)
    for _ in 0..<20 { await Task.yield() }
    let text = output.joined
    #expect(intercepted.headers["X-Weave-Correlation-ID"] != nil)
    #expect(text.contains("[REDACTED]"))
    #expect(!text.contains("Bearer secret"))
    #expect(!text.contains("password=secret"))
    #expect(text.contains("201"))
    subscription.cancel()
}

@Test
func loggingInterceptorPreservesErrorsAndLogsDurationCorrelation() async throws {
    let output = LockedStrings()
    let logger = Logger(clock: { Date(timeIntervalSince1970: 0) })
    let subscription = logger.stream.sink { entry in
        output.append("\(entry.message) \(entry.metadata)")
    }
    let now = LockedDate(Date(timeIntervalSince1970: 2))
    let interceptor = LoggingInterceptor(logger: logger, clock: { now.get() })
    let url = try #require(URL(string: "https://example.com"))
    let original = HTTPRequest(method: .get, url: url)
    let request = try await interceptor.intercept(original)
    now.set(Date(timeIntervalSince1970: 2.25))
    let error = HTTPError.transport("offline")
    #expect(try await interceptor.interceptError(error, for: request) == error)
    for _ in 0..<20 { await Task.yield() }
    #expect(output.joined.contains("duration_ms=250"))
    #expect(output.joined.contains("correlation="))
    subscription.cancel()
}
