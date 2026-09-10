import Foundation
import Flux

/// Immutable item context supplied to a collection cell factory.
/// Ownership: the context is copied by the factory. Isolation: none. Errors: indexes are snapshots and may become stale after a new snapshot. Cancellation: no work is scheduled.
public struct ItemContext<ItemID: Hashable & Sendable>: Sendable, Hashable {
    public let itemID: ItemID
    public let index: Int
    public let sectionIndex: Int

    /// Creates an item context.
    /// Ownership: values are copied. Isolation: none. Errors: negative indexes are clamped to zero. Cancellation: not applicable.
    public init(itemID: ItemID, index: Int, sectionIndex: Int = 0) {
        self.itemID = itemID
        self.index = max(0, index)
        self.sectionIndex = max(0, sectionIndex)
    }
}

/// Per-item UI state a collection captures just before a cell leaves the rendered window
/// (recycle or dispose) and restores immediately after a cell is materialized or reconfigured
/// for an item — so state like a nested collection's scroll offset survives virtualization and
/// cell reuse instead of resetting every time an item scrolls back into view. Concrete and
/// `Sendable` by design, not a type-erased payload: strict concurrency and the public API
/// baseline both want a known shape here, and `nestedOffset` is the concrete need card 04/06
/// exist for (a `CollectionCell`'s nested scroll position, or a `PageContainer` page's).
/// Ownership: an immutable value copied into `KeyedItemStateStore`. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ItemPresentationState: Sendable, Hashable {
    public var nestedOffset: LayoutPoint?

    /// Creates a presentation state snapshot.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(nestedOffset: LayoutPoint? = nil) {
        self.nestedOffset = nestedOffset
    }
}

/// Stable item in an immutable collection section.
/// Ownership: the snapshot owns the item value. Isolation: none. Errors: duplicate IDs are diagnosed by the consumer. Cancellation: not applicable.
public struct CollectionItem<ItemID: Hashable & Sendable, Item: Sendable>: Sendable {
    public let id: ItemID
    public let value: Item

    /// Creates a stable collection item.
    /// Ownership: id and value are copied into the snapshot. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: ItemID, value: Item) {
        self.id = id
        self.value = value
    }
}

/// Immutable section snapshot delivered by a collection data source.
/// Ownership: the section owns its item array. Isolation: none. Errors: duplicate item IDs remain observable for diagnostics. Cancellation: not applicable.
public struct CollectionSection<
    SectionID: Hashable & Sendable, ItemID: Hashable & Sendable, Item: Sendable
>: Sendable {
    public let id: SectionID
    public let items: [CollectionItem<ItemID, Item>]

    /// Creates a section snapshot.
    /// Ownership: the section copies the item array. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: SectionID, items: [CollectionItem<ItemID, Item>]) {
        self.id = id
        self.items = items
    }
}

/// Immutable collection snapshot with stable section and item identity.
/// Ownership: the snapshot owns all copied arrays and values. Isolation: none. Errors: duplicate IDs are reported by diagnostics. Cancellation: stale revisions are discarded by the owner.
public struct CollectionSnapshot<
    SectionID: Hashable & Sendable, ItemID: Hashable & Sendable, Item: Sendable
>: Sendable {
    public let sections: [CollectionSection<SectionID, ItemID, Item>]
    public let revision: UInt64

    /// Creates a collection snapshot.
    /// Ownership: values are copied into the snapshot. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(sections: [CollectionSection<SectionID, ItemID, Item>], revision: UInt64 = 0) {
        self.sections = sections
        self.revision = revision
    }

    /// Flattens sections while preserving stable order and section context.
    /// Ownership: the returned array is owned by the caller. Isolation: none. Errors: none. Cancellation: not applicable.
    public var flattened: [(item: CollectionItem<ItemID, Item>, sectionIndex: Int, index: Int)] {
        sections.enumerated().flatMap { sectionIndex, section in
            section.items.enumerated().map { index, item in (item, sectionIndex, index) }
        }
    }
}

/// Presentation style for one row swipe action.
/// Ownership: the value is immutable and copied into a swipe configuration. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public enum SwipeActionStyle: Sendable, Hashable {
    case normal
    case destructive
}

/// Edge from which row actions are revealed.
/// Ownership: the value is immutable. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SwipeEdge: Sendable, Hashable {
    case leading
    case trailing
}

/// Semantic action description independent of UIKit/AppKit.
/// Ownership: the value owns copied metadata. Isolation: none. Errors: empty IDs/titles are
/// accepted and remain consumer-visible. Cancellation: not applicable.
public struct SwipeAction: Sendable, Hashable {
    public let id: String
    public let title: String
    public let style: SwipeActionStyle
    public let tint: ThemeColorRole?

    /// Creates a row swipe action.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        id: String,
        title: String,
        style: SwipeActionStyle = .normal,
        tint: ThemeColorRole? = nil
    ) {
        self.id = id
        self.title = title
        self.style = style
        self.tint = tint
    }
}

/// Immutable actions revealed from one row edge.
/// Ownership: the configuration owns its action array. Isolation: none. Errors: an empty array
/// means that no reveal affordance is available. Cancellation: not applicable.
public struct SwipeActionsConfiguration: Sendable, Hashable {
    public let actions: [SwipeAction]
    public let performsFirstActionWithFullSwipe: Bool

    /// Creates a row swipe configuration.
    /// Ownership: actions are copied. Isolation: none. Errors: empty actions are valid. Cancellation: not applicable.
    public init(actions: [SwipeAction], performsFirstActionWithFullSwipe: Bool = true) {
        self.actions = actions
        self.performsFirstActionWithFullSwipe = performsFirstActionWithFullSwipe
    }
}

/// Invocation of one currently materialized row action.
/// Ownership: the invocation owns immutable identity and a bounded completion token. Isolation:
/// Sendable value; completion delivery is controlled by the adapter. Errors: completion is
/// idempotent at the adapter boundary. Cancellation: stale invocations are ignored by the owner.
public struct SwipeActionInvocation<ItemID: Hashable & Sendable>: Sendable {
    public let itemID: ItemID
    public let actionID: String
    public let edge: SwipeEdge
    public let complete: @Sendable (_ shouldDismiss: Bool) -> Void

    /// Creates an action invocation.
    /// Ownership: identity is copied and completion is retained by the invocation. Isolation:
    /// completion must be safe to call from its delivery context. Errors: none. Cancellation: the
    /// adapter may make completion a no-op after cancellation or timeout.
    public init(
        itemID: ItemID,
        actionID: String,
        edge: SwipeEdge,
        complete: @escaping @Sendable (_ shouldDismiss: Bool) -> Void
    ) {
        self.itemID = itemID
        self.actionID = actionID
        self.edge = edge
        self.complete = complete
    }
}

/// Committed reveal state for one materialized row.
/// Ownership: the state is copied by render/input bridges. Isolation: none. Errors: offsets are
/// normalized by the state machine. Cancellation: cancelled state returns to closed.
public enum SwipeRevealState: Sendable, Hashable {
    case closed
    case revealing(edge: SwipeEdge, offset: Double)
    case open(edge: SwipeEdge, offset: Double)
    case settling(edge: SwipeEdge, offset: Double)
    case cancelled
}

/// Immutable reveal update consumed by a platform renderer.
/// Ownership: the update is copied into a bounded pipe. Isolation: none. Errors: nil item means
/// that the active reveal was closed. Cancellation: cancelled updates terminate the interaction.
public struct SwipeRevealUpdate<ItemID: Hashable & Sendable>: Sendable, Hashable {
    public let itemID: ItemID?
    public let state: SwipeRevealState

    /// Creates a reveal update.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(itemID: ItemID?, state: SwipeRevealState) {
        self.itemID = itemID
        self.state = state
    }
}

/// Type-erased reveal boundary used by platform input and layer adapters.
/// Ownership: the container owns reveal state and materialized row nodes. Isolation: MainActor.
/// Errors: inactive or unsupported gestures are ignored. Cancellation: cancel releases the active
/// row and any pending action invocation.
@MainActor
public protocol SwipeRevealContainer: AnyObject {
    func beginSwipeReveal(at point: LayoutPoint, edge: SwipeEdge) -> Bool
    func updateSwipeReveal(translation: Double)
    func finishSwipeReveal(velocity: Double)
    func cancelSwipeReveal()
    func closeSwipeReveal()
    var activeSwipeNode: Node? { get }
    var activeSwipeState: SwipeRevealState { get }
    var activeSwipeConfiguration: SwipeActionsConfiguration? { get }
    @discardableResult
    func invokeSwipeAction(
        actionID: String,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> Bool
}

/// Immutable data-source boundary for collection content.
/// Ownership: the data source owns its Flux and content policy. Isolation: snapshots may be observed off MainActor; content is built on MainActor. Errors: malformed snapshots are diagnosed by the collection. Cancellation: subscribers cancel through Flux subscriptions.
public protocol CollectionDataSource: Sendable {
    associatedtype SectionID: Hashable & Sendable
    associatedtype ItemID: Hashable & Sendable
    associatedtype Item: Sendable

