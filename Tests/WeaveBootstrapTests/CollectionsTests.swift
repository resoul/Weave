import Testing
@testable import Weave

@MainActor
struct CollectionsTests {
    @MainActor
    final class ReusableCell: Node, ReusableNode {
        var resets = 0
        func prepareForReuse() { resets += 1 }
    }

    @MainActor
    final class KindCell: Node, ReusableNode {
        let kind: String
        var resets = 0
        init(kind: String) {
            self.kind = kind
            super.init()
        }
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

    // MARK: - Card 01: heterogeneous cell reuse identity

    @Test
    func heterogeneousCellsRecycleIntoSeparatePools() {
        var configuredKinds: [String] = []
        let list = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            KindCell(kind: item.isMultiple(of: 2) ? "even" : "odd")
        }
        list.reuseIdentifier = { $0.isMultiple(of: 2) ? "even" : "odd" }
        list.configureReusedCell = { node, _, _ in
            guard let cell = node as? KindCell else { return false }
            configuredKinds.append(cell.kind)
            return true
        }
        list.estimatedItemLength = 20
        list.updateVirtualViewport(length: 100, offset: 0)
        list.updateItems(Array(0..<10))

        // Replace the whole window with disjoint IDs so every rendered cell recycles, seeding
        // both pools.
        list.updateItems(Array(1000..<1010))
        #expect(list.reusePool.pooledCount(reuseID: "even") > 0)
        #expect(list.reusePool.pooledCount(reuseID: "odd") > 0)

        // A window of only even items must never dequeue an "odd" pooled cell.
        configuredKinds.removeAll()
        list.updateItems(Array(stride(from: 2000, to: 2010, by: 2)))
        #expect(!configuredKinds.isEmpty)
        #expect(configuredKinds.allSatisfy { $0 == "even" })
    }

    @Test
    func reuseIdentifierNilPreservesLegacyPoolBehaviour() {
        var reuseAttempts = 0
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in ReusableCell() }
        list.configureReusedCell = { node, _, _ in
            reuseAttempts += 1
            return node is ReusableCell
        }
        list.estimatedItemLength = 20
        list.updateVirtualViewport(length: 100, offset: 0)
        list.updateItems(Array(0..<10))
        list.updateItems(Array(1000..<1010))
        #expect(list.reusePool.pooledCount(reuseID: "VirtualizedCell") > 0)

