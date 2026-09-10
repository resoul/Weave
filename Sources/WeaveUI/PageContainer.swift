import Foundation

/// A composition host for several pages — each an arbitrary `Node`, typically a collection —
/// switched by a `SegmentedControl`. This is the tabbed-list composition: card 02's
/// `CollectionCell` makes a collection valid *inside* a cell, and this type makes a set of
/// collections (or any nodes) valid as *pages* switched by one control, with per-page scroll and
/// interaction state preserved across switches.
///
/// ## Retention policy
/// A non-selected page is **detached** from the node hierarchy (removed as a child of the
/// internal page host) but not disposed — the `Node` instance, and everything it owns (a
/// `VirtualizedView`'s scroll offset, its materialized cells, its `itemState`), stays alive.
/// Reattaching it later is a plain `addSubnode` with no rebuild. Detached pages beyond
/// `maxRetainedPages` (least-recently-used first, the currently selected page always exempt) are
/// evicted: disposed and dropped, to be rebuilt from scratch via `pageFactory` if selected again.
/// This gets "switching tabs does not scroll to top" without paying for unboundedly many live
/// pages — see card 06's task file for the measurement this trade-off should be checked against.
///
/// ## Selection is owner-driven
/// Tapping a segment only emits `selectionIntents`; `setSelected(_:)` is the only thing that
/// moves `selected` and attaches/detaches pages — mirroring `SegmentedControl` itself, which this
/// type composes rather than duplicates.
/// Ownership: the container owns `control`, the page host, and every page it has built until evicted or disposed. Isolation: MainActor. Errors: a `selected`/`setSelected` ID absent from `pages` falls back to the first page (or `nil` when `pages` is empty). Cancellation: disposal disposes every retained page, attached or not.
@MainActor
public final class PageContainer<PageID: Hashable & Sendable>: Node {
    public let control: SegmentedControl<PageID>
    public private(set) var pages: [Segment<PageID>]
    public private(set) var selected: PageID?
    public let selectionIntents: ActionPipe<PageID>
    /// Upper bound on retained (attached + detached-but-alive) pages. The selected page is never
    /// evicted regardless of this cap. Ownership: changing it may immediately evict pages over
    /// the new cap.
    public var maxRetainedPages: Int = 4 {
        didSet { enforceRetentionCap() }
    }

    private let pageFactory: @MainActor (PageID) -> Node
    private let pageHost: Node
    private let headerSlot: Node
    private var attachedPages: [PageID: Node] = [:]
    /// Least-recently-selected first.
    private var pageRecency: [PageID] = []
    private var headerNode: Node?
    private var headerCollapsedExtent: Double = 0
    /// Progress toward the header's collapse point, shared across every page rather than reset
    /// per page — this is what makes switching pages not jump the header. The caller reports it
    /// (see `updateHeaderScrollProgress(_:)`); `PageContainer` does not assume every page is a
    /// `ScrollNode` it could observe directly.
    private var headerScrollProgress: Double = 0

    /// Creates a page container with an initial page list and selection.
    /// Ownership: `pageFactory` is retained and called lazily, at most once per page ID until that page is evicted. Isolation: MainActor. Errors: none — see type-level docs for selection fallback. Cancellation: no work starts beyond building the initially selected page.
    public init(
        pages: [Segment<PageID>],
        selected: PageID?,
        pageFactory: @escaping @MainActor (PageID) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.pages = pages
        let resolvedSelected = pages.contains { $0.id == selected } ? selected : pages.first?.id
        self.selected = resolvedSelected
        self.pageFactory = pageFactory
        selectionIntents = ActionPipe(capacity: 16)
        control = SegmentedControl(segments: pages, selectedID: resolvedSelected)
        pageHost = Node()
        var pageHostDraft = LayoutStyle.Draft(LayoutStyle())
        pageHostDraft.flexDirection = .column
        pageHostDraft.flexGrow = 1
        // A page host is a full-width viewport below the segmented control. Without an explicit
        // cross-axis width, its single child is measured at its intrinsic width (zero for an
        // unmaterialized virtualized view), so `.stretch` has no width to apply.
        pageHostDraft.width = .fraction(1)
        pageHost.style = LayoutStyle.bake(pageHostDraft)
        headerSlot = Node()

        var draft = LayoutStyle.Draft(style)
        draft.flexDirection = .column
        super.init(style: LayoutStyle.bake(draft), environment: environment)

        addSubnode(headerSlot)
        addSubnode(control)
        addSubnode(pageHost)
        bind(id: "page-container-selection", control.selectionIntents.flux) {
            [weak self] selection in
            _ = self?.selectionIntents.send(selection.id)
        }

        if let resolvedSelected {
            attach(resolvedSelected)
        }
    }