    nonisolated var snapshots: Flux<CollectionSnapshot<SectionID, ItemID, Item>> { get }

    /// Builds platform-neutral content for one item without allocating native objects.
    @MainActor @NodeBuilder func content(
        for item: Item,
        context: ItemContext<ItemID>
    ) -> NodeContent
}

/// The visible and overscan ranges for one virtualization pass.
/// Ownership: the window is an immutable calculation result. Isolation: none. Errors: invalid inputs produce an empty or bounded window. Cancellation: stale windows are discarded by the MainActor owner.
public struct VirtualizationWindow: Sendable, Hashable {
    public let visibleRange: Range<Int>
    public let renderedRange: Range<Int>

    /// Creates a virtualization window.
    /// Ownership: ranges are copied. Isolation: none. Errors: malformed ranges are normalized to empty. Cancellation: not applicable.
    public init(visibleRange: Range<Int>, renderedRange: Range<Int>) {
        self.visibleRange = visibleRange
        self.renderedRange = renderedRange
    }

    /// Computes visible and overscan ranges without allocating item nodes.
    /// Ownership: the result is owned by the caller. Isolation: none. Errors: non-finite or non-positive estimates produce empty ranges. Cancellation: not applicable.
    public static func compute(
        totalCount: Int,
        viewportLength: Double,
        scrollOffset: Double,
        estimatedItemLength: Double,
        overscanFactor: Double = 2
    ) -> Self {
        compute(
            totalCount: totalCount,
            viewportLength: viewportLength,
            scrollOffset: scrollOffset,
            estimatedItemLength: estimatedItemLength,
            itemLengths: [:],
            overscanFactor: overscanFactor
        )
    }

    /// Computes visible and overscan ranges taking known measured item lengths into account.
    /// Ownership: the result is owned by the caller. Isolation: none. Errors: non-finite estimates produce empty ranges. Cancellation: not applicable.
    public static func compute(
        totalCount: Int,
        viewportLength: Double,
        scrollOffset: Double,
        estimatedItemLength: Double,
        itemLengths: [Int: Double],
        overscanFactor: Double = 2
    ) -> Self {
        guard totalCount > 0, viewportLength.isFinite, viewportLength > 0,
            scrollOffset.isFinite, estimatedItemLength.isFinite, estimatedItemLength > 0
        else { return Self(visibleRange: 0..<0, renderedRange: 0..<0) }

        if itemLengths.isEmpty {
            let rawStart = max(0, Int((scrollOffset / estimatedItemLength).rounded(.down)))
            let start = min(max(0, totalCount - 1), rawStart)
            let visibleCount = max(1, Int(ceil(viewportLength / estimatedItemLength)))
            let visibleEnd = max(start, min(totalCount, start + visibleCount))
            let overscan = max(
                0,
                Int(
                    ceil(
                        Double(visibleCount) * max(0, overscanFactor.isFinite ? overscanFactor : 0))
                ))
            let renderedStart = min(start, max(0, start - overscan))
            let renderedEnd = max(renderedStart, min(totalCount, visibleEnd + overscan))
            return Self(
                visibleRange: start..<visibleEnd, renderedRange: renderedStart..<renderedEnd)
        }

        var currentOffset = 0.0
        var visibleStart: Int? = nil
        var visibleEnd = totalCount

        for index in 0..<totalCount {
            let itemLength = itemLengths[index] ?? estimatedItemLength
            let nextOffset = currentOffset + itemLength
            if visibleStart == nil && nextOffset > scrollOffset {
                visibleStart = index
            }
            if visibleStart != nil && currentOffset >= scrollOffset + viewportLength {
                visibleEnd = index
                break
            }
            currentOffset = nextOffset
        }

        let start = min(max(0, totalCount - 1), visibleStart ?? 0)
        let end = max(start, min(totalCount, visibleEnd))
        let visibleCount = max(1, end - start)
        let overscan = max(
            0,
            Int(ceil(Double(visibleCount) * max(0, overscanFactor.isFinite ? overscanFactor : 0))))
        let renderedStart = min(start, max(0, start - overscan))
        let renderedEnd = max(renderedStart, min(totalCount, end + overscan))
        return Self(visibleRange: start..<end, renderedRange: renderedStart..<renderedEnd)
    }
}

/// MainActor-owned bounded pool for reusable Node instances, partitioned by reuse identifier so
/// heterogeneous cell kinds (e.g. a text row vs. a media tile) never dequeue into each other.
/// Ownership: the pool owns recycled nodes until dequeue or drain. Isolation: MainActor. Errors: missing reuse IDs return nil. Cancellation: drain disposes every pooled node.
@MainActor
public final class CellReusePool {
    private var storage: [String: [Node]] = [:]
    private let limitPerIdentifier: Int

    /// Creates an empty pool.
    /// Ownership: no nodes are retained. Isolation: MainActor. Errors: `limitPerIdentifier` below 1 is treated as 1. Cancellation: no work starts.
    public init(limitPerIdentifier: Int = 8) {
        self.limitPerIdentifier = max(1, limitPerIdentifier)
    }

    /// Recycles a node after its owner has removed it from the tree, under a given reuse
    /// identifier's pool. A pool already at `limitPerIdentifier` disposes the node instead of
    /// retaining it, so pool growth stays bounded under fast scroll.
    /// Ownership: the pool retains the node, or disposes it if the identifier's pool is full. Isolation: MainActor. Errors: disposed nodes are ignored. Cancellation: reuse preparation is synchronous.
    public func recycle(_ node: Node, reuseID: String) {
        guard node.lifecycleState != .disposed else { return }
        guard storage[reuseID, default: []].count < limitPerIdentifier else {
            node.dispose()
            return
        }
        if let reusable = node as? any ReusableNode { reusable.prepareForReuse() }
        storage[reuseID, default: []].append(node)
    }

    /// Dequeues the most recently recycled node for a reuse identifier.
    /// Ownership: ownership transfers to the caller. Isolation: MainActor. Errors: no node returns nil. Cancellation: none.
    public func dequeue(reuseID: String) -> Node? { storage[reuseID]?.popLast() }

    /// Number of nodes currently pooled under a reuse identifier. Introspection for tests and
    /// in-app validation (see card 08's reuse measurement).
    /// Ownership: the returned count does not transfer ownership. Isolation: MainActor. Errors: an unknown identifier returns 0. Cancellation: not applicable.
    public func pooledCount(reuseID: String) -> Int { storage[reuseID]?.count ?? 0 }

    /// Disposes all retained nodes, across every reuse identifier, and clears the pool.
    /// Ownership: the pool releases every node. Isolation: MainActor. Errors: none. Cancellation: pooled work is terminated by disposal.
    public func drain() {
        storage.values.flatMap { $0 }.forEach { $0.dispose() }
        storage.removeAll()
    }
}

/// Opt-in reset boundary for nodes entering a reuse pool.
/// Ownership: the collection invokes the node synchronously. Isolation: MainActor. Errors: reset failures are contained by the node. Cancellation: owners must cancel bindings/tasks here.
@MainActor
public protocol ReusableNode: AnyObject {
    func prepareForReuse()
}

/// MainActor-owned state store keyed by stable collection item IDs.
/// Ownership: the store owns state values until removal. Isolation: MainActor. Errors: missing IDs return nil. Cancellation: clearing an ID cancels its demand.
@MainActor
public final class KeyedItemStateStore<ItemID: Hashable & Sendable, State: Sendable> {
    private var values: [ItemID: State] = [:]
    private var demands: [ItemID: ItemDemand] = [:]

    /// Creates an empty keyed state store.
    /// Ownership: no values are retained. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {}

    /// Returns state for a stable item ID.
    /// Ownership: the returned value is copied. Isolation: MainActor. Errors: unknown IDs return nil. Cancellation: not applicable.
    public func state(for id: ItemID) -> State? { values[id] }

    /// Stores state without coupling it to a reusable node.
    /// Ownership: the store retains a copied Sendable value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func setState(_ state: State, for id: ItemID) { values[id] = state }

