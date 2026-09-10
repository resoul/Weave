import Testing
@testable import Weave

@MainActor
struct PageContainerTests {
    private func makeListPage() -> ListView<Int, Int> {
        let list = ListView<Int, Int>(itemID: { $0 }) { _, _ in
            Node().style {
                $0.width = .fraction(1)
                $0.height = .points(20)
            }
        }
        list.estimatedItemLength = 20
        // Items first: updateVirtualViewport computes content length from the *current* item
        // count, so calling it before there are any items would leave contentSize too small for
        // a later scroll offset to stick.
        list.updateItems(Array(0..<1000))
        list.updateVirtualViewport(length: 100, offset: 0)
        return list
    }

    private func makeContainer(pages: [String] = ["a", "b", "c"], maxRetained: Int = 4)
        -> PageContainer<String>
    {
        let container = PageContainer<String>(
            pages: pages.map { Segment(id: $0, title: $0) },
            selected: pages.first,
            pageFactory: { _ in self.makeListPage() }
        )
        container.maxRetainedPages = maxRetained
        return container
    }

    @Test
    func switchingPagesRestoresScrollOffset() {
        let container = makeContainer()
        guard let pageA = container.page("a") as? ListView<Int, Int> else {
            #expect(Bool(false), "page a must exist")
            return
        }
        _ = pageA.scroll(.to(LayoutPoint(x: 0, y: 240)))

        container.setSelected("b")
        container.setSelected("a")

        guard let restored = container.page("a") as? ListView<Int, Int> else {
            #expect(Bool(false), "page a must still exist")
            return
        }
        #expect(restored === pageA)
        #expect(restored.state.offset.y == 240)
    }

    @Test
    func switchingPagesRestoresNestedInnerOffset() {
        let container = PageContainer<String>(
            pages: [Segment(id: "rows", title: "Rows"), Segment(id: "other", title: "Other")],
            selected: "rows",
            pageFactory: { id in
                if id == "rows" {
                    let outer = ListView<Int, Int>(itemID: { $0 }) { _, _ in
                        let inner = CollectionView<Int, Int>(axis: .horizontal, itemID: { $0 }) {
                            _, _ in Node()
                        }
                        inner.estimatedItemLength = 40
                        return CollectionCell(content: inner, hostAxis: .vertical, extent: 100)
                    }
                    outer.estimatedItemLength = 100
                    outer.updateVirtualViewport(length: 100, offset: 0)
                    outer.updateItems(Array(0..<10))
                    return outer
                }
                return self.makeListPage()
            }
        )

        guard let rowsPage = container.page("rows") as? ListView<Int, Int>,
            let firstCell = rowsPage.subnodes.first as? CollectionCell<Int, Int>
        else {
            #expect(Bool(false), "rows page must host a CollectionCell")
            return
        }
        firstCell.content.updateItems(Array(0..<20))
        firstCell.content.updateVirtualViewport(length: 50, offset: 0)
        _ = firstCell.content.scroll(.to(LayoutPoint(x: 33, y: 0)))

        // Switching pages detaches/reattaches whole subtrees — nothing inside "rows" recycles,
        // so the nested offset needs no capture/restore hook here; it's just still there.
        container.setSelected("other")
        container.setSelected("rows")

        guard
            let restoredCell = container.page("rows")?.subnodes.first
                as? CollectionCell<
                    Int, Int
                >
        else {
            #expect(Bool(false), "row must still host a CollectionCell after returning")
            return
        }
        #expect(restoredCell === firstCell)
        #expect(restoredCell.content.state.offset.x == 33)
    }

    @Test
    func detachedPageEmitsNoEvents() {
        let container = makeContainer()
        guard let pageA = container.page("a") else {
            #expect(Bool(false), "page a must exist")
            return
        }
        #expect(pageA.supernode != nil, "selected page starts attached")

        container.setSelected("b")

        #expect(pageA.supernode == nil, "a detached page is unreachable by hit-testing/visibility")
    }

    @Test
    func attachedPageFillsPageHostRegardlessOfItsOwnStyle() {
        // Found by actually running the card 08 demo app: a page built with no explicit sizing
        // (the common case — see makeListPage() above) rendered at zero size, because nothing
        // forced it to fill the space beneath the tab bar. PageContainer.attach now forces
        // flexGrow on whatever node the factory returns.
        let container = makeContainer()
        guard let pageA = container.page("a") else {
            #expect(Bool(false), "page a must exist")
            return
        }
        #expect(pageA.style.flexGrow == 1)
    }

