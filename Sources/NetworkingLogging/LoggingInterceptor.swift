import Foundation
import Logging
import Networking

private actor CorrelationState {
    private var starts: [String: Date] = [:]

    func begin(_ id: String, at date: Date) { starts[id] = date }
    func end(_ id: String, at date: Date) -> TimeInterval? {
        guard let start = starts.removeValue(forKey: id) else { return nil }
        return max(0, date.timeIntervalSince(start))
    }
}

/// Optional Networking-to-Logging integration interceptor.
/// Ownership: the interceptor retains Logger and correlation state. Isolation: async Sendable hooks.
/// Errors: hooks preserve request/response/error semantics. Cancellation: cancelled requests are logged only when an error hook is invoked.
public struct LoggingInterceptor: HTTPInterceptor, Sendable {
    private let logger: Logger
    private let logBody: Bool
    private let clock: @Sendable () -> Date
    private let state: CorrelationState

    /// Creates a redacting interceptor; request bodies are omitted by default.
    /// Ownership: dependencies are retained. Isolation: none. Errors: none. Cancellation: none during init.
    public init(
        logger: Logger = .shared,
        logBody: Bool = false,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.logger = logger
        self.logBody = logBody
        self.clock = clock
        self.state = CorrelationState()
    }

    /// Adds a correlation ID and logs a redacted request summary.
    /// Ownership: request is copied. Isolation: async. Errors: none from logging. Cancellation: interceptor cancellation propagates.
    public func intercept(_ request: HTTPRequest) async throws -> HTTPRequest {
        var request = request
        let correlation = request.headers["X-Weave-Correlation-ID"] ?? UUID().uuidString
        request.headers["X-Weave-Correlation-ID"] = correlation
        await state.begin(correlation, at: clock())
        await logger.log(
            .debug,
            "HTTP request \(request.method.rawValue.uppercased()) \(redactedURL(request.url, query: request.query))",
            category: "Network",
            metadata: metadata(
                correlation: correlation, headers: request.headers, body: request.body))
        return request
    }

    /// Logs a successful response and returns it unchanged.
    /// Ownership: result is returned unchanged. Isolation: async. Errors: none from logging. Cancellation: cancellation propagates.
    public func interceptResponse(_ result: HTTPResult, for request: HTTPRequest) async throws
        -> HTTPResult
    {
        let correlation = request.headers["X-Weave-Correlation-ID"] ?? "unknown"
        let duration = await state.end(correlation, at: clock())
        let durationText = duration.map { String(Int($0 * 1_000)) } ?? "unknown"
        await logger.log(
            .info,
            "HTTP response \(result.statusCode) correlation=\(correlation) duration_ms=\(durationText)",
            category: "Network",
            metadata: [
                "correlation": correlation,
                "status": String(result.statusCode),
                "duration_ms": durationText,
            ])
        return result
    }

    /// Logs a typed error and returns it unchanged.
    /// Ownership: error semantics are preserved. Isolation: async. Errors: none from logging. Cancellation: cancellation remains unchanged.
    public func interceptError(_ error: HTTPError, for request: HTTPRequest) async throws
        -> HTTPError
    {
        let correlation = request.headers["X-Weave-Correlation-ID"] ?? "unknown"
        let duration = await state.end(correlation, at: clock())
        let durationText = duration.map { String(Int($0 * 1_000)) } ?? "unknown"
        await logger.log(
            .error,
            "HTTP error \(errorSummary(error)) correlation=\(correlation) duration_ms=\(durationText)",
            category: "Network",
            metadata: [
                "correlation": correlation,
                "duration_ms": durationText,
            ])
        return error
    }

    private func errorSummary(_ error: HTTPError) -> String {
        switch error {
        case .invalidResponse:
            return "invalid_response"
        case let .unacceptableStatus(code, _):
            return "status_\(code)"
        case .transport:
            return "transport"
        case .decoding:
            return "decoding"
        }
    }

    private func metadata(correlation: String, headers: [String: String], body: Data?) -> [String:
        String]
    {
        var values = ["correlation": correlation]
        values["headers"] = redactedHeaders(headers)
        if logBody { values["body"] = body.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }
        return values
    }

    private func redactedHeaders(_ headers: [String: String]) -> String {
        headers.keys.sorted().map { key in
            let sensitive = ["authorization", "cookie", "token", "password", "secret"].contains {
                key.lowercased().contains($0)
            }
            return "\(key)=\(sensitive ? "[REDACTED]" : headers[key] ?? "")"
        }.joined(separator: ",")
    }

    private func redactedURL(_ url: URL, query: [String: String]) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let items =
            (components.queryItems ?? [])
            + query.keys.sorted().map {
                URLQueryItem(name: $0, value: query[$0])
            }
        components.queryItems = items.map { item in
            let sensitive = ["token", "password", "secret", "key", "authorization"].contains {
                item.name.lowercased().contains($0)
            }
            return URLQueryItem(name: item.name, value: sensitive ? "[REDACTED]" : item.value)
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}