    /// Starts an owner-scoped demand for one item.
    /// Ownership: the returned token owns cancellation of this demand. Isolation: MainActor. Errors: replacing a demand cancels the old one. Cancellation: token or removal cancels exactly once.
    @discardableResult
    public func beginDemand(for id: ItemID, onCancel: @escaping @MainActor () -> Void) -> ItemDemand
    {
        demands[id]?.cancel()
        let demand = ItemDemand(onCancel: onCancel)
        demands[id] = demand
        return demand
    }

    /// Removes state and demand for an item that left the snapshot.
    /// Ownership: removed values are released. Isolation: MainActor. Errors: unknown IDs are ignored. Cancellation: the item's demand is cancelled.
    public func remove(_ id: ItemID) {
        values.removeValue(forKey: id)
        demands.removeValue(forKey: id)?.cancel()
    }

    /// Retains state only for IDs present in the latest stable snapshot.
    /// Ownership: the store releases stale values. Isolation: MainActor. Errors: duplicates are naturally collapsed. Cancellation: stale demands are cancelled.
    public func retainOnly(_ ids: some Sequence<ItemID>) {
        let retained = Set(ids)
        for id in Set(values.keys).subtracting(retained) { remove(id) }
        for id in Set(demands.keys).subtracting(retained) { remove(id) }
    }

    /// Number of IDs currently holding state. Introspection for tests and bounded-growth
    /// validation (see card 08's memory measurement).
    /// Ownership: the returned count does not transfer ownership. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public var count: Int { values.count }
}

/// Cancellable owner token for one keyed item demand.
/// Ownership: the token owns one cancellation callback. Isolation: MainActor. Errors: repeated cancellation is idempotent. Cancellation: callback runs at most once.
@MainActor
public final class ItemDemand {
    private var onCancel: (@MainActor () -> Void)?

    fileprivate init(onCancel: @escaping @MainActor () -> Void) { self.onCancel = onCancel }

    /// Cancels this demand once.
    /// Ownership: releases the callback after invocation. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public func cancel() {
        guard let callback = onCancel else { return }
        onCancel = nil
        callback()
    }
}

/// Selection policy for virtualized collections.
/// Ownership: the value is copied by the collection. Isolation: MainActor when changed. Errors: none. Cancellation: selection changes are bounded actions.
public enum SelectionMode: Sendable, Hashable {
    case none
    case single
    case multiple
}

/// Collection content lifecycle state used by empty/loading presentations.
/// Ownership: the state is copied by the view. Isolation: MainActor when changed. Errors: none. Cancellation: loading work is owned by the caller.
public enum CollectionContentState: Sendable, Hashable {
    case empty
    case loading
    case ready
}

/// A typed context-menu action exposed by a collection cell.
/// Ownership: the action is copied into a bounded request pipe. Isolation: none. Errors: none. Cancellation: subscribers own cancellation.
public struct CollectionContextMenuAction: Sendable, Hashable {
    public let id: String
    public let title: String

    /// Creates a context-menu action.
    /// Ownership: strings are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: String, title: String) { self.id = id; self.title = title }
}

/// Immutable context-menu description owned by a collection cell.
/// Ownership: the menu owns its action array. Isolation: none. Errors: none. Cancellation: invoking an action is handled by the consumer.
public struct CollectionContextMenu: Sendable, Hashable {
    public let actions: [CollectionContextMenuAction]

    /// Creates a menu description.
    /// Ownership: actions are copied. Isolation: none. Errors: none. Cancellation: no work starts.
    public init(actions: [CollectionContextMenuAction]) { self.actions = actions }
}

/// Request to present a context menu for one stable item ID.
/// Ownership: the request is copied into a bounded pipe. Isolation: none. Errors: unknown IDs are not emitted. Cancellation: subscribers cancel independently.
public struct CollectionContextMenuRequest<ItemID: Hashable & Sendable>: Sendable, Hashable {
    public let itemID: ItemID
    public let menu: CollectionContextMenu

    /// Creates a menu request.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(itemID: ItemID, menu: CollectionContextMenu) {
        self.itemID = itemID; self.menu = menu
    }
}

/// Grid layout policy used by GridView and CollectionView.
/// Ownership: the policy is copied by the collection. Isolation: none. Errors: invalid counts/spacing normalize at layout. Cancellation: not applicable.
public enum GridLayout: Sendable, Hashable {
    case fixed(columns: Int, spacing: Double)
    case adaptive(minItemWidth: Double, spacing: Double)
    case masonry(columns: Int, spacing: Double)
    case custom(columns: [GridTrack])
}

/// One custom grid track.
/// Ownership: the track is copied by GridLayout. Isolation: none. Errors: invalid widths normalize to zero. Cancellation: not applicable.
public struct GridTrack: Sendable, Hashable {
    public let minimum: Double
    public let maximum: Double?

    /// Creates a custom track range.
    /// Ownership: values are copied. Isolation: none. Errors: negative/non-finite values normalize to zero. Cancellation: not applicable.
    public init(minimum: Double = 0, maximum: Double? = nil) {
        let normalizedMinimum = max(0, minimum.isFinite ? minimum : 0)
        self.minimum = normalizedMinimum
        self.maximum = maximum.flatMap { $0.isFinite ? max(normalizedMinimum, $0) : nil }
    }
}

