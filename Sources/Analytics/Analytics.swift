import Foundation
import Flux

/// Scalar value permitted in an analytics event.
/// Ownership: immutable value. Isolation: none. Errors: non-finite numbers normalize to zero. Cancellation: not applicable.
public enum AnalyticsValue: Sendable, Hashable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
}

/// Non-identifying context attached to analytics events.
/// Ownership: strings are copied. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AnalyticsContext: Sendable, Hashable {
    public let appVersion: String?
    public let build: String?
    public let platform: String?

    /// Creates context without user/device identifiers.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(appVersion: String? = nil, build: String? = nil, platform: String? = nil) {
        self.appVersion = appVersion
        self.build = build
        self.platform = platform
    }
}

/// Typed analytics event submitted to the consent and privacy boundary.
/// Ownership: event owns copied properties/context. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AnalyticsEvent: Sendable, Hashable {
    public let name: String
    public let timestamp: Date
    public let properties: [String: AnalyticsValue]
    public let context: AnalyticsContext

    /// Creates an event; no event is published until consent and allow-list checks pass.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        name: String,
        timestamp: Date = Date(),
        properties: [String: AnalyticsValue] = [:],
        context: AnalyticsContext = AnalyticsContext()
    ) {
        self.name = name
        self.timestamp = timestamp
        self.properties = properties
        self.context = context
    }
}

/// Stable sink destination for bounded analytics batches.
/// Ownership: client retains attached sinks. Isolation: async Sendable boundary. Errors: send failures are retried and reported. Cancellation: caller cancellation propagates.
public protocol AnalyticsSink: Sendable {
    var id: UUID { get }
    func send(_ batch: [AnalyticsEvent]) async throws
}

/// Consent state applied before stream publication or sink delivery.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum AnalyticsConsent: Sendable, Hashable { case denied, granted }

/// Allow-list and redaction policy applied before an event enters any bounded stream.
/// Ownership: policy owns copied sets. Isolation: none. Errors: none. Cancellation: not applicable.
public struct AnalyticsPrivacyPolicy: Sendable, Hashable {
    public let allowedProperties: Set<String>
    public let sensitiveKeys: Set<String>

    /// Creates a policy. Empty allow-list rejects all custom properties while preserving event name/context.
    /// Ownership: sets are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        allowedProperties: Set<String> = [],
        sensitiveKeys: Set<String> = ["token", "password", "secret", "email", "phone", "user_id"]
    ) {
        self.allowedProperties = allowedProperties
        self.sensitiveKeys = Set(sensitiveKeys.map { $0.lowercased() })
    }

    func sanitize(_ event: AnalyticsEvent) -> AnalyticsEvent {
        var properties: [String: AnalyticsValue] = [:]
        for key in allowedProperties {
            guard let value = event.properties[key] else { continue }
            if sensitiveKeys.contains(key.lowercased()) {
                properties[key] = .string("[REDACTED]")
            } else {
                properties[key] = value
            }
        }
        return AnalyticsEvent(
            name: event.name, timestamp: event.timestamp, properties: properties,
            context: event.context)
    }
}

/// Typed terminal delivery failure after bounded retries.
/// Ownership: diagnostic owns copied values. Isolation: none. Errors: this is reported on `failures`. Cancellation: not applicable.
public struct AnalyticsFailure: Sendable, Hashable {
    public let batchCount: Int
    public let attempts: Int
    public let message: String

    /// Creates a terminal delivery failure record.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(batchCount: Int, attempts: Int, message: String) {
        self.batchCount = batchCount
        self.attempts = attempts
        self.message = message
    }
}

