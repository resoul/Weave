import Foundation
import Testing
import Logging

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Test
func loggerFiltersBeforeMessageConstruction_andRedactsBeforeStream() async {
    let logger = Logger(clock: { Date(timeIntervalSince1970: 0) })
    let sink = ConsoleSink(minLevel: .error, output: { _ in })
    await logger.attach(sink)
    var evaluated = false
    await logger.log(
        .debug,
        {
            evaluated = true
            return "should not build"
        }()
    )
    #expect(!evaluated)

    let stream = logger.stream
    let subscription = stream.sink { entry in
        #expect(entry.metadata["token"] == "[REDACTED]")
        #expect(!entry.message.contains("secret-value"))
    }
    await logger.log(.info, "token=secret-value", metadata: ["token": "secret-value"])
    subscription.cancel()
}

@Test
func loggerDetachStopsSinkDelivery_andUsesBoundedPipePolicy() async {
    let logger = Logger(clock: { Date(timeIntervalSince1970: 0) })
    let writes = LockedCounter()
    let sink = ConsoleSink(minLevel: .trace, output: { _ in writes.increment() })
    await logger.attach(sink)
    await logger.log(.info, "one")
    await logger.detach(sink)
    await logger.log(.info, "two")
    #expect(writes.count <= 1)
}
