import Foundation
import Testing
import Weave

@MainActor
private final class EventRecorder {
    var phases: [String] = []
}

@MainActor
private class EventNode: Node {
    let name: String
    let recorder: EventRecorder

    init(name: String, recorder: EventRecorder) {
        self.name = name
        self.recorder = recorder
        super.init()
    }

    override func handleCapture(_ event: Event) {
        recorder.phases.append("capture:\(name)")
    }

    override func handleEvent(_ event: Event) {
        recorder.phases.append("target:\(name)")
    }

    override func handleBubble(_ event: Event) {
        recorder.phases.append("bubble:\(name)")
    }
}

@MainActor
private final class StoppingEventNode: EventNode {
    override func handleCapture(_ event: Event) {
        super.handleCapture(event)
        event.stopPropagation()
    }
}

@MainActor
private final class RemovingEventNode: EventNode {
    weak var nodeToRemove: Node?

    override func handleCapture(_ event: Event) {
        super.handleCapture(event)
        nodeToRemove?.removeFromSupernode()
    }
}

@Test
@MainActor
func eventDispatcherRunsCaptureTargetBubbleInOrder() {
    let recorder = EventRecorder()
    let root = EventNode(name: "root", recorder: recorder)
    let child = EventNode(name: "child", recorder: recorder)
    root.addSubnode(child)
    let event = Event(type: .pointerDown, targetID: child.id)

    let result = EventDispatcher().dispatch(event, target: child)

    #expect(recorder.phases == ["capture:root", "target:child", "bubble:root"])
    #expect(!result.propagationStopped)
    #expect(!result.defaultPrevented)
}

@Test
@MainActor
func eventDispatcherStopsLaterPhasesAndReportsDefaultCancellation() {
    let recorder = EventRecorder()
    let root = StoppingEventNode(name: "root", recorder: recorder)
    let child = EventNode(name: "child", recorder: recorder)
    root.addSubnode(child)
    let event = Event(type: .pointerDown, targetID: child.id)
    event.preventDefault()

    let result = EventDispatcher().dispatch(event, target: child)

    #expect(recorder.phases == ["capture:root"])
    #expect(result.propagationStopped)
    #expect(result.defaultPrevented)
}

@Test
@MainActor
func eventDispatcherUsesAncestrySnapshotWhenTargetIsRemovedDuringCapture() {
    let recorder = EventRecorder()
    let root = RemovingEventNode(name: "root", recorder: recorder)
    let child = EventNode(name: "child", recorder: recorder)
    root.addSubnode(child)
    root.nodeToRemove = child

    let event = Event(type: .pointerDown, targetID: child.id)
    _ = EventDispatcher().dispatch(event, target: child)

    #expect(recorder.phases == ["capture:root", "target:child", "bubble:root"])
    #expect(child.supernode == nil)
}

@Test
@MainActor
func hitTesterUsesFramesAndFrontmostZOrder() {
    let root = Node()
    let back = Node(style: LayoutStyle(visual: LayoutVisualProperties(zIndex: 1)))
    let front = Node(style: LayoutStyle(visual: LayoutVisualProperties(zIndex: 2)))
    root.addSubnode(back)
    root.addSubnode(front)
    let frames = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(identity: back.id, frame: LayoutFrame(width: 80, height: 80)),
            LayoutPlacement(identity: front.id, frame: LayoutFrame(width: 80, height: 80)),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(frames)
    back.apply(frames)
    front.apply(frames)

    #expect(HitTester.hitTest(point: LayoutPoint(x: 20, y: 20), root: root) === front)
    #expect(HitTester.hitTest(point: LayoutPoint(x: 120, y: 20), root: root) == nil)
}

@Test
@MainActor
func pointerCaptureIsScopedByWindowAndCancelIsIdempotent() {
    let store = PointerCaptureStore()
    let target = Node()
    let firstWindow = UUID()
    let secondWindow = UUID()

    #expect(store.capture(pointerID: 7, windowID: firstWindow, target: target))
    #expect(store.target(pointerID: 7, windowID: firstWindow) === target)
    #expect(store.target(pointerID: 7, windowID: secondWindow) == nil)
    #expect(store.cancel(pointerID: 7, windowID: firstWindow, reason: .pointerCancelled) === target)
    #expect(store.cancel(pointerID: 7, windowID: firstWindow, reason: .pointerCancelled) == nil)
}

@Test
@MainActor
func hitTesterHonorsHiddenOverflowClip() {
    let root = Node()
    let parent = Node(
        style: LayoutStyle(visual: LayoutVisualProperties(overflow: .hidden))
    )
    let child = Node()
    root.addSubnode(parent)
    parent.addSubnode(child)
    let frames = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 200, height: 200)),
            LayoutPlacement(identity: parent.id, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(
                identity: child.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 80, y: 0), width: 50, height: 50)
            ),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(frames)
    parent.apply(frames)
    child.apply(frames)

    #expect(HitTester.hitTest(point: LayoutPoint(x: 120, y: 20), root: root) === root)
}

@Test
@MainActor
func hitTesterAppliesPresentationTransformAroundFrameOrigin() {
    let root = Node()
    let child = Node(
        style: LayoutStyle(
            visual: LayoutVisualProperties(
                zIndex: 0,
                overflow: .visible,
                opacity: 1,
                transform: LayoutTransform(scaleX: 2, scaleY: 2)
            )
        )
    )
    root.addSubnode(child)
    let frames = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 200, height: 200)),
            LayoutPlacement(
                identity: child.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 80, y: 80), width: 40, height: 40)
            ),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(frames)
    child.apply(frames)

    #expect(HitTester.hitTest(point: LayoutPoint(x: 150, y: 100), root: root) === child)
}

@Test
@MainActor
func pointerDispatchPrefersCaptureAndReleasesOnCancel() {
    let recorder = EventRecorder()
    let root = EventNode(name: "root", recorder: recorder)
    let child = EventNode(name: "child", recorder: recorder)
    root.addSubnode(child)
    let frames = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(identity: child.id, frame: LayoutFrame(width: 40, height: 40)),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(frames)
    child.apply(frames)
    let windowID = UUID()
    let store = PointerCaptureStore()
    let dispatcher = EventDispatcher()
    let down = Event(
        type: .pointerDown,
        targetID: child.id,
        payload: .pointer(
            PointerData(
                point: LayoutPoint(x: 10, y: 10), pointerID: 3, windowID: windowID
            )
        )
    )
    #expect(dispatcher.dispatch(down, root: root, captureStore: store) != nil)
    #expect(store.capture(pointerID: 3, windowID: windowID, target: child))

    let cancel = Event(
        type: .pointerCancel,
        targetID: child.id,
        payload: .pointer(
            PointerData(
                point: LayoutPoint(x: 500, y: 500), pointerID: 3, windowID: windowID
            )
        )
    )
    #expect(dispatcher.dispatch(cancel, root: root, captureStore: store) != nil)
    #expect(store.target(pointerID: 3, windowID: windowID) == nil)
    #expect(recorder.phases.contains("target:child"))
}
