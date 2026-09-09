import Foundation
import Testing
@testable import Networking

private actor FakeConnection: WebSocketConnection {
    let incoming: AsyncThrowingStream<WSMessage, Error>
    private let continuation: AsyncThrowingStream<WSMessage, Error>.Continuation
    private(set) var sent: [WSMessage] = []
    private(set) var closed = false

    init() {
        let pair = AsyncThrowingStream<WSMessage, Error>.makeStream(
            bufferingPolicy: .bufferingNewest(256))
        incoming = pair.stream
        continuation = pair.continuation
    }

    func send(_ message: WSMessage) async throws { sent.append(message) }
    func close() async { closed = true; continuation.finish() }
    func emit(_ message: WSMessage) { continuation.yield(message) }
}

private actor FakeTransport: WebSocketTransport {
    private(set) var connectCount = 0
    private var failuresRemaining: Int
    private(set) var latest: FakeConnection?

    init(failuresRemaining: Int = 0) { self.failuresRemaining = failuresRemaining }

    func connect(url: URL) async throws -> any WebSocketConnection {
        connectCount += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw WebSocketError.transport("offline")
        }
        let connection = FakeConnection()
        latest = connection
        return connection
    }
}

private actor DelayRecorder {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }
}

@Test
func websocketRepeatedConnectUsesOneSocketAndDeliversMessages() async throws {
    let transport = FakeTransport()
    let client = WebSocketClient(
        url: URL(string: "wss://example.com")!,
        reconnectPolicy: .none,
        transport: transport,
        sleep: { _ in })
    await client.connect()
    await client.connect()
    for _ in 0..<100 {
        if await client.state.value == .connected { break }
        await Task.yield()
    }
    #expect(await transport.connectCount == 1)

    let connection = await transport.latest
    try await client.send(.data(Data([1, 2])))
    #expect(await connection?.sent == [.data(Data([1, 2]))])
    await client.disconnect()
    #expect(await client.state.value == .disconnected)
}

@Test
func websocketReconnectUsesBoundedExponentialBackoff() async throws {
    let transport = FakeTransport(failuresRemaining: 2)
    let delays = DelayRecorder()
    let client = WebSocketClient(
        url: URL(string: "wss://example.com")!,
        reconnectPolicy: .exponentialBackoff(initial: 1, max: 8, maxAttempts: 3),
        transport: transport,
        sleep: { delay in await delays.record(delay) })
    await client.connect()
    for _ in 0..<1_000 {
        if await transport.connectCount == 3 { break }
        await Task.yield()
    }
    #expect(await transport.connectCount == 3)
    #expect(await delays.delays == [.seconds(1), .seconds(2)])
    #expect(await client.state.value == .connected)
    await client.disconnect()
}

@Test
func websocketDisconnectCancelsReconnectAndSendReportsNotConnected() async {
    let transport = FakeTransport(failuresRemaining: 10)
    let client = WebSocketClient(
        url: URL(string: "wss://example.com")!,
        reconnectPolicy: .fixed(interval: 10, maxAttempts: nil),
        transport: transport,
        sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    await client.connect()
    for _ in 0..<6 { await Task.yield() }
    await client.disconnect()
    let attempts = await transport.connectCount
    #expect(await client.state.value == .disconnected)
    do {
        try await client.send(.text("late"))
        Issue.record("Expected notConnected")
    } catch WebSocketError.notConnected {
        #expect(await transport.connectCount == attempts)
    } catch {
        Issue.record("Unexpected WebSocket error: \(error)")
    }
}
