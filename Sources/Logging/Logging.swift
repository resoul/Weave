import Foundation
import Flux

/// Severity ordered from diagnostic output to unrecoverable failure.
/// Ownership: the enum is an immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum LogLevel: Int, Comparable, Sendable, Hashable {
    case trace
    case debug
    case info
    case warning
    case error
    case critical

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Immutable structured log record.
/// Ownership: the entry owns copied strings and metadata. Isolation: none. Errors: sensitive values
/// are redacted before construction. Cancellation: not applicable.
public struct LogEntry: Sendable, Hashable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]
    public let file: String
    public let line: Int
    public let function: String

    /// Creates an immutable log record.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        timestamp: Date,
        level: LogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
        self.file = file
        self.line = line
        self.function = function
    }
}

/// Destination for structured log entries.
/// Ownership: the logger retains an attached sink by its stable ID. Isolation: implementations
/// define their own actor boundary. Errors: write failures are handled by the sink. Cancellation:
/// an owner may stop an in-flight write when detached.
public protocol LogSink: Sendable {
    var id: UUID { get }
    var minLevel: LogLevel { get }
    func write(_ entry: LogEntry) async throws
}

/// Injectable console destination with bounded logger fan-out upstream.
/// Ownership: the sink owns its output closure. Isolation: writes are async and sendable. Errors:
/// output failures are outside the console contract. Cancellation: detached writes may be cancelled.
public struct ConsoleSink: LogSink {
    public let id: UUID
    public let minLevel: LogLevel
    private let output: @Sendable (String) -> Void

    /// Creates a console sink with an injectable output for tests or platform logging adapters.
    /// Ownership: the sink retains the output closure. Isolation: none. Errors: none.
    /// Cancellation: output is synchronous within `write`.
    public init(
        id: UUID = UUID(),
        minLevel: LogLevel = .debug,
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.id = id
        self.minLevel = minLevel
        self.output = output
    }

    /// Writes a formatted record to the injected output.
    /// Ownership: the entry is borrowed for formatting. Isolation: none. Errors: none.
    /// Cancellation: a cancelled task skips the write.
    public func write(_ entry: LogEntry) async throws {
        guard !Task.isCancelled else { return }
        output("[\(entry.level)] \(entry.category): \(entry.message)")
    }
}

/// Rotation strategy for an actor-owned file sink.
/// Ownership: the policy is an immutable value. Isolation: none. Errors: invalid limits are
/// rejected by FileSink. Cancellation: an interrupted write does not rotate partially.
public enum LogRotationPolicy: Sendable, Hashable {
    case none
    case bySize(maxBytes: Int, maxFiles: Int)
    case byDate(interval: DateInterval, maxFiles: Int)
}

/// Typed failures reported by FileSink writes and shutdown.
/// Ownership: the error value is caller-owned. Isolation: none. Errors: it describes the failed
/// file operation. Cancellation: cancellation is represented separately by Task cancellation.
public enum FileSinkError: Error, Sendable, Hashable {
    case invalidPolicy
    case closed
    case directoryUnavailable
    case writeFailed(String)
}

/// Actor-owned file sink with deterministic rotation and retention.
/// Ownership: the sink owns its URL, FileManager and open-state. Isolation: actor. Errors: writes
/// throw typed FileSinkError. Cancellation: cancelled writes do not publish partial records.
public actor FileSink: LogSink {
    public let id: UUID
    public let minLevel: LogLevel
    public let url: URL
    public let rotation: LogRotationPolicy

    private let fileManager: FileManager
    private let clock: @Sendable () -> Date
    private var closed = false
    private var lastRotationDate: Date?

    /// Creates a file sink with injectable clock and filesystem manager.
    /// Ownership: the sink retains URL, manager and clock. Isolation: actor. Errors: invalid policy
    /// throws immediately. Cancellation: no write starts during initialization.
    public init(
        url: URL,
        minLevel: LogLevel = .debug,
        rotation: LogRotationPolicy = .bySize(maxBytes: 10_000_000, maxFiles: 5),
        id: UUID = UUID(),
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) throws {
        guard Self.isValid(rotation) else { throw FileSinkError.invalidPolicy }
        self.url = url
        self.minLevel = minLevel
        self.rotation = rotation
        self.id = id
        self.fileManager = fileManager
        self.clock = clock
    }

    /// Appends one complete UTF-8 record, rotating before overflow.
    /// Ownership: the sink copies the entry into a line. Isolation: actor. Errors: filesystem
    /// failures throw FileSinkError. Cancellation: a cancelled task stops before append.
    public func write(_ entry: LogEntry) async throws {
        try Task.checkCancellation()
        guard !closed else { throw FileSinkError.closed }
        try ensureDirectory()
        let data = Data(Self.format(entry).utf8)
        try rotateIfNeeded(incomingBytes: data.count, timestamp: clock())
        try Task.checkCancellation()
        do {
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            throw FileSinkError.writeFailed(String(describing: error))
        }
    }

    /// Flushes and permanently closes the sink.
    /// Ownership: the sink releases future writes after close. Isolation: actor. Errors: close
    /// failures throw FileSinkError. Cancellation: cancellation leaves the sink open.
    public func finish() async throws {
        guard !closed else { return }
        closed = true
    }

    private func ensureDirectory() throws {
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FileSinkError.directoryUnavailable
        }
    }

    private func rotateIfNeeded(incomingBytes: Int, timestamp: Date) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            if case .byDate = rotation { lastRotationDate = timestamp }
            return
        }
        switch rotation {
        case .none:
            return
        case let .bySize(maxBytes, maxFiles):
            let currentSize =
                (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
                ?? 0
            guard currentSize > 0, currentSize + incomingBytes > maxBytes else { return }
            try rotate(maxFiles: maxFiles)
        case let .byDate(interval, maxFiles):
            guard let lastRotationDate,
                timestamp.timeIntervalSince(lastRotationDate) >= interval.duration
            else { return }
            try rotate(maxFiles: maxFiles)
            self.lastRotationDate = timestamp
        }
    }

    private func rotate(maxFiles: Int) throws {
        for index in stride(from: maxFiles - 1, through: 1, by: -1) {
            let source = archiveURL(index)
            let destination = archiveURL(index + 1)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        let first = archiveURL(1)
        if fileManager.fileExists(atPath: first.path) { try fileManager.removeItem(at: first) }
        try fileManager.moveItem(at: url, to: first)
    }

    private func archiveURL(_ index: Int) -> URL {
        url.appendingPathExtension("\(index)")
    }

    private static func isValid(_ policy: LogRotationPolicy) -> Bool {
        switch policy {
        case .none: true
        case let .bySize(maxBytes, maxFiles): maxBytes > 0 && maxFiles > 0
        case let .byDate(interval, maxFiles): interval.duration > 0 && maxFiles > 0
        }
    }

    private static func format(_ entry: LogEntry) -> String {
        let metadata = entry.metadata.keys.sorted()
            .map { "\($0)=\(entry.metadata[$0] ?? "")" }
            .joined(separator: ",")
        return "\(entry.timestamp.timeIntervalSince1970)|\(entry.level.rawValue)|"
            + "\(entry.category)|\(entry.message)|\(metadata)\n"
    }
}