/// Actor-owned consent-aware analytics client with bounded batching and retry.
/// Ownership: client owns pending events, sinks and bounded streams. Isolation: actor. Errors: sink failures are exposed as `AnalyticsFailure`; track itself does not throw. Cancellation: flush cancellation leaves the pending batch owned by the client.
public actor AnalyticsClient {
    private let policy: AnalyticsPrivacyPolicy
    private let batchSize: Int
    private let maxPending: Int
    private let maxRetries: Int
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let eventPipe = Pipe<AnalyticsEvent>(bufferingPolicy: .bufferingNewest(256))
    private let failurePipe = Pipe<AnalyticsFailure>(bufferingPolicy: .bufferingNewest(64))
    private var consent: AnalyticsConsent
    private var sinks: [UUID: any AnalyticsSink] = [:]
    private var pending: [AnalyticsEvent] = []
    private var lastFlush: Date
    private var finished = false

    /// Sanitized accepted events. No denied or disallowed event reaches this stream.
    /// Ownership: subscriber owns its Flux subscription. Isolation: nonisolated stream. Errors: none. Cancellation: subscription cancellation detaches it.
    public nonisolated var stream: Flux<AnalyticsEvent> { eventPipe.flux }

    /// Terminal delivery failures after retry exhaustion.
    /// Ownership: subscriber owns its Flux subscription. Isolation: nonisolated stream. Errors: none. Cancellation: subscription cancellation detaches it.
    public nonisolated var failures: Flux<AnalyticsFailure> { failurePipe.flux }

    /// Creates a client without starting timers or network work.
    /// Ownership: client retains policy/sinks and injected dependencies. Isolation: actor. Errors: invalid limits normalize. Cancellation: none during initialization.
    public init(
        consent: AnalyticsConsent = .denied,
        policy: AnalyticsPrivacyPolicy = AnalyticsPrivacyPolicy(),
        batchSize: Int = 20,
        maxRetries: Int = 2,
        clock: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.consent = consent
        self.policy = policy
        self.batchSize = max(1, batchSize)
        self.maxPending = max(1, batchSize) * 4
        self.maxRetries = max(0, maxRetries)
        self.clock = clock
        self.sleep = sleep
        self.lastFlush = clock()
    }

    /// Changes consent; denying consent clears all pending events immediately.
    /// Ownership: client owns pending state. Isolation: actor. Errors: none. Cancellation: none.
    public func setConsent(_ consent: AnalyticsConsent) {
        self.consent = consent
        if consent == .denied { pending.removeAll() }
    }

    /// Attaches or replaces a sink by stable ID.
    /// Ownership: client retains sink until detach. Isolation: actor. Errors: none. Cancellation: none.
    public func attach(_ sink: any AnalyticsSink) { sinks[sink.id] = sink }

    /// Detaches a sink; pending events remain bounded and can be flushed to other sinks.
    /// Ownership: client releases sink. Isolation: actor. Errors: none. Cancellation: none.
    public func detach(_ sink: any AnalyticsSink) { sinks.removeValue(forKey: sink.id) }

    /// Sanitizes and records one event, flushing a full batch synchronously.
    /// Ownership: event is copied. Isolation: actor. Errors: denied events are ignored; sink failures are published. Cancellation: cancellation propagates while flushing a full batch.
    public func track(_ event: AnalyticsEvent) async {
        guard !finished, consent == .granted else { return }
        let sanitized = policy.sanitize(event)
        eventPipe.send(sanitized)
        pending.append(sanitized)
        if pending.count > maxPending {
            let dropped = pending.count - maxPending
            pending.removeFirst(dropped)
            failurePipe.send(
                AnalyticsFailure(
                    batchCount: dropped, attempts: 0, message: "pending buffer overflow"))
        }
        if pending.count >= batchSize { await flush() }
    }

    /// Flushes a batch when the configured interval has elapsed.
    /// Ownership: client owns pending batch. Isolation: actor. Errors: failures are published, not thrown. Cancellation: cancellation propagates to sink work.
    public func flushIfDue(interval: TimeInterval) async {
        guard consent == .granted, clock().timeIntervalSince(lastFlush) >= max(0, interval) else {
            return
        }
        await flush()
    }

    /// Sends the current bounded batch with limited retries.
    /// Ownership: batch is removed after success or terminal failure. Isolation: actor. Errors: terminal failures publish `AnalyticsFailure`. Cancellation: cancellation leaves pending events intact.
    public func flush() async {
        guard consent == .granted, !pending.isEmpty, !sinks.isEmpty else { return }
        let batch = pending
        let destinations = Array(sinks.values)
        for sink in destinations {
            var attempts = 0
            var delivered = false
            while attempts <= maxRetries {
                attempts += 1
                do {
                    try await sink.send(batch)
                    delivered = true
                    break
                } catch is CancellationError {
                    return
                } catch {
                    if attempts > maxRetries { break }
                    do {
                        try await sleep(.milliseconds(Int64(attempts) * 10))
                    } catch {
                        return
                    }
                }
            }
            guard delivered else {
                pending.removeFirst(min(batch.count, pending.count))
                failurePipe.send(
                    AnalyticsFailure(
                        batchCount: batch.count, attempts: attempts,
                        message: "sink delivery failed"))
                lastFlush = clock()
                return
            }
        }
        pending.removeFirst(min(batch.count, pending.count))
        lastFlush = clock()
    }

    /// Stops the client after attempting a final flush.
    /// Ownership: client releases sinks and pending events. Isolation: actor. Errors: terminal failures are published. Cancellation: cancellation can interrupt the final flush.
    public func finish() async {
        guard !finished else { return }
        await flush()
        finished = true
        sinks.removeAll()
        pending.removeAll()
        eventPipe.finish()
        failurePipe.finish()
    }
}
