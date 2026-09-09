import Testing
import Weave

@Test
func test_nodeBuilder_supportsOptionalEitherArrayAndGroup_withoutRuntimeNodes() {
    let include = true
    let content: NodeContent = {
        Group.content {
            NodeDescriptor(typeName: "Header", key: "header")
            if include {
                NodeDescriptor(typeName: "Body", key: "body")
            } else {
                Empty.content
            }
            for index in 0..<2 {
                NodeDescriptor(typeName: "Row", key: "row-\(index)")
            }
        }
    }()
    #expect(content.flattenedDescriptors.map(\.key) == ["header", "body", "row-0", "row-1"])
}

@Test
func test_forEach_preservesStableKeys_andDropsDuplicateIDs() {
    let values = ["a", "b", "a"]
    let result = ForEach.result(values, id: \.self) { value in
        NodeDescriptor(typeName: "Item", key: value)
    }
    #expect(result.content.flattenedDescriptors.map(\.key) == ["a", "b"])
    #expect(result.diagnostics.duplicateKeys == ["a"])
}

@Test
func test_nodeBuilder_isValueOnly_andDiagnosticsAreDeterministic() {
    let content = NodeContent.children([NodeDescriptor(typeName: "Leaf", key: "x")])
    #expect(content.diagnostics.isClean)
    #expect(content.flattenedDescriptors.count == 1)
}
