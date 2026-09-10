import Foundation
import Flux

/// Width policy for a table column.
/// Ownership: immutable value copied by the table. Isolation: none. Errors: invalid values normalize. Cancellation: not applicable.
public enum TableColumnWidth: Sendable, Hashable {
    case fixed(Double)
    case flexible(minimum: Double = 0, maximum: Double? = nil)

    fileprivate func resolve(available: Double, flexibleCount: Int) -> Double {
        switch self {
        case let .fixed(value): return max(0, value.isFinite ? value : 0)
        case let .flexible(minimum, maximum):
            let minValue = max(0, minimum.isFinite ? minimum : 0)
            let share = max(minValue, available / Double(max(1, flexibleCount)))
            return maximum.map { min(share, max(minValue, $0.isFinite ? $0 : minValue)) } ?? share
        }
    }
}

/// Immutable typed table column description.
/// Ownership: the column owns copied metadata. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TableColumn<ColumnID: Hashable & Sendable>: Sendable, Hashable {
    public let id: ColumnID
    public let title: String
    public let width: TableColumnWidth
    public let header: NodeContent

    /// Creates a column description without allocating native objects.
    /// Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        id: ColumnID, title: String, width: TableColumnWidth = .flexible(),
        header: NodeContent = .empty
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.header = header
    }
}

/// User intent to sort a stable table column. The table emits this intent and never sorts domain items itself.
/// Ownership: the descriptor is copied into a bounded action pipe. Isolation: none. Errors: none. Cancellation: subscriber-owned.
public struct TableSortDescriptor<ColumnID: Hashable & Sendable>: Sendable, Hashable {
    public let columnID: ColumnID
    public let ascending: Bool

    /// Creates a sort intent.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(columnID: ColumnID, ascending: Bool = true) {
        self.columnID = columnID
        self.ascending = ascending
    }
}

/// A resolved width for one table column.
/// Ownership: immutable result owned by the caller. Isolation: none. Errors: invalid widths are normalized. Cancellation: not applicable.
public struct TableColumnLayout<ColumnID: Hashable & Sendable>: Sendable, Hashable {
    public let columnID: ColumnID
    public let title: String
    public let width: Double
    public let semanticLabel: String
}

/// Virtualized table façade with stable rows, typed columns, and explicit sort intents.
/// Ownership: the MainActor table owns columns, row identity and bounded pipes. Isolation: MainActor. Errors: malformed widths normalize. Cancellation: inherited disposal cancels work.
@MainActor
public final class TableView<
    Item: Sendable, ItemID: Hashable & Sendable, ColumnID: Hashable & Sendable
>: VirtualizedView<Item, ItemID> {
    public private(set) var columns: [TableColumn<ColumnID>]
    public let sortRequests: ActionPipe<TableSortDescriptor<ColumnID>>
    public var rowSemanticLabel: (@MainActor (Item, ItemContext<ItemID>) -> String?)?
    public private(set) var columnResizeEnabled = false

    /// Creates a virtualized table.
    /// Ownership: closures and columns are retained/copied. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        columns: [TableColumn<ColumnID>],
        itemID: @escaping @MainActor (Item) -> ItemID,
        cell: @escaping @MainActor (Item, ItemContext<ItemID>) -> Node,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.columns = columns
        sortRequests = ActionPipe(capacity: 16)
        super.init(
            axis: .vertical, itemID: itemID, cell: cell, style: style, environment: environment)
    }

    /// Replaces columns without changing row identity or selection.
    /// Ownership: columns are copied. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public func updateColumns(_ columns: [TableColumn<ColumnID>]) { self.columns = columns }

    /// Resolves fixed/flexible widths within the available table width.
    /// Ownership: returned layouts are caller-owned. Isolation: MainActor. Errors: non-finite width becomes zero. Cancellation: not applicable.
    public func resolveColumnLayout(availableWidth: Double) -> [TableColumnLayout<ColumnID>] {
        let width = max(0, availableWidth.isFinite ? availableWidth : 0)
        let fixed = columns.reduce(0) { partial, column in
            if case .fixed = column.width {
                return partial + column.width.resolve(available: 0, flexibleCount: 1)
            }
            return partial
        }
        let flexibleCount = columns.reduce(0) { $1.width.isFlexible ? $0 + 1 : $0 }
        let remaining = max(0, width - fixed)
        return columns.map {
            TableColumnLayout(
                columnID: $0.id, title: $0.title,
                width: $0.width.resolve(available: remaining, flexibleCount: flexibleCount),
                semanticLabel: $0.title)
        }
    }

    /// Emits an explicit sort intent; the caller applies it and supplies a new stable snapshot.
    /// Ownership: intent is copied into a bounded pipe. Isolation: MainActor. Errors: overflow is reported by the yield result. Cancellation: subscribers cancel independently.
    @discardableResult
    public func requestSort(columnID: ColumnID, ascending: Bool = true)
        -> AsyncStream<TableSortDescriptor<ColumnID>>.Continuation.YieldResult
    {
        sortRequests.send(TableSortDescriptor(columnID: columnID, ascending: ascending))
    }

    /// Moves focus through stable row IDs, suitable for keyboard or remote navigation.
    /// Ownership: IDs remain owned by the table. Isolation: MainActor. Errors: empty tables return false. Cancellation: not applicable.
    @discardableResult
    public func moveRowFocus(by offset: Int) -> Bool {
        guard !itemIDs.isEmpty, offset != 0 else { return false }
        let current = focusedItemID.flatMap { itemIDs.firstIndex(of: $0) } ?? 0
        let target = min(max(0, current + offset), itemIDs.count - 1)
        guard itemIDs.indices.contains(target) else { return false }
        setFocusedItem(itemIDs[target])
        return true
    }

    /// Returns semantic labels for visible rows and columns without allocating platform views.
    /// Ownership: returned string is caller-owned. Isolation: MainActor. Errors: absent provider returns nil. Cancellation: not applicable.
    public func semanticRowLabel(for item: Item, context: ItemContext<ItemID>) -> String? {
        rowSemanticLabel?(item, context)
    }

    /// Finishes `sortRequests` before the inherited `VirtualizedView`/`ScrollNode` teardown.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: idempotent.
    public override func dispose() {
        sortRequests.finish()
        super.dispose()
    }
}

private extension TableColumnWidth {
    var isFlexible: Bool {
        if case .flexible = self { return true }
        return false
    }
}
