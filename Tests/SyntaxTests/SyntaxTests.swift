import Foundation
import Testing
import Syntax
import Weave
import Flux

@Test
@MainActor
func namedAndOperatorForwardingAreEquivalent() async {
    let value = 3 |> { $0 * 2 } |> { $0 + 1 }
    #expect(value == forwardApply(forwardApply(3, { $0 * 2 }), { $0 + 1 }))

    let scope = ConnectionScope()
    let target = BindingTarget<Int>(id: "state", owner: scope) { value in
        _ = value
    }
    let named = bind(Flux.just(4), to: target)
    named.cancel()
    let operatorSubscription = Flux.just(5) ~> target
    operatorSubscription.cancel()
    let reverseSubscription = target <~ Flux.just(6)
    reverseSubscription.cancel()
    let namedForward = forward(Flux.just(7), to: target)
    namedForward.cancel()
}

@Test
@MainActor
func targetOwnerCancelsAllSyntaxBindings() async {
    let scope = ConnectionScope()
    let target = BindingTarget<Int>(id: "state", owner: scope) { _ in }
    let subscription = Flux.from([1, 2, 3]) ~> target
    #expect(scope.isCancelled == false)
    scope.cancelAll()
    #expect(scope.isCancelled)
    #expect(subscription.id != UUID())
}