    /// Moves the applied selection: detaches the previous page (kept alive, subject to the
    /// retention cap), attaches or builds the new one, and syncs `control`. Does not emit
    /// `selectionIntents` — that only happens from a tap on `control`.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: an `id` absent from `pages` is ignored. Cancellation: not applicable.
    public func setSelected(_ id: PageID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        guard id != selected else { return }
        if let selected { detach(selected) }
        attach(id)
        selected = id
        control.setSelected(id)
    }

    /// Replaces the page list. Pages no longer present are evicted (disposed) even if currently
    /// attached. If `selected` is no longer present, falls back to the first remaining page (or
    /// `nil` if `pages` is now empty).
    /// Ownership: `pages` is copied; evicted page nodes are disposed. Isolation: MainActor. Errors: none — see fallback above. Cancellation: not applicable.
    public func updatePages(_ pages: [Segment<PageID>], selected: PageID?) {
        self.pages = pages
        let validIDs = Set(pages.map(\.id))
        for id in attachedPages.keys where !validIDs.contains(id) {
            evict(id)
        }
        let resolvedSelected = pages.contains { $0.id == selected } ? selected : pages.first?.id
        control.updateSegments(pages, selectedID: resolvedSelected)
        if let current = self.selected, current != resolvedSelected {
            detach(current)
        }
        self.selected = resolvedSelected
        if let resolvedSelected {
            attach(resolvedSelected)
        }
    }

    /// Returns a retained page's node, attached or not; `nil` if it was never built or has been
    /// evicted.
    /// Ownership: the returned node remains owned by the container. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func page(_ id: PageID) -> Node? { attachedPages[id] }

    /// Sets (or clears, passing `nil`) a shared header above `control`. The header's own
    /// "expanded" extent is read from its `calculatedFrame` once available after a real layout
    /// pass; until then it reports as fully expanded (no collapse applied). Replacing an existing
    /// header discards the previous collapse progress cache but not `headerScrollProgress` itself
    /// — that stays shared across whatever header is current, matching the "switching pages does
    /// not jump the header" requirement this exists for.
    /// Ownership: the container takes ownership of `node` as `headerSlot`'s child; any previous header is detached (not disposed — the caller supplied it and may reuse it). Isolation: MainActor. Errors: a non-finite/negative `collapsedExtent` normalizes to zero. Cancellation: not applicable.
    public func setHeader(_ node: Node?, collapsedExtent: Double) {
        for child in headerSlot.subnodes { child.removeFromSupernode() }
        headerNode = node
        headerCollapsedExtent = max(0, collapsedExtent.isFinite ? collapsedExtent : 0)
        if let node { headerSlot.addSubnode(node) }
        applyHeaderCollapse()
    }

    /// Reports how far the active page has scrolled, driving the header toward its collapsed
    /// extent (clamped there — past that point the tab bar stays put beneath it). The caller
    /// forwards this from whichever page is actually selected; `PageContainer` does not assume
    /// every page is a `ScrollNode` it could observe on its own.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: a non-finite/negative `progress` normalizes to zero. Cancellation: not applicable.
    public func updateHeaderScrollProgress(_ progress: Double) {
        headerScrollProgress = max(0, progress.isFinite ? progress : 0)
        applyHeaderCollapse()
    }

