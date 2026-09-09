import Foundation
import Analytics
import Testing

private actor RecordingSink: AnalyticsSink {
    let id = UUID()
    var batches: [[AnalyticsEvent]] = []
    var failures = 0
    let failCount: Int

    init(failCount: Int = 0) { self.failCount = failCount }

    func send(_ batch: [AnalyticsEvent]) async throws {
        if failures < failCount {
            failures += 1
            throw TestError.failed
        }
        batches.append(batch)
    }
}

private enum TestError: Error { case failed }

@Test
func deniedConsentDoesNotPublishOrAccumulate() async {
    let client = AnalyticsClient(policy: AnalyticsPrivacyPolicy(allowedProperties: ["ok"]))
    let subscription = client.stream.sink { _ in Issue.record("denied event published") }
    await client.track(AnalyticsEvent(name: "ignored", properties: ["ok": .string("x")]))
    await client.setConsent(.granted)
    await client.flush()
    subscription.cancel()
}

@Test
func privacyPolicySanitizesBeforeStream() async {
    let client = AnalyticsClient(
        consent: .granted,
        policy: AnalyticsPrivacyPolicy(allowedProperties: ["ok", "password"]),
        batchSize: 10)
    let values = LockedEvents()
    let subscription = client.stream.sink { values.append($0) }
    await client.track(
        AnalyticsEvent(
            name: "login",
            properties: [
                "ok": .string("yes"), "password": .string("secret"), "extra": .string("drop"),
            ]))
    for _ in 0..<20 { await Task.yield() }
    subscription.cancel()
    let event = values.items.first
    #expect(event?.properties["ok"] == .string("yes"))
    #expect(event?.properties["password"] == .string("[REDACTED]"))
    #expect(event?.properties["extra"] == nil)
}

@Test
func boundedRetryReportsFailureAndDoesNotLoop() async {
    let sink = RecordingSink(failCount: 10)
    let client = AnalyticsClient(consent: .granted, batchSize: 1, maxRetries: 2, sleep: { _ in })
    let failures = LockedFailures()
    let subscription = client.failures.sink { failures.append($0) }
    await client.attach(sink)
    await client.track(AnalyticsEvent(name: "event"))
    for _ in 0..<20 { await Task.yield() }
    subscription.cancel()
    #expect(failures.items.first?.attempts == 3)
    #expect(await sink.batches.isEmpty)
}

@Test
func successfulBatchFlushesAndDetaches() async {
    let sink = RecordingSink()
    let client = AnalyticsClient(consent: .granted, batchSize: 2)
    await client.attach(sink)
    await client.track(AnalyticsEvent(name: "one"))
    await client.track(AnalyticsEvent(name: "two"))
    #expect(await sink.batches.count == 1)
    await client.detach(sink)
    await client.finish()
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [AnalyticsEvent] = []
    func append(_ event: AnalyticsEvent) { lock.withLock { items.append(event) } }
}

private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var items: [AnalyticsFailure] = []
    func append(_ failure: AnalyticsFailure) { lock.withLock { items.append(failure) } }
}
