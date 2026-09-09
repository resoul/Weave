# Optional Integrations

> Modular services: `Logging`, `Networking`, `Storage`, `Analytics`, and sensory feedback.  
> Each integration is packaged as an **independent target** and does not depend on `WeaveCore`.

---

## Architectural Boundaries

```
┌────────────────────────────────────────────────────────────────────────┐
│                        App Feature / ViewModel                         │
└───────────────┬────────────────────────────────────────┬───────────────┘
                │                                        │
                ▼                                        ▼
┌───────────────────────────────┐        ┌───────────────────────────────┐
│     WeaveCore / Facade        │        │   WeaveServices & Targets     │
│  (Node, Controller, Layout)   │        │ ┌───────────────────────────┐ │
│                               │        │ │ WeaveLogging              │ │
│  Injected via Environment     │◄───────┼─┤ WeaveNetworking           │ │
│  or Controller Factory        │        │ │ WeaveStorage              │ │
│                               │        │ │ WeaveAnalytics            │ │
│                               │        │ └───────────────────────────┘ │
└───────────────────────────────┘        └───────────────────────────────┘
```

### Key Principles
1. **Zero Core Dependencies**: `WeaveCore` has no knowledge of `URLSession`, `Security.framework`, `os_log`, or third-party SDKs.
2. **Protocol-Driven**: Features bind to abstract protocols (`Store`, `LogSink`, `AnalyticsSink`, `HapticsClient`).
3. **Reactive Fan-Out**: Sinks and observers subscribe via standard `Flux` streams and `Pipe` without introducing secondary reactive runtimes.
4. **Environment Injection**: Services are propagated via `Environment` (`environment.services`) or injected directly into ViewModels.

---

## 1. Logging (`WeaveLogging`)

Reactive, structured logging. The core `Logger` is a lightweight producer over a `Pipe<LogEntry>`.

```swift
public enum LogLevel: Int, Comparable, Sendable {
    case trace, debug, info, warning, error, critical
}

public struct LogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]
    public let file: String
    public let line: Int
    public let function: String
}

public protocol LogSink: Sendable {
    var minLevel: LogLevel { get }
    func write(_ entry: LogEntry) async
}
```

### Logger Engine

```swift
public final class Logger: Sendable {
    public static let shared = Logger()

    private let pipe = Pipe<LogEntry>(bufferingPolicy: .bufferingNewest(256))
    
    /// Stream of all log entries for debug overlays and diagnostics
    public var stream: Flux<LogEntry> { pipe.flux }

    public func attach(_ sink: any LogSink)
    public func detach(_ sink: any LogSink)

    public func log(
        _ level: LogLevel,
        _ message: @autoclosure () -> String,
        category: String = "App",
        metadata: [String: String] = [:],
        file: String = #file, line: Int = #line, function: String = #function
    )
}
```

- `@autoclosure` ensures message formatting is skipped if sinks filter out the log level.
- **Built-in Sinks**:
  - `ConsoleSink`: Outputs to `os_log` on Apple platforms, fallback to `print`.
  - `FileSink`: Actor-isolated disk logger with rotation (`LogRotationPolicy.bySize(maxBytes:maxFiles:)`).

---

## 2. Networking (`WeaveNetworking`)

A platform-neutral networking client built over `URLSession`.

```swift
public enum HTTPMethod: String, Sendable { case get, post, put, patch, delete }

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var url: URL
    public var headers: [String: String] = [:]
    public var body: Data? = nil
    public var query: [String: String] = [:]
}

public struct HTTPResult: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let data: Data
}

public protocol HTTPInterceptor: Sendable {
    func intercept(_ request: HTTPRequest) async throws -> HTTPRequest
}
```

### HTTP Client & Progress

```swift
public final class HTTPClient: Sendable {
    public init(session: URLSession = .shared, interceptors: [any HTTPInterceptor] = [])

    // Standard async/await paths
    public func send<T: Decodable & Sendable>(_ request: HTTPRequest, decode: T.Type) async throws -> T
    public func send(_ request: HTTPRequest) async throws -> HTTPResult

    // Reactive path with progress tracking
    public func send(_ request: HTTPRequest) -> Flux<HTTPProgress>
}

public enum HTTPProgress: Sendable {
    case uploadProgress(Double)
    case downloadProgress(Double)
    case completed(HTTPResult)
    case failed(Error)
}
```