    private func applyHeaderCollapse() {
        guard let headerNode else { return }
        // Read fresh every call rather than cached: nothing overrides `headerNode`'s own frame
        // (only `headerSlot`'s and `control`'s), so any real layout pass keeps giving it its
        // natural intrinsic height — but the *first* call here can easily land before that first
        // real pass has run at all, and a cache taken at that point would permanently lock in 0.
        let natural = headerNode.calculatedFrame?.height ?? 0
        let collapsedHeight = max(headerCollapsedExtent, natural - headerScrollProgress)
        let crossWidth = calculatedFrame?.width ?? headerSlot.calculatedFrame?.width ?? 0
        headerSlot.apply(
            LayoutResult(
                placements: [
                    LayoutPlacement(
                        identity: headerSlot.id,
                        frame: LayoutFrame(
                            origin: LayoutPoint(x: 0, y: 0), width: crossWidth,
                            height: collapsedHeight))
                ], treeIdentity: headerSlot.id, environmentRevision: 0, contentRevision: 0))
        guard let controlHeight = control.calculatedFrame?.height else { return }
        let controlY = collapsedHeight
        control.apply(
            LayoutResult(
                placements: [
                    LayoutPlacement(
                        identity: control.id,
                        frame: LayoutFrame(
                            origin: LayoutPoint(x: 0, y: controlY), width: crossWidth,
                            height: controlHeight))
                ], treeIdentity: control.id, environmentRevision: 0, contentRevision: 0))

        // pageHost (and whatever page is attached) must follow control's new position — nothing
        // else repositions them once headerSlot/control have been overridden outside a real
        // layout pass, so without this the active page stays wherever the last *real* pass put
        // it and visually collides with the now-higher tab bar as the header collapses.
        guard let containerHeight = calculatedFrame?.height else { return }
        let pageHostY = controlY + controlHeight
        let pageHostFrame = LayoutFrame(
            origin: LayoutPoint(x: 0, y: pageHostY), width: crossWidth,
            height: max(0, containerHeight - pageHostY))
        pageHost.apply(
            LayoutResult(
                placements: [LayoutPlacement(identity: pageHost.id, frame: pageHostFrame)],
                treeIdentity: pageHost.id, environmentRevision: 0, contentRevision: 0))
        if let page = pageHost.subnodes.first {
            // Frame only — not `didApplyLayoutResult`. That hook is what makes a
            // `VirtualizedView` re-sync its viewport and rendered window, which is desirable in
            // principle but firing it here means every scroll tick (this runs once per reported
            // header-scroll progress, i.e. often) can invalidate/re-materialize cells, which can
            // itself trigger a real async layout pass that resets these very frames — a
            // real-vs-synthetic layout fight. Keep this to the minimum needed to stop the page
            // from visually colliding with the tab bar as the header collapses.
            page.apply(
                LayoutResult(
                    placements: [LayoutPlacement(identity: page.id, frame: pageHostFrame)],
                    treeIdentity: page.id, environmentRevision: 0, contentRevision: 0))
        }
    }

    public override func dispose() {
        // `children` only reaches currently-attached nodes; detached-but-retained pages need
        // their own pass or they leak past this container's own disposal.
        for node in attachedPages.values { node.dispose() }
        attachedPages.removeAll()
        pageRecency.removeAll()
        selectionIntents.finish()
        super.dispose()
    }

    private func attach(_ id: PageID) {
        let node: Node
        if let existing = attachedPages[id] {
            node = existing
        } else {
            node = pageFactory(id)
            attachedPages[id] = node
        }
        // A page is expected to fill the space beneath the tab bar regardless of whatever style
        // pageFactory gave it — that's what "a page" means in any tabbed UI, and a caller
        // shouldn't have to remember to size every page explicitly to get it. `pageHost` is a
        // single-child `.column` container, so `flexGrow` (main axis) plus the default
        // `alignItems: .stretch` (cross axis) is enough; only `flexGrow` needs forcing here.
        var draft = LayoutStyle.Draft(node.style)
        draft.flexGrow = 1
        node.style = LayoutStyle.bake(draft)
        pageHost.addSubnode(node)
        touchRecency(id)
        enforceRetentionCap()
    }

    private func detach(_ id: PageID) {
        attachedPages[id]?.removeFromSupernode()
    }

    private func evict(_ id: PageID) {
        guard let node = attachedPages.removeValue(forKey: id) else { return }
        node.removeFromSupernode()
        node.dispose()
        pageRecency.removeAll { $0 == id }
    }

    private func touchRecency(_ id: PageID) {
        pageRecency.removeAll { $0 == id }
        pageRecency.append(id)
    }

    private func enforceRetentionCap() {
        let cap = max(1, maxRetainedPages)
        while attachedPages.count > cap {
            guard let lru = pageRecency.first(where: { $0 != selected }) else { break }
            evict(lru)
        }
    }
}