/// Platform-neutral virtualized collection base.
/// Ownership: the view owns item snapshots, rendered nodes, reuse pool, and bounded action pipes. Isolation: MainActor. Errors: duplicate IDs are ignored after the first occurrence. Cancellation: stale generations and disposed cells are discarded.
@MainActor
open class VirtualizedView<Item: Sendable, ItemID: Hashable & Sendable>: ScrollNode,
    SwipeRevealContainer
{
    public var items: [Item] = []
    public private(set) var itemIDs: [ItemID] = []
    public var estimatedItemLength: Double = 44
    public var overscanFactor: Double = 2
    public var selectionMode: SelectionMode = .none
    public private(set) var selectedItems: Set<ItemID> = []
    public private(set) var focusedItemID: ItemID?
    public private(set) var contentState: CollectionContentState = .empty
    public let selectionChanges: ActionPipe<Set<ItemID>>
    public let refreshRequests: ActionPipe<Void>
    public let prefetchRequests: ActionPipe<[ItemID]>
    public let contextMenuRequests: ActionPipe<CollectionContextMenuRequest<ItemID>>
    public let swipeActionInvocations: ActionPipe<SwipeActionInvocation<ItemID>>
    public let swipeRevealChanges: ActionPipe<SwipeRevealUpdate<ItemID>>
    public var emptyStateNode: Node?
    public var loadingStateNode: Node?
    public var isLoading = false {
        didSet { if isLoading { contentState = .loading } }
    }
    public var contextMenu: (@MainActor (Item, ItemContext<ItemID>) -> CollectionContextMenu?)?
    /// Provides actions lazily for a materialized row. AppKit/UIKit adapters resolve this only
    /// while the row is current; tvOS does not invoke it. Ownership: the closure is retained by
    /// the view. Isolation: MainActor. Errors: nil/empty configuration means no affordance.
    public var leadingSwipeActions:
        (@MainActor (Item, ItemContext<ItemID>) -> SwipeActionsConfiguration?)?
    /// Provides trailing actions lazily for a materialized row. See `leadingSwipeActions` for
    /// ownership and lifecycle semantics.
    public var trailingSwipeActions:
        (@MainActor (Item, ItemContext<ItemID>) -> SwipeActionsConfiguration?)?
    public var reuseIdentifier: (@MainActor (Item) -> String)?
    public var configureReusedCell: (@MainActor (Node, Item, ItemContext<ItemID>) -> Bool)?
    public let reusePool: CellReusePool
    /// Per-item presentation state (e.g. a hosted `CollectionCell`'s nested scroll offset),
    /// keyed by stable item ID and pruned to the live item set on every `updateItems`/
    /// `updateSnapshot`. Exposed so a caller can also register `beginDemand(for:onCancel:)`
    /// against the same IDs `captureItemState`/`restoreItemState` key their state by.
    public let itemState = KeyedItemStateStore<ItemID, ItemPresentationState>()
    /// Captured just before a cell is recycled or disposed. Runs synchronously inside the same
    /// update that removes the cell.
    public var captureItemState: (@MainActor (Node, ItemContext<ItemID>) -> ItemPresentationState?)?
    /// Applied immediately after a cell is materialized or reconfigured for an item — before the
    /// cell is returned to the reconciler, so restoration is visible on the first rendered frame.
    public var restoreItemState:
        (@MainActor (Node, ItemContext<ItemID>, ItemPresentationState) -> Void)?
    public private(set) var virtualizationWindow = VirtualizationWindow(
        visibleRange: 0..<0, renderedRange: 0..<0)
    public private(set) var sectionCount: Int = 0
    public var sectionHeader: (@MainActor (Int) -> Node?)?
    /// Pins the section currently crossing the leading edge's header at that edge; the next
    /// section's header pushes it out as its own leading edge approaches. Default `false`
    /// preserves ordinary in-flow header layout — headers still materialize interleaved with
    /// their section's items (see `updateRenderedWindow`), just with no position override.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: turning this off clears `pinnedSectionIndex` on the next `updateRenderedWindow()`.
    public var pinsSectionHeaders: Bool = false
    /// The section index whose header is currently pinned to the leading edge, or `nil` when
    /// `pinsSectionHeaders` is `false` or the scroll position is before the first section.
    public private(set) var pinnedSectionIndex: Int?
    /// Number of measured item extents currently retained. Introspection for tests validating
    /// that `measuredLengths` is pruned alongside removed items rather than growing unbounded.
    public var measuredLengthCount: Int { measuredLengths.count }

    private let itemID: @MainActor (Item) -> ItemID
    private let cell: @MainActor (Item, ItemContext<ItemID>) -> Node
    private let reconciler = NodeReconciliationController()
    private var itemsByKey: [String: (item: Item, id: ItemID, index: Int, sectionIndex: Int)] = [:]
    private var headerByKey: [String: Int] = [:]
    private var measuredLengths: [String: Double] = [:]
    /// Reuse-pool identifier a materialized cell was built or reconfigured under, recovered at
    /// recycle time since the removed node no longer carries its originating item. Only item
    /// cells are tagged; headers and spacers are never pooled and are always disposed on removal.
    private var reusePoolKeys: [ObjectIdentifier: String] = [:]
    /// Item context a materialized cell was built or reconfigured for, recovered at recycle time
    /// so `captureItemState` can be called with the item it belongs to even though the node
    /// itself carries no back-reference to it.
    private var materializedContext: [ObjectIdentifier: ItemContext<ItemID>] = [:]
    private var swipeRevealItemID: ItemID?
    private var swipeRevealEdge: SwipeEdge?
    private var swipeRevealStartOffset: Double = 0
    private var swipeRevealConfiguration: SwipeActionsConfiguration?

    /// Creates a virtualized view with stable item identity and a cell factory.
    /// Ownership: the view retains the closures and bounded pipes. Isolation: MainActor. Errors: invalid estimates normalize during window calculation. Cancellation: no work starts.
    public init(
        axis: ScrollAxis = .vertical,
        itemID: @escaping @MainActor (Item) -> ItemID,
        cell: @escaping @MainActor (Item, ItemContext<ItemID>) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.itemID = itemID
        self.cell = cell
        selectionChanges = ActionPipe(capacity: 32)
        refreshRequests = ActionPipe(capacity: 8)
        prefetchRequests = ActionPipe(capacity: 8)
        contextMenuRequests = ActionPipe(capacity: 16)
        swipeActionInvocations = ActionPipe(capacity: 32)
        swipeRevealChanges = ActionPipe(capacity: 32)
        reusePool = CellReusePool()
        var draft = LayoutStyle.Draft(style)
        switch axis {
        case .vertical:
            draft.flexDirection = .column
        case .horizontal:
            draft.flexDirection = .row
        case .both:
            break
        }
        super.init(axis: axis, style: LayoutStyle.bake(draft), environment: environment)
    }

    /// Replaces items and computes a new stable-ID render window.
    /// Ownership: values are copied into the MainActor view. Isolation: MainActor. Errors: duplicate IDs keep the first item. Cancellation: old rendered cells are reconciled and disposed or recycled by the owner.
    public func updateItems(_ newItems: [Item]) {
        let anchorID = virtualizationWindow.visibleRange.compactMap {
            itemIDs.indices.contains($0) ? itemIDs[$0] : nil
        }.first
        let oldAnchorOffset = axis == .horizontal ? state.offset.x : state.offset.y
        items = newItems
        contentState = isLoading ? .loading : (newItems.isEmpty ? .empty : .ready)
        itemIDs.removeAll(keepingCapacity: true)
        itemsByKey.removeAll(keepingCapacity: true)
        for (index, item) in newItems.enumerated() {
            let id = itemID(item)
            let key = String(reflecting: id)
            guard itemsByKey[key] == nil else { continue }
            itemIDs.append(id)
            itemsByKey[key] = (item, id, index, 0)
        }
        updateRenderedWindow()
        if let anchorID, let newIndex = itemIDs.firstIndex(of: anchorID) {
            let target = Double(newIndex) * max(0, estimatedItemLength)
            let delta = target - oldAnchorOffset
            if abs(delta) > 0 {
                _ = super.moveBy(
                    x: axis == .horizontal ? delta : 0, y: axis == .vertical ? delta : 0)
                updateRenderedWindow()
            }
        }
        pruneItemScopedState()
    }

    /// Replaces items from a stable-ID section snapshot and retains section context.
    /// Ownership: values are copied into the MainActor view. Isolation: MainActor. Errors: duplicate item IDs keep the first occurrence. Cancellation: stale cells are reconciled by generation.
    public func updateSnapshot<SectionID: Hashable & Sendable>(
        _ snapshot: CollectionSnapshot<SectionID, ItemID, Item>
    ) {
        sectionCount = snapshot.sections.count
        headerByKey.removeAll(keepingCapacity: true)
        var flattened: [Item] = []
        itemsByKey.removeAll(keepingCapacity: true)
        itemIDs.removeAll(keepingCapacity: true)
        for (sectionIndex, section) in snapshot.sections.enumerated() {
            headerByKey[String(reflecting: section.id)] = sectionIndex
            for item in section.items {
                let key = String(reflecting: item.id)
                guard itemsByKey[key] == nil else { continue }
                let index = flattened.count
                flattened.append(item.value)
                itemIDs.append(item.id)
                itemsByKey[key] = (item.value, item.id, index, sectionIndex)
            }
        }
        items = flattened
        contentState = isLoading ? .loading : (flattened.isEmpty ? .empty : .ready)
        updateRenderedWindow()
        pruneItemScopedState()
    }

    /// Drops `itemState` entries (and any `beginDemand` registered against them) and
    /// `measuredLengths` entries for IDs no longer in the current item set. Called once per
    /// `updateItems`/`updateSnapshot`, after the departing window's cells have already had a
    /// chance to capture state during recycle — so a capture that just landed for a genuinely
    /// removed item is pruned in the same pass rather than lingering until the next update.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: pruned demands are cancelled by `KeyedItemStateStore.retainOnly`.
    private func pruneItemScopedState() {
        itemState.retainOnly(itemIDs)
        guard !measuredLengths.isEmpty else { return }
        let liveKeys = Set(itemIDs.map { String(reflecting: $0) })
        measuredLengths = measuredLengths.filter { liveKeys.contains($0.key) }
    }

    /// Commits a measured item length while preserving the leading scroll anchor.
    /// Ownership: the measurement is copied into view state. Isolation: MainActor. Errors: non-positive lengths are ignored. Cancellation: no asynchronous work starts.
    public func updateMeasuredItem(id: ItemID, length: Double) {
        guard length.isFinite, length > 0 else { return }
        let key = String(reflecting: id)
        let old = measuredLengths[key] ?? estimatedItemLength
        measuredLengths[key] = length
        guard let index = itemIDs.firstIndex(of: id),
            let anchor = virtualizationWindow.visibleRange.first
        else {
            updateVirtualViewport(
                length: axis == .horizontal ? state.viewportSize.width : state.viewportSize.height,
                offset: axis == .horizontal ? state.offset.x : state.offset.y)
            return
        }
        if index < anchor {
            let delta = length - old
            _ = super.moveBy(x: axis == .horizontal ? delta : 0, y: axis == .vertical ? delta : 0)
        }
        updateVirtualViewport(
            length: axis == .horizontal ? state.viewportSize.width : state.viewportSize.height,
            offset: axis == .horizontal ? state.offset.x : state.offset.y)
    }

    /// Updates the viewport length and offset used by virtualization.
    /// Ownership: values are copied into ScrollNode state. Isolation: MainActor. Errors: bounds clamp in ScrollNode. Cancellation: stale rendered windows are replaced synchronously.
    public func updateVirtualViewport(length: Double, offset: Double) {
        let safeLength = max(0, length.isFinite ? length : 0)
        let contentLength = safeLength == 0 ? 0 : totalContentLength(viewportLength: safeLength)
        let size =
            axis == .horizontal
            ? MeasuredSize(width: safeLength, height: 0)
            : MeasuredSize(width: 0, height: safeLength)
        let contentSize =
            axis == .horizontal
            ? MeasuredSize(width: contentLength, height: 0)
            : MeasuredSize(width: 0, height: contentLength)
        updateViewport(viewportSize: size, contentSize: contentSize)
        _ = moveBy(
            x: axis == .horizontal ? offset - state.offset.x : 0,
            y: axis == .vertical ? offset - state.offset.y : 0)
        updateRenderedWindow()
    }

    /// Selects an item according to the configured selection mode.
    /// Ownership: the selected ID is copied into view state. Isolation: MainActor. Errors: unknown IDs and `.none` are ignored. Cancellation: no asynchronous work starts.
    public func select(_ id: ItemID) {
        guard itemIDs.contains(id), selectionMode != .none else { return }
        switch selectionMode {
        case .none: return
        case .single: selectedItems = [id]
        case .multiple:
            if selectedItems.contains(id) {
                selectedItems.remove(id)
            } else {
                selectedItems.insert(id)
            }
        }
        _ = selectionChanges.send(selectedItems)
    }

    /// Deselects all currently selected items.
    /// Ownership: resets selection state. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func deselectAll() {
        guard !selectedItems.isEmpty else { return }
        selectedItems.removeAll()
        _ = selectionChanges.send(selectedItems)
    }

    /// Sets or clears the focused stable item and reveals it when present.
    /// Ownership: the ID is copied into view state. Isolation: MainActor. Errors: unknown IDs clear focus. Cancellation: no asynchronous work starts.
    public func setFocusedItem(_ id: ItemID?) {
        guard let id, let index = itemIDs.firstIndex(of: id) else {
            focusedItemID = nil
            return
        }
        focusedItemID = id
        let start = Double(index) * max(0, estimatedItemLength)
        _ = reveal(
            frame: LayoutFrame(
                origin: LayoutPoint(
                    x: axis == .horizontal ? start : 0, y: axis == .vertical ? start : 0),
                width: axis == .horizontal ? estimatedItemLength : state.viewportSize.width,
                height: axis == .vertical ? estimatedItemLength : state.viewportSize.height
            ), alignment: .nearest)
    }

    /// Requests the context menu for an item using the typed menu policy.
    /// Ownership: the emitted request owns a copied menu. Isolation: MainActor. Errors: unknown IDs or absent menus return nil. Cancellation: bounded pipe overflow is returned.
    @discardableResult
    public func requestContextMenu(for id: ItemID) -> AsyncStream<
        CollectionContextMenuRequest<ItemID>
    >.Continuation.YieldResult? {
        guard let record = itemsByKey[String(reflecting: id)], let contextMenu else { return nil }
        let context = ItemContext(
            itemID: record.id, index: record.index, sectionIndex: record.sectionIndex)
        guard let menu = contextMenu(record.item, context) else { return nil }
        return contextMenuRequests.send(CollectionContextMenuRequest(itemID: id, menu: menu))
    }

    /// Resolves current swipe actions for a stable item ID without consulting an index.
    /// Ownership: the returned configuration is caller-owned. Isolation: MainActor. Errors:
    /// unknown IDs and unsupported/empty providers return nil. Cancellation: no asynchronous work.
    public func swipeActions(
        for id: ItemID,
        edge: SwipeEdge
    ) -> SwipeActionsConfiguration? {
        guard let record = itemsByKey[String(reflecting: id)] else { return nil }
        let context = ItemContext(
            itemID: record.id, index: record.index, sectionIndex: record.sectionIndex)
        let configuration: SwipeActionsConfiguration?
        switch edge {
        case .leading:
            configuration = leadingSwipeActions?(record.item, context)
        case .trailing:
            configuration = trailingSwipeActions?(record.item, context)
        }
        guard let configuration, !configuration.actions.isEmpty else { return nil }
        return configuration
    }

    /// Begins a reveal session for the current stable item ID.
    /// Ownership: the view owns the session state. Isolation: MainActor. Errors: unknown IDs or
    /// empty configurations return false. Cancellation: a previous reveal is closed first.
    @discardableResult
    public func beginSwipeReveal(for id: ItemID, edge: SwipeEdge) -> Bool {
        guard let configuration = swipeActions(for: id, edge: edge) else { return false }
        if swipeRevealItemID != id || swipeRevealEdge != edge {
            closeSwipeReveal()
        }
        swipeRevealItemID = id
        swipeRevealEdge = edge
        swipeRevealConfiguration = configuration
        swipeRevealStartOffset = currentSwipeRevealOffset
        return true
    }

    /// Begins a reveal session at the specified coordinate within the collection.
    /// Ownership: the view owns the session state. Isolation: MainActor. Errors: points outside
    /// rows or rows with empty configurations return false. Cancellation: a previous reveal is closed first.
    @discardableResult
    public func beginSwipeReveal(at point: LayoutPoint, edge: SwipeEdge) -> Bool {
        guard let id = itemID(at: point) else { return false }
        return beginSwipeReveal(for: id, edge: edge)
    }

    public var activeSwipeNode: Node? {
        guard let id = swipeRevealItemID else { return nil }
        return materializedNode(for: id)
    }

    public var activeSwipeState: SwipeRevealState { lastSwipeRevealState }
    public var activeSwipeConfiguration: SwipeActionsConfiguration? { swipeRevealConfiguration }

    /// Updates the active reveal using a signed horizontal translation.
    /// Leading actions use a positive offset; trailing actions use a negative offset. Ownership:
    /// state remains owned by the view. Isolation: MainActor. Errors: inactive sessions are ignored.
    /// Cancellation: callers should use `cancelSwipeReveal()` for interruption.
    public func updateSwipeReveal(translation: Double) {
        guard let itemID = swipeRevealItemID else { return }
        let desiredEdge: SwipeEdge = translation >= 0 ? .leading : .trailing
        if desiredEdge != swipeRevealEdge {
            guard let configuration = swipeActions(for: itemID, edge: desiredEdge) else {
                emitSwipeReveal(itemID: itemID, state: .revealing(edge: desiredEdge, offset: 0))
                return
            }
            swipeRevealEdge = desiredEdge
            swipeRevealConfiguration = configuration
            swipeRevealStartOffset = 0
        }
        guard let edge = swipeRevealEdge, let configuration = swipeRevealConfiguration else {
            return
        }
        let sign = edge == .leading ? 1.0 : -1.0
        let width = Double(configuration.actions.count) * 72
        let fullSwipeWidth = activeSwipeNode?.calculatedFrame?.width ?? width
        let maximumOffset =
            configuration.performsFirstActionWithFullSwipe
            ? max(width, fullSwipeWidth)
            : width
        let offset =
            min(maximumOffset, max(0, sign * (swipeRevealStartOffset + translation))) * sign
        emitSwipeReveal(
            itemID: itemID,
            state: .revealing(edge: edge, offset: offset)
        )
    }

    /// Settles the active reveal using the current offset and gesture velocity.
    /// Ownership: the resulting state is copied into the update pipe. Isolation: MainActor.
    /// Errors: inactive sessions are ignored. Cancellation: cancelled sessions do not settle open.
    public func finishSwipeReveal(velocity: Double = 0) {
        guard let itemID = swipeRevealItemID, let edge = swipeRevealEdge,
            let configuration = swipeRevealConfiguration
        else { return }
        let sign = edge == .leading ? 1.0 : -1.0
        let width = Double(configuration.actions.count) * 72
        let offset = currentSwipeRevealOffset
        let rowWidth = activeSwipeNode?.calculatedFrame?.width ?? width
        let fullSwipeThreshold = max(width, rowWidth * 0.7)
        if configuration.performsFirstActionWithFullSwipe,
            abs(offset) >= fullSwipeThreshold,
            let firstAction = configuration.actions.first
        {
            _ = sendSwipeActionInvocation(actionID: firstAction.id, complete: { _ in })
            return
        }
        let shouldOpen = abs(velocity) > 500 ? velocity * sign > 0 : abs(offset) >= width / 2
        let target = shouldOpen ? width * sign : 0
        if shouldOpen {
            emitSwipeReveal(itemID: itemID, state: .open(edge: edge, offset: target))
        } else {
            emitSwipeReveal(itemID: itemID, state: .settling(edge: edge, offset: 0))
            closeSwipeReveal()
        }
    }

    /// Cancels and closes the active reveal session.
    /// Ownership: the view releases its session state. Isolation: MainActor. Errors: none.
    /// Cancellation: emits a terminal cancelled update.
    public func cancelSwipeReveal() {
        guard let itemID = swipeRevealItemID else { return }
        emitSwipeReveal(itemID: itemID, state: .cancelled)
        clearSwipeRevealState()
    }

    /// Closes any open reveal without emitting an action invocation.
    /// Ownership: session state is released by the view. Isolation: MainActor. Errors: none.
    /// Cancellation: active gesture state is discarded.
    public func closeSwipeReveal() {
        guard let itemID = swipeRevealItemID else { return }
        emitSwipeReveal(
            itemID: itemID, state: .settling(edge: swipeRevealEdge ?? .trailing, offset: 0))
        clearSwipeRevealState()
    }

    /// Invokes an action for the currently revealed item.
    /// Ownership: the invocation is copied into a bounded pipe. Isolation: MainActor. Errors:
    /// stale IDs, unknown actions and inactive reveals return nil. Cancellation: the completion
    /// closure may become a no-op after the adapter invalidates the session.
    @discardableResult
    public func sendSwipeActionInvocation(
        actionID: String,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> AsyncStream<SwipeActionInvocation<ItemID>>.Continuation.YieldResult? {
        guard let itemID = swipeRevealItemID, let edge = swipeRevealEdge,
            let configuration = swipeRevealConfiguration,
            configuration.actions.contains(where: { $0.id == actionID })
        else { return nil }
        let invocation = SwipeActionInvocation(
            itemID: itemID, actionID: actionID, edge: edge, complete: complete)
        let result = swipeActionInvocations.send(invocation)
        closeSwipeReveal()
        return result
    }

    /// Invokes an action by identifier for the currently revealed item.
    /// Ownership: the invocation is copied into a bounded pipe. Isolation: MainActor. Errors:
    /// stale IDs, unknown actions, and inactive reveals return false. Cancellation: the completion
    /// closure may become a no-op after the adapter invalidates the session.
    @discardableResult
    public func invokeSwipeAction(
        actionID: String,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> Bool {
        sendSwipeActionInvocation(actionID: actionID, complete: complete) != nil
    }

    private func itemID(at point: LayoutPoint) -> ItemID? {
        guard let viewportFrame = calculatedFrame,
            point.x >= viewportFrame.origin.x,
            point.x <= viewportFrame.origin.x + viewportFrame.width,
            point.y >= viewportFrame.origin.y,
            point.y <= viewportFrame.origin.y + viewportFrame.height
        else { return nil }
        let contentPoint = LayoutPoint(
            x: point.x + state.offset.x,
            y: point.y + state.offset.y
        )
        for child in subnodes.reversed() {
            guard let frame = child.calculatedFrame,
                contentPoint.x >= frame.origin.x,
                contentPoint.x <= frame.origin.x + frame.width,
                contentPoint.y >= frame.origin.y,
                contentPoint.y <= frame.origin.y + frame.height
            else { continue }
            guard let key = child.reconciliationDescriptor?.key else { continue }
            if let match = itemIDs.first(where: { String(reflecting: $0) == key }) {
                return match
            }
        }
        return nil
    }

    private func materializedNode(for id: ItemID) -> Node? {
        let key = String(reflecting: id)
        return subnodes.first { $0.reconciliationDescriptor?.key == key }
    }

    private var currentSwipeRevealOffset: Double {
        guard let itemID = swipeRevealItemID, let edge = swipeRevealEdge else { return 0 }
        if case let .revealing(activeEdge, offset) = lastSwipeRevealState,
            activeEdge == edge
        {
            return offset
        }
        if case let .open(activeEdge, offset) = lastSwipeRevealState,
            activeEdge == edge
        {
            return offset
        }
        _ = itemID
        return 0
    }

    private var lastSwipeRevealState: SwipeRevealState = .closed

    private func emitSwipeReveal(itemID: ItemID, state: SwipeRevealState) {
        lastSwipeRevealState = state
        _ = swipeRevealChanges.send(SwipeRevealUpdate(itemID: itemID, state: state))
    }

    private func clearSwipeRevealState() {
        swipeRevealItemID = nil
        swipeRevealEdge = nil
        swipeRevealStartOffset = 0
        swipeRevealConfiguration = nil
        lastSwipeRevealState = .closed
    }

    /// Requests a refresh through the bounded action pipe.
    /// Ownership: the action is copied into the pipe. Isolation: MainActor. Errors: overflow is reported by the pipe. Cancellation: subscribers cancel independently.
    @discardableResult
    public func requestRefresh() -> AsyncStream<Void>.Continuation.YieldResult {
        refreshRequests.send(())
    }

    /// Recomputes the rendered range after scroll or resize.
    /// Ownership: no mutable state escapes. Isolation: MainActor. Errors: invalid estimates render nothing. Cancellation: stale cells are removed before new cells are attached.
    public func updateRenderedWindow() {
        let length = axis == .horizontal ? state.viewportSize.width : state.viewportSize.height
        let offset = axis == .horizontal ? state.offset.x : state.offset.y
        var indexedLengths: [Int: Double] = [:]
        let itemGap = max(0, style.gap)
        for (index, id) in itemIDs.enumerated() {
            if let measured = measuredLengths[String(reflecting: id)] {
                indexedLengths[index] = measured + (index == itemIDs.count - 1 ? 0 : itemGap)
            }
        }
        virtualizationWindow = VirtualizationWindow.compute(
            totalCount: itemIDs.count, viewportLength: length, scrollOffset: offset,
            estimatedItemLength: estimatedItemLength + itemGap,
            itemLengths: indexedLengths,
            overscanFactor: overscanFactor)
        let leadingContentOffset = contentOffset(
            before: virtualizationWindow.renderedRange.lowerBound)
        let leadingSpacerLength = max(0, leadingContentOffset - itemGap)
        var allDescriptors: [NodeDescriptor] = []
        if leadingSpacerLength > 0 {
            allDescriptors.append(
                NodeDescriptor(
                    typeName: "VirtualizedLeadingSpacer",
                    key:
                        "virtualized-leading-spacer:\(virtualizationWindow.renderedRange.lowerBound):\(leadingSpacerLength)"
                )
            )
        }
        // Headers are interleaved with their section's items in flow order (header, then that
        // section's items, then the next section's header, ...) rather than all batched before
        // the rendered window — the latter would leave `contentOffset`/the leading spacer
        // accounting for header extents that never actually occupied the position the spacer math
        // assumed. `lastSection` seeds from whatever section precedes the window's first rendered
        // item, so a window that starts mid-section does not re-materialize a header that already
        // appeared earlier, off-window.
        var lastSection: Int?
        if let firstRenderedIndex = virtualizationWindow.renderedRange.first,
            itemIDs.indices.contains(firstRenderedIndex), firstRenderedIndex > 0,
            let previousRecord = itemsByKey[String(reflecting: itemIDs[firstRenderedIndex - 1])]
        {
            lastSection = previousRecord.sectionIndex
        }
        var naturallyRenderedSections: Set<Int> = []
        for index in virtualizationWindow.renderedRange {
            guard itemIDs.indices.contains(index) else { continue }
            let id = itemIDs[index]
            let key = String(reflecting: id)
            guard let record = itemsByKey[key] else { continue }
            if sectionHeader != nil, record.sectionIndex != lastSection {
                allDescriptors.append(
                    NodeDescriptor(
                        typeName: "SectionHeader", key: "header:\(record.sectionIndex)"))
                naturallyRenderedSections.insert(record.sectionIndex)
                lastSection = record.sectionIndex
            }
            allDescriptors.append(NodeDescriptor(typeName: "VirtualizedCell", key: key))
        }
        // Pinning can require a header whose section has scrolled entirely out of the rendered
        // window (a long section, scrolled deep into). Resolved here so the descriptor list —
        // and therefore the reconciler diff — includes it; positioned as an overlay below since
        // its natural flow slot already contributed to `leadingSpacerLength` above.
        var forcedPinnedHeaderKey: String?
        if pinsSectionHeaders, sectionHeader != nil {
            let leadingScrollOffset = offset
            let starts = sectionStartOffsets()
            pinnedSectionIndex =
                starts.filter { $0.value <= leadingScrollOffset }
                .max(by: { $0.value < $1.value })?.key
            if let pinnedSectionIndex, !naturallyRenderedSections.contains(pinnedSectionIndex) {
                let headerKey = "header:\(pinnedSectionIndex)"
                allDescriptors.insert(
                    NodeDescriptor(typeName: "SectionHeader", key: headerKey), at: 0)
                forcedPinnedHeaderKey = headerKey
            }
        } else {
            pinnedSectionIndex = nil
        }
        _ = reconciler.apply(to: self, descriptors: allDescriptors, generation: state.revision) {
            [self] descriptor in
            let key = descriptor.key ?? ""
            if descriptor.typeName == "VirtualizedLeadingSpacer" {
                let spacer = Node()
                var draft = LayoutStyle.Draft(spacer.style)
                draft.width = .fraction(1)
                draft.height = .points(leadingSpacerLength)
                draft.flexShrink = 0
                spacer.style = LayoutStyle.bake(draft)
                return spacer
            }
            if key.hasPrefix("header:"), let sectionIndex = Int(key.dropFirst(7)) {
                let header = self.sectionHeader?(sectionIndex) ?? Node()
                // A header materialized only because it's pinned, but whose section is outside
                // the rendered window, takes no flow space — its natural slot is already
                // reserved by the leading spacer above, so letting it *also* participate in flow
                // would double-count that space and push the rendered window's real content down.
                if key == forcedPinnedHeaderKey {
                    var draft = LayoutStyle.Draft(header.style)
                    draft.positionType = .absolute
                    header.style = LayoutStyle.bake(draft)
                }
                return header
            }
            guard let record = itemsByKey[key] else { return Node() }
            let context = ItemContext(
                itemID: record.id, index: record.index, sectionIndex: record.sectionIndex)
            let poolKey = reuseIdentifier?(record.item) ?? "VirtualizedCell"
            let resultNode: Node
            if let configureReusedCell,
                let reused = reusePool.dequeue(reuseID: poolKey),
                configureReusedCell(reused, record.item, context)
            {
                resultNode = prepareVirtualizedCell(reused)
            } else {
                resultNode = prepareVirtualizedCell(cell(record.item, context))
            }
            reusePoolKeys[ObjectIdentifier(resultNode)] = poolKey
            materializedContext[ObjectIdentifier(resultNode)] = context
            if let restoreItemState, let restored = itemState.state(for: record.id) {
                restoreItemState(resultNode, context, restored)
            }
            return resultNode
        } recycle: { [self] node in
            if let captureItemState, let context = materializedContext[ObjectIdentifier(node)],
                let captured = captureItemState(node, context)
            {
                itemState.setState(captured, for: context.itemID)
            }
            materializedContext.removeValue(forKey: ObjectIdentifier(node))
            guard let poolKey = reusePoolKeys.removeValue(forKey: ObjectIdentifier(node)),
                configureReusedCell != nil, node is any ReusableNode
            else {
                node.dispose()
                return
            }
            reusePool.recycle(node, reuseID: poolKey)
        }
        if pinsSectionHeaders, sectionHeader != nil {
            applyPinnedHeaderFrames(scrollOffset: offset)
        }
        let prefetch = virtualizationWindow.renderedRange.compactMap {
            itemIDs.indices.contains($0) ? itemIDs[$0] : nil
        }
        if !prefetch.isEmpty { _ = prefetchRequests.send(prefetch) }
        if let focusedItemID, !itemIDs.contains(focusedItemID) { self.focusedItemID = nil }
    }

    /// Explicitly frames every currently-materialized section header: the pinned one gets its
    /// leading-edge-clamped, push-out-aware position; every other header gets its natural flow
    /// position re-asserted (undoing a pin override from a prior call, since nothing else resets
    /// it once `apply(_:)` has overridden a node's `calculatedFrame`). Called once per
    /// `updateRenderedWindow()` when `pinsSectionHeaders` is on; a no-op set of headers is cheap
    /// (at most one pinned plus the rendered window's own, per the bounded-materialization
    /// invariant this card requires).
    /// Ownership: no value escapes. Isolation: MainActor. Errors: a header without a computable section start (stale/unmeasured) is left untouched. Cancellation: not applicable.
    private func applyPinnedHeaderFrames(scrollOffset: Double) {
        let starts = sectionStartOffsets()
        let crossLength = axis == .horizontal ? state.viewportSize.height : state.viewportSize.width
        for child in subnodes {
            guard let key = child.reconciliationDescriptor?.key, key.hasPrefix("header:"),
                let sectionIndex = Int(key.dropFirst(7)),
                let naturalStart = starts[sectionIndex]
            else { continue }
            let headerLength = measuredLengths[key] ?? estimatedItemLength
            var mainOrigin = naturalStart
            if sectionIndex == pinnedSectionIndex {
                mainOrigin = max(naturalStart, scrollOffset)
                if let nextStart = starts[sectionIndex + 1] {
                    mainOrigin = min(mainOrigin, nextStart - headerLength)
                }
            }
            let frame: LayoutFrame =
                axis == .horizontal
                ? LayoutFrame(
                    origin: LayoutPoint(x: mainOrigin, y: 0), width: headerLength,
                    height: crossLength)
                : LayoutFrame(
                    origin: LayoutPoint(x: 0, y: mainOrigin), width: crossLength,
                    height: headerLength)
            child.apply(
                LayoutResult(
                    placements: [LayoutPlacement(identity: child.id, frame: frame)],
                    treeIdentity: child.id, environmentRevision: 0, contentRevision: 0))
        }
    }

    /// Disposes the view: finishes every bounded pipe this class owns (beyond the ones
    /// `ScrollNode.dispose()` already finishes), drains the reuse pool — pooled-but-detached
    /// nodes are not `children` and would otherwise never be disposed — then disposes the
    /// materialized cell tree via `super.dispose()`.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: idempotent; a second call is a no-op via `LifecycleMachine`.
    open override func dispose() {
        reusePool.drain()
        reusePoolKeys.removeAll()
        materializedContext.removeAll()
        itemState.retainOnly([ItemID]())
        selectionChanges.finish()
        refreshRequests.finish()
        prefetchRequests.finish()
        contextMenuRequests.finish()
        swipeActionInvocations.finish()
        swipeRevealChanges.finish()
        super.dispose()
    }

    open override func didApplyLayoutResult(_ result: LayoutResult) {
        super.didApplyLayoutResult(result)
        if let frame = calculatedFrame,
            frame.width > 0,
            frame.height > 0,
            state.viewportSize.width != frame.width || state.viewportSize.height != frame.height
        {
            let viewportLength = axis == .horizontal ? frame.width : frame.height
            let contentLength = totalContentLength(viewportLength: viewportLength)
            let contentSize =
                axis == .horizontal
                ? MeasuredSize(width: contentLength, height: frame.height)
                : MeasuredSize(width: frame.width, height: contentLength)
            updateViewport(
                viewportSize: MeasuredSize(width: frame.width, height: frame.height),
                contentSize: contentSize
            )
            updateRenderedWindow()
        }
        var hasNewMeasurements = false
        for child in subnodes {
            guard let frame = child.calculatedFrame else { continue }
            let length = axis == .horizontal ? frame.width : frame.height
            guard length > 0, length.isFinite else { continue }
            guard let key = child.reconciliationDescriptor?.key,
                itemsByKey[key] != nil || key.hasPrefix("header:")
            else {
                continue
            }
            if measuredLengths[key] != length {
                measuredLengths[key] = length
                hasNewMeasurements = true
            }
        }
        if hasNewMeasurements {
            let length = axis == .horizontal ? state.viewportSize.width : state.viewportSize.height
            let total = totalContentLength(viewportLength: length)
            let contentSize =
                axis == .horizontal
                ? MeasuredSize(width: total, height: state.contentSize.height)
                : MeasuredSize(width: state.contentSize.width, height: total)
            if contentSize != state.contentSize {
                updateViewport(viewportSize: state.viewportSize, contentSize: contentSize)
            }
        }
    }

    /// Cumulative flow length (section headers, when `sectionHeader` is set, plus items) up to
    /// but not including item index `index`, and the leading flow offset of each section's header
    /// encountered along the way — one walk instead of two, since both figures come from the same
    /// per-item accounting and `pinsSectionHeaders` needs the per-section offsets on every scroll.
    /// `measuredLengths` is the single source for both header and item extents (headers are keyed
    /// `"header:<sectionIndex>"`, matching their materialization key) — there is no second
    /// measurement source. O(n) in `itemIDs.count`; acceptable at today's scale, flagged as a
    /// scaling concern for very large sectioned lists (see card 08's measurement pass).
    /// Ownership: the returned dictionary is caller-owned. Isolation: MainActor. Errors: an out-of-range `index` clamps to the item count. Cancellation: not applicable.
    private func flowMetrics(uptoItemIndex index: Int) -> (
        length: Double, sectionStarts: [Int: Double]
    ) {
        let end = min(max(0, index), itemIDs.count)
        var sectionStarts: [Int: Double] = [:]
        guard end > 0 else { return (0, sectionStarts) }
        let gap = max(0, style.gap)
        var cursor = 0.0
        var lastSection: Int?
        for i in 0..<end {
            let id = itemIDs[i]
            guard let record = itemsByKey[String(reflecting: id)] else { continue }
            if sectionHeader != nil, record.sectionIndex != lastSection {
                sectionStarts[record.sectionIndex] = cursor
                let headerKey = "header:\(record.sectionIndex)"
                cursor += (measuredLengths[headerKey] ?? estimatedItemLength) + gap
                lastSection = record.sectionIndex
            }
            let isLastOverall = i == itemIDs.count - 1
            cursor +=
                (measuredLengths[String(reflecting: id)] ?? estimatedItemLength)
                + (isLastOverall ? 0 : gap)
        }
        return (cursor, sectionStarts)
    }

    private func totalContentLength(viewportLength: Double) -> Double {
        max(viewportLength, flowMetrics(uptoItemIndex: itemIDs.count).length)
    }

    private func contentOffset(before index: Int) -> Double {
        flowMetrics(uptoItemIndex: index).length
    }

    /// Leading flow offset of every section's header, keyed by section index, across the whole
    /// item list — not just the rendered window, since pinning needs to know which section the
    /// current scroll position falls into even when that section's own header has scrolled far
    /// out of the rendered range.
    private func sectionStartOffsets() -> [Int: Double] {
        flowMetrics(uptoItemIndex: itemIDs.count).sectionStarts
    }

    /// A scroll-axis item keeps its measured extent even when the materialized window is larger
    /// than the viewport. Shrinking belongs to ordinary flex containers, not virtualization.
    private func prepareVirtualizedCell(_ node: Node) -> Node {
        guard node.style.flexShrink != 0 else { return node }
        var draft = LayoutStyle.Draft(node.style)
        draft.flexShrink = 0
        node.style = LayoutStyle.bake(draft)
        return node
    }

    open override func moveBy(x: Double, y: Double) -> ScrollState {
        let result = super.moveBy(x: x, y: y)
        updateRenderedWindow()
        return result
    }
}

/// Vertical virtualized list.
/// Ownership: inherited VirtualizedView ownership. Isolation: MainActor. Errors: inherited policies. Cancellation: inherited cancellation and disposal.
@MainActor
public final class ListView<Item: Sendable, ItemID: Hashable & Sendable>: VirtualizedView<
    Item, ItemID
>
{
    /// Creates a vertical list.
    /// Ownership: closures are retained by the list. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        itemID: @escaping @MainActor (Item) -> ItemID,
        cell: @escaping @MainActor (Item, ItemContext<ItemID>) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        super.init(
            axis: .vertical, itemID: itemID, cell: cell, style: style, environment: environment)
    }
}