    @Test
    func attachedVirtualizedPageGetsNonZeroViewportAfterLayout() {
        let container = makeContainer()
        guard let page = container.page("a") as? ListView<Int, Int> else {
            #expect(Bool(false), "page a must exist")
            return
        }

        let initialResult = FlexSolver.layoutContainer(
            input: container.makeLayoutInputSnapshot(),
            frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 500))
        // The first pass supplies the viewport and materializes the initial cells. The second
        // pass must still keep the list's cross axis equal to the page host, not sum row widths.
        container.applyRecursively(initialResult)
        let materializedResult = FlexSolver.layoutContainer(
            input: container.makeLayoutInputSnapshot(),
            frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 500))
        container.applyRecursively(materializedResult)

        #expect(page.calculatedFrame?.width == 300)
        #expect(page.calculatedFrame?.height ?? 0 > 0)
        #expect(page.state.viewportSize.width == 300)
        #expect(page.state.viewportSize.height > 0)
        #expect(!page.subnodes.isEmpty)
        #expect(page.subnodes.allSatisfy { $0.calculatedFrame?.width == 300 })
    }

    @Test
    func rapidPageSwitchingKeepsRetainedPageCountBounded() {
        let ids = (0..<50).map { "page-\($0)" }
        let container = makeContainer(pages: ids, maxRetained: 3)

        for id in ids {
            container.setSelected(id)
        }
        for id in ids.reversed() {
            container.setSelected(id)
        }

        let retainedCount = ids.filter { container.page($0) != nil }.count
        #expect(retainedCount <= 3)
    }

    @Test
    func pageContainerSelectionIsOwnerDriven() async {
        let container = makeContainer()
        var received: [String] = []
        let subscription = container.selectionIntents.flux.sinkOnMain { received.append($0) }

        guard let target = container.control.subnodes[1] as? any ControlInputTarget else {
            #expect(Bool(false), "segment 1 must be a ControlInputTarget")
            return
        }
        _ = target.handle(.pointerDown)
        _ = target.handle(.pointerUp(inside: true))
        // The tap relays through control.selectionIntents -> the container's own bind -> this
        // subscription — each a separate sinkOnMain Task, so delivery needs a few run-loop turns.
        // Poll rather than a fixed yield count to avoid flaking under scheduling jitter.
        for _ in 0..<200 where received.isEmpty { await Task.yield() }

        #expect(received == ["b"])
        #expect(container.selected == "a", "container must not self-select on a control tap")
        subscription.cancel()
    }

    @Test
    func updatePagesDroppingSelectedFallsBackToFirstRemaining() {
        let container = makeContainer()
        container.updatePages(
            [Segment(id: "b", title: "b"), Segment(id: "c", title: "c")], selected: "a")
        #expect(container.selected == "b")
        #expect(container.page("a") == nil, "evicted page is disposed and dropped")
    }

    @Test
    func disposingContainerDisposesRetainedPages() {
        let container = makeContainer()
        container.setSelected("b")
        container.setSelected("c")
        let pages = ["a", "b", "c"].compactMap { container.page($0) }
        #expect(pages.count == 3)

        container.dispose()

        for page in pages {
            #expect(page.lifecycleState == .disposed)
        }
    }

    // MARK: - Card 07: pinned tab bar

    private func makeHeaderedContainer() -> (container: PageContainer<String>, header: Node) {
        let container = makeContainer()
        let header = Node()
        var headerDraft = LayoutStyle.Draft(header.style)
        headerDraft.height = .points(80)
        header.style = LayoutStyle.bake(headerDraft)
        container.setHeader(header, collapsedExtent: 20)

        // A real layout pass so `header`/`control` have a `calculatedFrame` to read a natural
        // extent from, matching how the header's "expanded" height is discovered in practice.
        let placements = [
            LayoutPlacement(
                identity: container.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 500)),
            LayoutPlacement(
                identity: header.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 0), width: 300, height: 80)),
            LayoutPlacement(
                identity: container.control.id,
                frame: LayoutFrame(origin: LayoutPoint(x: 0, y: 80), width: 300, height: 44)),
        ]
        container.applyRecursively(
            LayoutResult(
                placements: placements, treeIdentity: container.id, environmentRevision: 1,
                contentRevision: 1))
        return (container, header)
    }

    @Test
    func containerHeaderCollapsesAndPinsTabBar() {
        let (container, _) = makeHeaderedContainer()

        container.updateHeaderScrollProgress(50)
        // natural(80) - progress(50) = 30, still above collapsedExtent(20).
        #expect(container.control.calculatedFrame?.origin.y == 30)

        container.updateHeaderScrollProgress(100)
        // natural(80) - progress(100) would go negative; clamps to collapsedExtent(20) — the
        // tab bar "stays put" beneath the collapsed header past that point.
        #expect(container.control.calculatedFrame?.origin.y == 20)

        container.updateHeaderScrollProgress(1000)
        #expect(container.control.calculatedFrame?.origin.y == 20)
    }

    @Test
    func headerCollapseMovesActivePageNotJustControl() {
        // Regression: an earlier version repositioned headerSlot and control on collapse but
        // never touched pageHost or the active page, so the page stayed wherever the last real
        // layout pass put it — visually colliding with (or leaving a gap below) the now-higher
        // tab bar as the header collapsed. Found by actually running the card 08 demo and
        // scrolling: tabs became unreachable because page content had climbed over them.
        let (container, _) = makeHeaderedContainer()
        guard let page = container.page("a") else {
            #expect(Bool(false), "page a must exist")
            return
        }

        container.updateHeaderScrollProgress(50)
        let controlFrame = container.control.calculatedFrame
        #expect(
            page.calculatedFrame?.origin.y == (controlFrame?.origin.y ?? 0)
                + (controlFrame?.height ?? 0))

        container.updateHeaderScrollProgress(1000)
        let collapsedControlFrame = container.control.calculatedFrame
        #expect(
            page.calculatedFrame?.origin.y
                == (collapsedControlFrame?.origin.y ?? 0) + (collapsedControlFrame?.height ?? 0))
    }

    @Test
    func pageSwitchDoesNotJumpSharedHeader() {
        let (container, _) = makeHeaderedContainer()
        container.updateHeaderScrollProgress(50)
        #expect(container.control.calculatedFrame?.origin.y == 30)

        container.setSelected("b")
        container.setSelected("a")

        #expect(
            container.control.calculatedFrame?.origin.y == 30,
            "switching pages must not reset the shared header collapse progress")
    }
}
