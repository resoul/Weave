import Testing
@testable import Weave

@MainActor
@Test
func tableResolvesWidthsAndPreservesStableRows() {
    let table = TableView<Int, Int, String>(
        columns: [
            TableColumn(id: "name", title: "Name", width: .fixed(100)),
            TableColumn(id: "value", title: "Value", width: .flexible(minimum: 80)),
        ], itemID: { $0 }, cell: { _, _ in Node() })
    table.selectionMode = .single
    table.updateItems([1, 2, 3])
    table.select(2)
    table.updateItems([3, 2, 1])
    #expect(table.selectedItems == [2])
    #expect(table.resolveColumnLayout(availableWidth: 300).map(\.width) == [100, 200])
    #expect(table.moveRowFocus(by: 1))
    #expect(table.focusedItemID == 2)
}

@MainActor
@Test
func tableEmitsSortIntentWithoutSortingItems() {
    let table = TableView<Int, Int, String>(
        columns: [TableColumn(id: "name", title: "Name")], itemID: { $0 }, cell: { _, _ in Node() })
    table.updateItems([3, 1, 2])
    _ = table.requestSort(columnID: "name", ascending: false)
    #expect(table.itemIDs == [3, 1, 2])
}