/// Two-dimensional virtualized grid policy.
/// Ownership: the grid owns its inherited item and layout state. Isolation: MainActor. Errors: invalid layout values are normalized by the adapter. Cancellation: inherited disposal cancels work.
@MainActor
public final class GridView<Item: Sendable, ItemID: Hashable & Sendable>: VirtualizedView<
    Item, ItemID
>
{
    public var layout: GridLayout

    /// Computes the deterministic column count for an available width.
    /// Ownership: the scalar is returned by value. Isolation: MainActor. Errors: invalid width yields one column. Cancellation: not applicable.
    public func columnCount(availableWidth: Double) -> Int {
        let width = max(0, availableWidth.isFinite ? availableWidth : 0)
        switch layout {
        case let .fixed(columns, _), let .masonry(columns, _):
            return max(1, columns)
        case let .adaptive(minimum, spacing):
            return max(1, Int((width + max(0, spacing)) / max(1, minimum + max(0, spacing))))
        case let .custom(columns):
            return max(1, columns.count)
        }
    }

    /// Creates a grid with a layout policy.
    /// Ownership: the grid retains closures and copies layout. Isolation: MainActor. Errors: invalid columns are tolerated. Cancellation: no work starts.
    public init(
        layout: GridLayout = .adaptive(minItemWidth: 120, spacing: 8),
        itemID: @escaping @MainActor (Item) -> ItemID,
        cell: @escaping @MainActor (Item, ItemContext<ItemID>) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.layout = layout
        super.init(axis: .both, itemID: itemID, cell: cell, style: style, environment: environment)
    }
}

