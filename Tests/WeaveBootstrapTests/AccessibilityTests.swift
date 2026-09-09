import Testing
import Weave

@Test
@MainActor
func accessibilityTreeBuildsIndependentReadingOrderAndFrames() {
    let root = Node()
    let low = Node()
    low.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Low",
        role: .text,
        sortPriority: 1
    )
    let high = Node()
    high.accessibility = AccessibilityProperties(
        isElement: true,
        label: "High",
        role: .button,
        sortPriority: 10,
        actions: [.activate]
    )
    root.addSubnode(low)
    root.addSubnode(high)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 200, height: 100)),
            LayoutPlacement(identity: low.id, frame: LayoutFrame(width: 50, height: 50)),
            LayoutPlacement(
                identity: high.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 60, y: 0), width: 50, height: 50)
            ),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(result)
    low.apply(result)
    high.apply(result)

    let tree = AccessibilityTree()
    let snapshot = tree.rebuild(root: root, revision: 7)
    #expect(snapshot.revision == 7)
    #expect(snapshot.readingOrder == [high.id, low.id])
    #expect(snapshot.root?.children.count == 2)
    #expect(snapshot.root?.children.contains { $0.properties.role == .button } == true)
}

@Test
@MainActor
func accessibilityTreeHonorsHideCombineAndModalBoundary() {
    let root = Node()
    let background = Node()
    background.accessibility = AccessibilityProperties(isElement: true, label: "Background")
    let modal = Node()
    modal.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Modal",
        childrenPolicy: .combine
    )
    let hidden = Node()
    hidden.accessibility = AccessibilityProperties(
        isElement: true,
        label: "Hidden",
        childrenPolicy: .hide
    )
    root.addSubnode(background)
    root.addSubnode(modal)
    modal.addSubnode(hidden)
    let result = LayoutResult(
        placements: [
            LayoutPlacement(identity: root.id, frame: LayoutFrame(width: 200, height: 200)),
            LayoutPlacement(identity: background.id, frame: LayoutFrame(width: 50, height: 50)),
            LayoutPlacement(identity: modal.id, frame: LayoutFrame(width: 100, height: 100)),
            LayoutPlacement(identity: hidden.id, frame: LayoutFrame(width: 40, height: 40)),
        ],
        treeIdentity: 1,
        environmentRevision: 1,
        contentRevision: 1
    )
    root.apply(result)
    background.apply(result)
    modal.apply(result)
    hidden.apply(result)

    let tree = AccessibilityTree()
    tree.setModalRoot(modal)
    let snapshot = tree.rebuild(root: root, revision: 2)
    #expect(snapshot.readingOrder == [modal.id])
    #expect(snapshot.root?.nodeID == modal.id)
    #expect(snapshot.root?.children.isEmpty == true)
}