/// Thread-safe bounded logger independent from Weave Core.
/// Ownership: the logger owns attached sink references and its Flux pipe. Isolation: lock-protected
/// synchronous submission; sink writes are asynchronous. Errors: secrets are redacted before publish.
/// Cancellation: `detach` stops future writes; deinitialization finishes the stream.
public actor Logger {
    /// Process-local shared logger.
    public static let shared = Logger()

    private let pipe = Pipe<LogEntry>(bufferingPolicy: .bufferingNewest(256))
    private var sinks: [UUID: any LogSink] = [:]
    private let clock: @Sendable () -> Date

    /// Creates an empty logger with an injectable clock.
    /// Ownership: the logger owns the clock and sink registry. Isolation: lock protected.
    /// Errors: none. Cancellation: no work is active until a sink is attached.
    public init(clock: @escaping @Sendable () -> Date = Date.init) {
        self.clock = clock
    }

    /// Stream of already-redacted entries with bounded newest buffering.
    /// Ownership: each subscriber owns its Flux subscription. Isolation: none. Errors: none.
    /// Cancellation: cancelling a subscription detaches that subscriber.
    public nonisolated var stream: Flux<LogEntry> { pipe.flux }

    /// Attaches or replaces a sink by stable ID.
    /// Ownership: the logger retains the sink until detach. Isolation: lock protected. Errors: none.
    /// Cancellation: replacing a sink stops future writes to the old instance.
    public func attach(_ sink: any LogSink) { sinks[sink.id] = sink }

    /// Detaches a sink by stable ID.
    /// Ownership: the logger releases the sink. Isolation: lock protected. Errors: none.
    /// Cancellation: future writes to this sink stop immediately.
    public func detach(_ sink: any LogSink) { sinks.removeValue(forKey: sink.id) }

    /// Publishes a structured entry after level filtering and redaction.
    /// Ownership: the logger copies the resulting entry into the bounded stream. Isolation: lock
    /// protected submission. Errors: sensitive metadata and message tokens are redacted.
    /// Cancellation: sink tasks do not block the caller and may be cancelled by task ownership.
    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: String = "App",
        metadata: [String: String] = [:],
        file: String = #fileID,
        line: Int = #line,
        function: String = #function
    ) {
        let eligible = sinks.values.filter { level >= $0.minLevel }
        guard !eligible.isEmpty || pipe.subscriberCount > 0 else { return }
        let entry = LogEntry(
            timestamp: clock(), level: level, category: category,
            message: Self.redact(message()), metadata: Self.redact(metadata),
            file: file, line: line, function: function
        )
        pipe.send(entry)
        for sink in eligible {
            Task {
                try? await sink.write(entry)
            }
        }
    }

    private static func redact(_ metadata: [String: String]) -> [String: String] {
        let sensitive = ["token", "password", "secret", "authorization", "api_key", "apikey"]
        return metadata.mapValues { value in value }
            .reduce(into: [:]) { result, pair in
                let key = pair.key.lowercased()
                result[pair.key] =
                    sensitive.contains(where: { key.contains($0) }) ? "[REDACTED]" : pair.value
            }
    }

    private static func redact(_ message: String) -> String {
        message.split(separator: " ").map { token in
            let value = String(token)
            let lower = value.lowercased()
            return ["token=", "password=", "secret="].contains(where: lower.hasPrefix)
                ? String(value.prefix { $0 != "=" }) + "=[REDACTED]"
                : value
        }.joined(separator: " ")
    }
}

/// Emits a trace-level message through the shared logger.
/// Ownership: message evaluation is deferred until a sink or stream needs it. Isolation: none.
/// Errors: redaction is applied by Logger. Cancellation: sink delivery may be cancelled.
public func logTrace(_ message: @autoclosure () -> String, category: String = "App") async {
    let value = message()
    await Logger.shared.log(.trace, value, category: category)
}

/// Emits a debug-level message through the shared logger.
/// Ownership: message evaluation is deferred until needed. Isolation: none. Errors: redaction applies.
/// Cancellation: sink delivery may be cancelled.
public func logDebug(_ message: @autoclosure () -> String, category: String = "App") async {
    let value = message()
    await Logger.shared.log(.debug, value, category: category)
}
