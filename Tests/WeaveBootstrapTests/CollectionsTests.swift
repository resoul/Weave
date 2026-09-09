import Testing
@testable import Weave

@MainActor
struct CollectionsTests {
    @MainActor
    final class ReusableCell: Node, ReusableNode {
        var resets = 0
        func prepareForReuse() { resets += 1 }
    }
    @Test
    func virtualizationWindowKeepsOverscanBounded() {
        let window = VirtualizationWindow.compute(
            totalCount: 10_000,
            viewportLength: 100,
            scrollOffset: 1_000,
            estimatedItemLength: 20,
            overscanFactor: 2
        )
        #expect(window.visibleRange == 50..<55)
        #expect(window.renderedRange == 40..<65)
    }

    @Test
    func listRendersOnlyOverscanRangeAndPreservesStableIDs() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, context in
            _ = context
            return Node()
        }
        list.estimatedItemLength = 20
        list.updateViewport(
            viewportSize: MeasuredSize(width: 100, height: 100),
            contentSize: MeasuredSize(width: 100, height: 10_000)
        )
        list.updateItems(Array(0..<10_000))
        #expect(list.subnodes.count <= 30)
        let first = list.subnodes.first
        list.updateItems(Array(0..<10_000))
        #expect(list.subnodes.count <= 30)
        #expect(first?.lifecycleState != .disposed)
    }

    @Test
    func selectionAndDuplicateIDsAreBounded() {
        let list = ListView<String, Int>(itemID: { _ in 1 }) { _, _ in Node() }
        list.selectionMode = .single
        list.updateItems(["first", "duplicate"])
        #expect(list.itemIDs == [1])
        list.select(1)
        #expect(list.selectedItems == [1])
    }

    @Test
    func sectionSnapshotProvidesHeaderContextAndMeasuredAnchor() {
        let list = ListView<String, Int>(itemID: { value in Int(value)! }) { _, context in
            #expect(context.sectionIndex >= 0)
            return Node()
        }
        list.sectionHeader = { _ in Node() }
        list.estimatedItemLength = 20
        list.updateSnapshot(
            CollectionSnapshot(sections: [
                CollectionSection(
                    id: "one",
                    items: [
                        CollectionItem(id: 1, value: "one")
                    ]),
                CollectionSection(
                    id: "two",
                    items: [
                        CollectionItem(id: 2, value: "two")
                    ]),
            ])
        )
        list.updateVirtualViewport(length: 20, offset: 20)
        list.updateMeasuredItem(id: 1, length: 40)
        #expect(list.sectionCount == 2)
        #expect(list.itemIDs == [1, 2])
    }

    @Test
    func adaptiveGridComputesAtLeastOneColumn() {
        let grid = GridView<Int, Int>(
            layout: .adaptive(minItemWidth: 120, spacing: 8), itemID: { $0 }
        ) { _, _ in Node() }
        #expect(grid.columnCount(availableWidth: 0) == 1)
        #expect(grid.columnCount(availableWidth: 400) == 3)
    }

    @Test
    func reuseAndContextMenuKeepStableIdentity() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in ReusableCell() }
        list.configureReusedCell = { node, _, _ in node is ReusableCell }
        list.contextMenu = { _, context in
            CollectionContextMenu(actions: [
                CollectionContextMenuAction(id: "open", title: "Open \(context.itemID)")
            ])
        }
        list.updateVirtualViewport(length: 40, offset: 0)
        list.updateItems(Array(0..<10))
        list.setFocusedItem(2)
        #expect(list.focusedItemID == 2)
        #expect(list.requestContextMenu(for: 2) != nil)
        list.updateItems([100, 101])
        #expect(list.focusedItemID == nil)
    }

    @Test
    func virtualizationWindowWithVariableHeightsComputesAccurateWindow() {
        let lengths = [0: 200.0, 1: 50.0, 2: 50.0, 3: 50.0]
        let window = VirtualizationWindow.compute(
            totalCount: 4,
            viewportLength: 100,
            scrollOffset: 150,
            estimatedItemLength: 50,
            itemLengths: lengths,
            overscanFactor: 0
        )
        // At offset 150, item 0 covers 0..<200, so it is the start of visible range
        #expect(window.visibleRange.contains(0))
        #expect(window.visibleRange.lowerBound == 0)
    }

    @Test
    func virtualizedViewAutomaticallyCapturesMeasuredHeightsAfterLayout() {
        let list = ListView<Int, Int>(itemID: { $0 }) { id, _ in Node() }
        list.updateVirtualViewport(length: 100, offset: 0)
        list.updateItems([1, 2, 3])

        guard let firstChild = list.subnodes.first else {
            #expect(Bool(false), "cell must exist")
            return
        }

        let placements = [
            LayoutPlacement(
                identity: list.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 100, height: 300)
            ),
            LayoutPlacement(
                identity: firstChild.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 100, height: 85)
            ),
        ]
        let result = LayoutResult(
            placements: placements,
            treeIdentity: list.id,
            environmentRevision: 1,
            contentRevision: 1
        )
        list.applyRecursively(result)

        #expect(firstChild.calculatedFrame?.height == 85)
        #expect(list.state.contentSize.height >= 85)
    }
}