/// Fully customizable collection façade sharing virtualization and stable identity.
/// Ownership: inherited VirtualizedView ownership. Isolation: MainActor. Errors: layout policy belongs to the concrete collection. Cancellation: inherited disposal cancels work.
@MainActor
public final class CollectionView<Item: Sendable, ItemID: Hashable & Sendable>: VirtualizedView<
    Item, ItemID
>
{
    /// Creates a collection view with a caller-selected axis.
    /// Ownership: closures are retained by the view. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public override init(
        axis: ScrollAxis = .vertical,
        itemID: @escaping @MainActor (Item) -> ItemID,
        cell: @escaping @MainActor (Item, ItemContext<ItemID>) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        super.init(axis: axis, itemID: itemID, cell: cell, style: style, environment: environment)
    }
}

/// A cell that hosts a nested collection with a fixed extent along the host axis.
///
/// This is the hosting contract a collection needs to be valid as a cell of another collection:
/// - the nested collection declares a **fixed** extent along the outer (host) axis, so the host's
///   own virtualization — which reads this cell's `calculatedFrame` into `measuredLengths`
///   (`VirtualizedView.didApplyLayoutResult`) — sees a stable input every pass instead of a value
///   that depends on the nested collection's own, possibly still-growing, content;
/// - the nested collection fills this cell along its own scroll axis and remains free to scroll
///   and virtualize independently there;
/// - `prepareForReuse()` clears nested items and resets the nested scroll offset to the origin,
///   so a pooled cell never shows a previous row's content or scroll position;
/// - `dispose()` (inherited from `Node`, reaching `content` as a child) disposes the nested
///   collection, which itself now finishes its own pipes and drains its own reuse pool
///   (`VirtualizedView.dispose()`).
///
/// Nesting is supported one level deep: `content` hosting a further `CollectionCell` of its own
/// is unsupported and untested. This type does not retain the outer collection that materializes
/// it — the outer's `cell` factory closure owns the only reference in that direction, so no
/// retain cycle is introduced by using this type as intended.
/// Ownership: the cell owns `content` as its sole child. Isolation: MainActor. Errors: a non-finite or negative `extent` normalizes to zero. Cancellation: disposal cancels the nested collection's work.
@MainActor
public final class CollectionCell<Item: Sendable, ItemID: Hashable & Sendable>: Node, ReusableNode {
    public let content: VirtualizedView<Item, ItemID>
    private let hostAxis: ScrollAxis