        reuseAttempts = 0
        list.updateItems(Array(2000..<2010))
        #expect(reuseAttempts > 0)
    }

    @Test
    func reusePoolRespectsPerIdentifierLimit() {
        let pool = CellReusePool(limitPerIdentifier: 2)
        let first = ReusableCell()
        let second = ReusableCell()
        let third = ReusableCell()
        pool.recycle(first, reuseID: "x")
        pool.recycle(second, reuseID: "x")
        pool.recycle(third, reuseID: "x")
        #expect(pool.pooledCount(reuseID: "x") == 2)
        #expect(third.lifecycleState == .disposed)
        #expect(first.lifecycleState != .disposed)
    }

    @Test
    func drainDisposesPooledCells() {
        let pool = CellReusePool()
        let a = ReusableCell()
        let b = ReusableCell()
        pool.recycle(a, reuseID: "x")
        pool.recycle(b, reuseID: "y")
        pool.drain()
        #expect(pool.pooledCount(reuseID: "x") == 0)
        #expect(pool.pooledCount(reuseID: "y") == 0)
        #expect(a.lifecycleState == .disposed)
        #expect(b.lifecycleState == .disposed)
    }

    // MARK: - Card 02: nested collection hosting

    private func makeHostedCell(itemID: Int) -> CollectionCell<Int, Int> {
        let inner = CollectionView<Int, Int>(axis: .horizontal, itemID: { $0 }) { _, _ in Node() }
        inner.estimatedItemLength = 40
        return CollectionCell(content: inner, hostAxis: .vertical, extent: 100)
    }

    @Test
    func nestedCollectionVirtualizesIndependentlyOfHost() {
        let outer = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            self.makeHostedCell(itemID: item)
        }
        outer.estimatedItemLength = 100
        outer.updateVirtualViewport(length: 300, offset: 0)
        outer.updateItems(Array(0..<50))

        guard let firstCell = outer.subnodes.first as? CollectionCell<Int, Int> else {
            #expect(Bool(false), "first row must be a CollectionCell")
            return
        }

        let placements = [
            LayoutPlacement(
                identity: outer.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 300)),
            LayoutPlacement(
                identity: firstCell.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
            LayoutPlacement(
                identity: firstCell.content.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
        ]
        let result = LayoutResult(
            placements: placements, treeIdentity: outer.id, environmentRevision: 1,
            contentRevision: 1)
        outer.applyRecursively(result)

        firstCell.content.updateItems(Array(0..<1000))

        #expect(outer.subnodes.count <= 30, "outer must stay within its own overscan window")
        #expect(
            firstCell.content.subnodes.count <= 30,
            "nested collection virtualizes on its own overscan window, independent of the outer's"
        )
    }

    @Test
    func nestedCellExtentIsStableAcrossLayoutPasses() {
        let outer = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            self.makeHostedCell(itemID: item)
        }
        outer.estimatedItemLength = 100
        outer.updateVirtualViewport(length: 300, offset: 0)
        outer.updateItems(Array(0..<5))

        guard let firstCell = outer.subnodes.first as? CollectionCell<Int, Int> else {
            #expect(Bool(false), "first row must be a CollectionCell")
            return
        }

        func applyLayout() {
            let placements = [
                LayoutPlacement(
                    identity: outer.id,
                    frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 300)),
                LayoutPlacement(
                    identity: firstCell.id,
                    frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 100)),
            ]
            let result = LayoutResult(
                placements: placements, treeIdentity: outer.id, environmentRevision: 1,
                contentRevision: 1)
            outer.applyRecursively(result)
        }

        applyLayout()
        #expect(firstCell.calculatedFrame?.height == 100)

        // Growing the nested collection's own content must never change the declared row extent.
        firstCell.content.updateItems(Array(0..<1000))
        applyLayout()
        #expect(firstCell.calculatedFrame?.height == 100)
        #expect(outer.state.contentSize.height < 1000)
    }

    @Test
    func recyclingNestedCellResetsInnerItemsAndOffset() {
        let outer = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            let cell = self.makeHostedCell(itemID: item)
            cell.content.updateItems(Array(0..<20))
            _ = cell.content.scroll(.to(LayoutPoint(x: 40, y: 0)))
            return cell
        }
        outer.configureReusedCell = { node, _, _ in node is CollectionCell<Int, Int> }
        outer.estimatedItemLength = 100
        outer.updateVirtualViewport(length: 100, offset: 0)
        outer.updateItems(Array(0..<10))

        // Replace the whole window with disjoint IDs so every rendered cell recycles.
        outer.updateItems(Array(1000..<1010))
        #expect(outer.reusePool.pooledCount(reuseID: "VirtualizedCell") > 0)

        // Bring back a window that must dequeue from the pool.
        outer.updateItems(Array(0..<10))
        guard let reused = outer.subnodes.first as? CollectionCell<Int, Int> else {
            #expect(Bool(false), "reused row must still be a CollectionCell")
            return
        }
        #expect(reused.content.items.isEmpty, "recycling must clear nested items before reuse")
        #expect(
            reused.content.state.offset == LayoutPoint(x: 0, y: 0),
            "recycling must reset nested scroll offset before reuse"
        )
    }

    @Test
    func disposingHostDisposesNestedCollections() {
        var innerRefs: [VirtualizedView<Int, Int>] = []
        let outer = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            let cell = self.makeHostedCell(itemID: item)
            cell.content.updateItems(Array(0..<5))
            innerRefs.append(cell.content)
            return cell
        }
        outer.estimatedItemLength = 100
        outer.updateVirtualViewport(length: 300, offset: 0)
        outer.updateItems(Array(0..<5))
        #expect(!innerRefs.isEmpty)

        outer.dispose()

        for inner in innerRefs {
            #expect(inner.lifecycleState == .disposed)
        }
    }

    @Test
    func nestedCollectionDoesNotRetainHost() {
        weak var weakInner: CollectionView<Int, Int>?
        do {
            let inner = CollectionView<Int, Int>(axis: .horizontal, itemID: { $0 }) { _, _ in
                Node()
            }
            weakInner = inner
            let cell = CollectionCell(content: inner, hostAxis: .vertical, extent: 100)
            cell.dispose()
        }
        #expect(weakInner == nil)
    }

    // MARK: - Card 04: per-item state retention

    @Test
    func nestedOffsetSurvivesWindowExitAndReturn() {
        let outer = ListView<Int, Int>(itemID: { $0 }) { item, _ in
            self.makeHostedCell(itemID: item)
        }
        // A reused cell is reconfigured fully for its new item, including geometry — this is the
        // realistic responsibility `configureReusedCell` has in production, where every row's
        // nested collection gets its viewport from the same layout pass (card 02), not from
        // whichever specific instance happened to be dequeued.
        outer.configureReusedCell = { node, _, _ in
            guard let cell = node as? CollectionCell<Int, Int> else { return false }
            cell.content.updateItems(Array(0..<20))
            cell.content.updateVirtualViewport(length: 50, offset: 0)
            return true
        }
        outer.captureItemState = { node, _ in
            guard let cell = node as? CollectionCell<Int, Int> else { return nil }
            return ItemPresentationState(nestedOffset: cell.content.state.offset)
        }
        outer.restoreItemState = { node, _, state in
            guard let cell = node as? CollectionCell<Int, Int>, let offset = state.nestedOffset
            else { return }
            _ = cell.content.scroll(.to(offset))
        }
        outer.estimatedItemLength = 100
        // Zero overscan keeps exactly one row materialized at a time.
        outer.overscanFactor = 0
        outer.updateVirtualViewport(length: 100, offset: 0)
        // One stable, unchanging item list throughout: only the *rendered window* moves, via
        // scroll — matching the real "row scrolled off and back" scenario this card targets.
        // (Swapping to a disjoint item list instead would make item 0 genuinely disappear from
        // `itemIDs`, which correctly prunes its state per `itemStateIsPrunedWhenItemDisappears` —
        // that is a different scenario from this one.)
        outer.updateItems(Array(0..<1000))

        guard let firstCell = outer.subnodes.first as? CollectionCell<Int, Int> else {
            #expect(Bool(false), "first row must be a CollectionCell")
            return
        }
        firstCell.content.updateItems(Array(0..<20))
        firstCell.content.updateVirtualViewport(length: 50, offset: 0)
        _ = firstCell.content.scroll(.to(LayoutPoint(x: 42, y: 0)))

        // Scroll the row for item 0 out of the rendered window, then back to the top.
        _ = outer.moveBy(x: 0, y: 500)
        #expect(outer.itemIDs.contains(0), "item 0 stays in the data throughout")
        _ = outer.moveBy(x: 0, y: -500)

        guard let restoredCell = outer.subnodes.first as? CollectionCell<Int, Int> else {
            #expect(Bool(false), "row must still be a CollectionCell after returning")
            return
        }
        #expect(restoredCell.content.state.offset.x == 42)
    }

    @Test
    func itemStateIsPrunedWhenItemDisappears() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.itemState.setState(
            ItemPresentationState(nestedOffset: LayoutPoint(x: 1, y: 1)), for: 5)
        list.estimatedItemLength = 20
        list.updateVirtualViewport(length: 100, offset: 0)
        list.updateItems(Array(0..<10))
        #expect(list.itemState.state(for: 5) != nil)

        list.updateItems(Array(100..<110))
        #expect(list.itemState.state(for: 5) == nil)
    }

    @Test
    func measuredLengthsArePrunedWithItems() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.estimatedItemLength = 20
        list.updateVirtualViewport(length: 100, offset: 0)
        list.updateItems(Array(0..<10))
        list.updateMeasuredItem(id: 3, length: 77)
        #expect(list.measuredLengthCount > 0)

        list.updateItems(Array(100..<110))
        #expect(list.measuredLengthCount == 0)
    }

    @Test
    func stateStoreStaysBoundedUnderRepeatedScroll() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.captureItemState = { _, _ in
            ItemPresentationState(nestedOffset: LayoutPoint(x: 0, y: 0))
        }
        list.estimatedItemLength = 20
        list.updateVirtualViewport(length: 100, offset: 0)

        for windowStart in stride(from: 0, to: 10_000, by: 50) {
            list.updateItems(Array(windowStart..<(windowStart + 50)))
        }

        #expect(list.itemState.count <= 50)
    }

    // MARK: - Card 07: sticky section headers

    private func makeSectionedSnapshot(sectionCount: Int, itemsPerSection: Int)
        -> CollectionSnapshot<Int, Int, Int>
    {
        var sections: [CollectionSection<Int, Int, Int>] = []
        var value = 0
        for section in 0..<sectionCount {
            var items: [CollectionItem<Int, Int>] = []
            for _ in 0..<itemsPerSection {
                items.append(CollectionItem(id: value, value: value))
                value += 1
            }
            sections.append(CollectionSection(id: section, items: items))
        }
        return CollectionSnapshot(sections: sections)
    }

    private func header(_ list: ListView<Int, Int>, _ sectionIndex: Int) -> Node? {
        list.subnodes.first { $0.reconciliationDescriptor?.key == "header:\(sectionIndex)" }
    }

    @Test
    func pinnedSectionHeaderStaysAtLeadingEdge() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.sectionHeader = { _ in Node() }
        list.estimatedItemLength = 20
        list.pinsSectionHeaders = true
        list.updateSnapshot(makeSectionedSnapshot(sectionCount: 3, itemsPerSection: 3))
        // Section starts (header 20 + 3 items * 20 = 80 each): 0 -> 0, 1 -> 80, 2 -> 160.
        list.updateVirtualViewport(length: 100, offset: 30)

        #expect(list.pinnedSectionIndex == 0)
        guard let header0 = header(list, 0) else {
            #expect(Bool(false), "section 0 header must be materialized")
            return
        }
        #expect(header0.calculatedFrame?.origin.y == 30)
    }

    @Test
    func nextSectionHeaderPushesPinnedHeaderOut() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.sectionHeader = { _ in Node() }
        list.estimatedItemLength = 20
        list.pinsSectionHeaders = true
        list.updateSnapshot(makeSectionedSnapshot(sectionCount: 3, itemsPerSection: 3))
        // Section 1 starts at 80; a header 20 tall must stop being pushed further than 60 so it
        // never overlaps section 1's incoming header.
        list.updateVirtualViewport(length: 100, offset: 75)

        #expect(list.pinnedSectionIndex == 0)
        guard let header0 = header(list, 0) else {
            #expect(Bool(false), "section 0 header must be materialized")
            return
        }
        #expect(header0.calculatedFrame?.origin.y == 60)
    }

    @Test
    func pinnedHeadersRespectRTLAndHorizontalAxis() {
        // FlexSolver does not mirror row-flow child positions for RTL today (only directional
        // padding/margin resolve differently) — verified by reading FlexSolver.swift, which uses
        // `LayoutDirection` solely for `resolved(for:)` edge-inset conversion. Pinning follows the
        // same convention the rest of virtualization already uses (raw physical scroll offset,
        // no direction-based mirroring), so the claim this test makes is narrower than "correct
        // RTL mirroring": pinning behaves *consistently* regardless of `layoutDirection`, matching
        // ordinary (non-pinned) virtualized positioning's existing RTL behavior rather than adding
        // new direction-aware behavior of its own.
        for direction: LayoutDirection in [.leftToRight, .rightToLeft] {
            let list = CollectionView<Int, Int>(axis: .horizontal, itemID: { $0 }) { _, _ in Node()
            }
            list.layoutDirection = direction
            list.sectionHeader = { _ in Node() }
            list.estimatedItemLength = 20
            list.pinsSectionHeaders = true
            list.updateSnapshot(makeSectionedSnapshot(sectionCount: 3, itemsPerSection: 3))
            list.updateVirtualViewport(length: 100, offset: 30)

            guard
                let header0 = list.subnodes.first(where: {
                    $0.reconciliationDescriptor?.key == "header:0"
                })
            else {
                #expect(
                    Bool(false), "section 0 header must be materialized (direction: \(direction))")
                continue
            }
            #expect(
                header0.calculatedFrame?.origin.x == 30,
                "direction: \(direction)")
        }
    }

    @Test
    func horizontalLayoutStoresContentLengthOnHorizontalAxis() {
        let collection = CollectionView<Int, Int>(axis: .horizontal, itemID: { $0 }) { _, _ in
            Node()
        }
        collection.estimatedItemLength = 50
        collection.updateItems(Array(0..<20))

        collection.applyRecursively(
            LayoutResult(
                placements: [
                    LayoutPlacement(
                        identity: collection.id,
                        frame: LayoutFrame(width: 200, height: 100))
                ],
                treeIdentity: collection.id,
                environmentRevision: 0,
                contentRevision: 0
            ))

        #expect(collection.state.viewportSize == MeasuredSize(width: 200, height: 100))
        #expect(collection.state.contentSize == MeasuredSize(width: 1_000, height: 100))
        _ = collection.moveBy(x: 50, y: 50)
        #expect(collection.state.offset == LayoutPoint(x: 50, y: 0))
    }

    @Test
    func pinsSectionHeadersFalseMatchesLegacyLayout() {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in Node() }
        list.sectionHeader = { _ in Node() }
        list.estimatedItemLength = 20
        // pinsSectionHeaders defaults false.
        list.updateSnapshot(makeSectionedSnapshot(sectionCount: 3, itemsPerSection: 3))
        list.updateVirtualViewport(length: 40, offset: 75)

        #expect(list.pinnedSectionIndex == nil)
        let descriptorKeys = list.subnodes.compactMap { $0.reconciliationDescriptor?.key }
        let headerKeys = Set(descriptorKeys.filter { $0.hasPrefix("header:") })
        // Interleaving invariant, independent of exactly which index range windowed in: every
        // rendered item's section has exactly one header, and there is no header for a section
        // with no rendered item — there is no "forced, outside the window" header without pinning.
        // `makeSectionedSnapshot` assigns 3 sequential IDs per section, so section = id / 3.
        let renderedSections = Set(
            list.virtualizationWindow.renderedRange.compactMap { index -> Int? in
                guard list.itemIDs.indices.contains(index) else { return nil }
                return list.itemIDs[index] / 3
            })
        #expect(headerKeys == Set(renderedSections.map { "header:\($0)" }))
        // No frame override ever ran — every materialized header's frame is whatever a real
        // FlexSolver pass would give it (nil here, since this test never runs one).
        for key in headerKeys {
            let node = list.subnodes.first { $0.reconciliationDescriptor?.key == key }
            #expect(node?.calculatedFrame == nil)
        }
    }
}
