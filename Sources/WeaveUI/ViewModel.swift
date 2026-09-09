import Foundation

public import Flux

/// Complete renderable state for a screen with explicit loading, empty, content and error cases.
/// Ownership: the state value is copied by its owner. Isolation: none. Errors: the error message is a typed state value. Cancellation: loading cancellation is managed by the owning effect scope.
public enum ScreenState<Content: Sendable & Equatable>: Sendable, Equatable {
    case loading
    case empty
    case content(Content)
    case error(String)
}

/// Actor-compatible screen state machine contract.
/// Ownership: the conformer owns state and output streams. Isolation: state/output are Sendable snapshots; `send` may be actor isolated. Errors: failures are represented by state or typed output. Cancellation: `send` observes caller cancellation and screen scope cancellation.
public protocol ViewModel: Sendable {
    associatedtype State: Sendable & Equatable
    associatedtype Intent: Sendable
    associatedtype Output: Sendable

    /// Actor-owned state storage published as a Flux snapshot.
    nonisolated var state: CurrentValueDistinct<State> { get }
    /// Bounded or finite outputs leaving the screen boundary.
    nonisolated var outputs: Flux<Output> { get }
    /// Handles one user or system intent in actor order.
    func send(_ intent: Intent) async
}

/// Stable identity for a controller connection or screen-scoped effect.
/// Ownership: the identifier is copied by the scope. Isolation: none. Errors: empty values are allowed but discouraged. Cancellation: matching identities replace and cancel prior work.
public struct ControllerConnectionID: Sendable, Hashable, ExpressibleByStringLiteral {
    public let rawValue: String

    /// Creates a stable connection identity.
    /// Ownership: the string is copied. Isolation: none. Errors: none. Cancellation: matching IDs replace prior work.
    public init(_ rawValue: String) { self.rawValue = rawValue }

    /// Creates an identity from a string literal.
    /// Ownership: the literal is copied. Isolation: none. Errors: none. Cancellation: matching IDs replace prior work.
    public init(stringLiteral value: String) { self.init(value) }
}