    /// Creates a hosting cell with a nested collection sized to fill it.
    /// Ownership: the cell takes ownership of `content` as a child node. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        content: VirtualizedView<Item, ItemID>,
        hostAxis: ScrollAxis,
        extent: Double,
        environment: EnvironmentScope? = nil
    ) {
        self.content = content
        self.hostAxis = hostAxis
        let normalizedExtent = max(0, extent.isFinite ? extent : 0)
        var draft = LayoutStyle.Draft(LayoutStyle())
        switch hostAxis {
        case .horizontal:
            draft.width = .points(normalizedExtent)
            draft.height = .fraction(1)
        case .vertical, .both:
            draft.height = .points(normalizedExtent)
            draft.width = .fraction(1)
        }
        draft.flexShrink = 0
        super.init(style: LayoutStyle.bake(draft), environment: environment)
        var contentDraft = LayoutStyle.Draft(content.style)
        contentDraft.width = .fraction(1)
        contentDraft.height = .fraction(1)
        contentDraft.flexShrink = 0
        content.style = LayoutStyle.bake(contentDraft)
        addSubnode(content)
    }

    /// Resets the boundary a pooled cell must cross before reuse: nested items are cleared and
    /// the nested scroll offset returns to the origin. Called by the reuse pool via
    /// `CellReusePool.recycle` before this cell is dequeued for a different row.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func prepareForReuse() {
        content.updateItems([])
        _ = content.scroll(.to(LayoutPoint(x: 0, y: 0)))
        content.deselectAll()
    }
}
