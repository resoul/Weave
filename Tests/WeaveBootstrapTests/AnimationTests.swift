import Testing
import Weave

@Test
@MainActor
func animationResolvesReduceMotionAndLogicalEdges() {
    let animation = Animation(duration: .seconds(1), curve: .easeIn, delay: .seconds(1))
    let reduced = animation.resolved(reduceMotion: true)
    #expect(reduced.duration == .zero)
    #expect(reduced.delay == .zero)
    #expect(TransitionEdge.leading.resolved(for: .leftToRight) == .left)
    #expect(TransitionEdge.leading.resolved(for: .rightToLeft) == .right)
}

@Test
@MainActor
func transitionSessionCompletesAndCancellationIsExactlyOnce() async {
    let session = TransitionSession()
    var outcomes: [TransitionOutcome] = []
    let started = session.start(
        animation: Animation(), apply: {}, completion: { outcomes.append($0) })
    #expect(started)
    await Task.yield()
    #expect(outcomes == [.completed])
    session.cancel()
    #expect(outcomes == [.completed])

    let cancelled = TransitionSession()
    var cancelledOutcomes: [TransitionOutcome] = []
    let cancellationStarted = cancelled.start(
        animation: Animation(duration: .seconds(1)), apply: {},
        completion: { cancelledOutcomes.append($0) })
    #expect(cancellationStarted)
    cancelled.cancel()
    #expect(cancelledOutcomes == [.cancelled])
    cancelled.cancel()
}