### WebSocket

```swift
public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected, reconnecting(attempt: Int), failed(String)
}

public protocol WebSocketClient: Sendable {
    var state: CurrentValueDistinct<ConnectionState> { get }
    var incoming: Flux<WSMessage> { get }
    func send(_ message: WSMessage) async throws
    func disconnect() async
}
```

---

## 3. Storage (`WeaveStorage`)

Platform-neutral storage abstraction unified around the `Store` protocol.

```swift
public protocol Store: Sendable {
    func get<T: Codable & Sendable>(_ key: String, as type: T.Type) async throws -> T?
    func set<T: Codable & Sendable>(_ key: String, value: T) async throws
    func remove(_ key: String) async throws
    func removeAll() async throws
}
```

### Built-in Store Implementations

| Store | Purpose | Backing Store |
|---|---|---|
| `UserDefaultsStore` | User preferences and lightweight flags | `UserDefaults` |
| `FileCacheStore` | Large files, images, LRU cache | Disk directory (Actor) |
| `KeychainStore` | Auth tokens, keys, credentials | Apple Keychain Services |
| `MemoryStore` | Ephemeral caching and unit test stub | In-memory dictionary actor |

### Unified Cache with `ImageNode`
`ImageNode` in Weave renders images asynchronously off the main thread. Instead of maintaining a separate proprietary cache, its background rasterization pipeline leverages `FileCacheStore` with LRU eviction:

```swift
public actor FileCacheStore: Store {
    public init(directory: URL, evictionPolicy: CacheEvictionPolicy = .lru(maxBytes: 100_000_000))
    public func getData(_ key: String) async throws -> Data?
    public func setData(_ key: String, data: Data) async throws
}
```

### `Persisted<T>` Property Wrapper

```swift
@MainActor
public final class Persisted<T: Codable & Sendable & Equatable> {
    public init(key: String, store: any Store, default: T)
    public var value: T { get }
    public func update(_ newValue: T) async throws
    public var flux: Flux<T> { get }
}
```

---

## 4. Analytics, Telemetry & Feedback (`WeaveAnalytics`)

Platform-neutral telemetry, haptics, and audio feedback services.

### Analytics Pipeline

```swift
public struct AnalyticsEvent: Sendable {
    public var name: String
    public var timestamp: Date
    public var properties: [String: AnalyticsValue]
    public var context: AnalyticsContext
}

public protocol AnalyticsSink: Sendable {
    func send(_ batch: [AnalyticsEvent]) async throws
}

public final class AnalyticsClient: Sendable {
    public var stream: Flux<AnalyticsEvent> { get }
    public func track(_ event: AnalyticsEvent)
    public func attach(_ sink: any AnalyticsSink)
}
```

- PII redaction and allow-listing occur **before** events are sent into the client's internal `Pipe`.
- Batched delivery runs on background tasks with persistent retry queues.

### Sensory Feedback (Haptics & Sound)

Sensory feedback types express semantic intent rather than native platform objects:

```swift
public enum HapticFeedback: Sendable {
    case selection
    case impact(weight: ImpactWeight)
    case success
    case warning
    case error
}

public protocol HapticsClient: Sendable {
    @MainActor func play(_ feedback: HapticFeedback)
}

public protocol SoundClient: Sendable {
    @MainActor func play(_ sound: SoundFeedback)
}
```

- On platforms without physical vibration engines (macOS, tvOS), `HapticsClient` safely behaves as a no-op.
- Respects accessibility settings (`accessibilityReduceMotion`, audio volume) automatically via `Environment`.

---

## Dependency Injection in Features

Services are registered at application startup and accessed through `Environment` or passed explicitly to screen factories:

```swift
// In App startup
let services = ServiceRegistry(
    logger: Logger.shared,
    http: HTTPClient(),
    storage: FileCacheStore(directory: cacheDir),
    haptics: PlatformHapticsClient()
)

// Inside a Controller
override func connect(_ connections: ControllerConnections<Action, Route>) {
    let storage = environment.services.storage
    let haptics = environment.services.haptics

    connections.actions
        .sinkOnMain { action in
            if case .itemTapped = action {
                haptics.play(.selection)
            }
        }
        .store(in: connections.scope)
}
```
