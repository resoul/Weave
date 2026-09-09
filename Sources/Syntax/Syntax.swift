import WeaveUI
import Flux

/// Precedence for pure forward application.
/// Ownership: compiler metadata only. Isolation: none. Errors: type checking rejects mismatches. Cancellation: none.
precedencegroup ForwardApplicationPrecedence {
    associativity: left
    higherThan: TernaryPrecedence
}

/// Precedence for event forwarding.
/// Ownership: compiler metadata only. Isolation: none. Errors: type checking rejects mismatches. Cancellation: none.
precedencegroup WeaveAssignmentPrecedence {
    associativity: right
    higherThan: ForwardApplicationPrecedence
}

/// Opt-in pure forward application operator.
/// Ownership: the result is returned to the caller. Isolation: follows the function. Errors: function errors are not hidden. Cancellation: not applicable.
infix operator |> : ForwardApplicationPrecedence

/// Opt-in Flux-to-consumer forwarding operator.
/// Ownership: the returned subscription belongs to the explicit target owner. Isolation: MainActor at delivery. Errors: none. Cancellation: owner cancellation stops delivery.
infix operator <~ : WeaveAssignmentPrecedence

/// Applies a pure function to a value.
/// Ownership: the value and result are passed by value. Isolation: follows the function. Errors: function errors are not hidden. Cancellation: not applicable.
@inlinable
public func forwardApply<Input, Output>(_ value: Input, _ transform: (Input) -> Output) -> Output {
    transform(value)
}

/// Applies a pure function using the opt-in forward operator.
/// Ownership: the value and result are passed by value. Isolation: follows the function. Errors: function errors are not hidden. Cancellation: not applicable.
@inlinable
public func |> <Input, Output>(lhs: Input, rhs: (Input) -> Output) -> Output {
    forwardApply(lhs, rhs)
}

/// Explicit owner for a typed Flux binding or event forwarding operation.
/// Ownership: the target retains its owner and callback. Isolation: MainActor. Errors: type mismatches fail at compile time. Cancellation: owner cancellation terminates subscriptions.
@MainActor
public final class BindingTarget<Value: Sendable> {
    private let owner: ConnectionScope
    private let id: AnyHashable
    private let receiveValue: @MainActor @Sendable (Value) -> Void

    /// Creates a target with an explicit lifecycle owner and replacement identity.
    /// Ownership: the target retains the owner and callback. Isolation: MainActor. Errors: none. Cancellation: the owner controls termination.
    public init(
        id: some Hashable,
        owner: ConnectionScope,
        receive: @escaping @MainActor @Sendable (Value) -> Void
    ) {
        self.id = AnyHashable(id)
        self.owner = owner
        self.receiveValue = receive
    }

    /// Binds a Flux to this target and stores cancellation in the owner.
    /// Ownership: the owner retains the subscription cancellation. Isolation: MainActor registration and delivery. Errors: none. Cancellation: replacing the ID or cancelling the owner stops delivery.
    @discardableResult
    public func bind(_ source: Flux<Value>) -> Subscription {
        let subscription = source.sinkOnMain(receiveValue)
        subscription.store(in: ownerSubscriptions)
        owner.bind(id: id) { subscription.cancel() }
        return subscription
    }

    /// Forwards a Flux to this target using the named API.
    /// Ownership: the target owner retains cancellation. Isolation: MainActor. Errors: none. Cancellation: owner cancellation stops delivery.
    @discardableResult
    public func forward(_ source: Flux<Value>) -> Subscription { bind(source) }

    private let ownerSubscriptions = SubscriptionBag()
}

/// Named binding equivalent for consumers that do not import operators.
/// Ownership: the explicit target owns cancellation. Isolation: MainActor. Errors: none. Cancellation: owner cancellation stops delivery.
@MainActor
@discardableResult
public func bind<Value: Sendable>(_ source: Flux<Value>, to target: BindingTarget<Value>)
    -> Subscription
{
    target.bind(source)
}

/// Named event-forwarding equivalent for consumers that do not import operators.
/// Ownership: the explicit target owns cancellation. Isolation: MainActor. Errors: none. Cancellation: owner cancellation stops delivery.
@MainActor
@discardableResult
public func forward<Value: Sendable>(_ source: Flux<Value>, to target: BindingTarget<Value>)
    -> Subscription
{
    target.forward(source)
}

/// Binds a Flux to a target with the `~>` operator.
/// Ownership: the explicit target owns cancellation. Isolation: MainActor. Errors: none. Cancellation: owner cancellation stops delivery.
@MainActor
@discardableResult
public func ~> <Value: Sendable>(lhs: Flux<Value>, rhs: BindingTarget<Value>) -> Subscription {
    rhs.bind(lhs)
}

/// Forwards a Flux to a target with the `<~` operator.
/// Ownership: the explicit target owns cancellation. Isolation: MainActor. Errors: none. Cancellation: owner cancellation stops delivery.
@MainActor
@discardableResult
public func <~ <Value: Sendable>(lhs: BindingTarget<Value>, rhs: Flux<Value>) -> Subscription {
    lhs.forward(rhs)
}
