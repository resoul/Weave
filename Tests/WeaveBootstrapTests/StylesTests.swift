import Testing
@testable import Weave

@MainActor
struct StylesTests {
    @Test
    func modifierOrderIsDeterministicAndLastWriteWins() {
        let set = ModifierSet()
            .appending(ModifierRecord(family: .visual, key: "opacity", value: .number(0.5)))
            .appending(ModifierRecord(family: .visual, key: "opacity", value: .number(1)))
        let result = set.resolved()
        #expect(result.records.count == 1)
        #expect(result.diagnostics == ["visual:opacity"])
        #expect(result.records.first?.value == .number(1))
    }

    @Test
    func styleScopesMergeChildValuesWithoutMutatingParent() {
        enum AccentKey: StyleKey {
            static let defaultValue = "default"
        }
        var parent = StyleValues()
        parent[AccentKey.self] = "parent"
        var child = StyleValues()
        child[AccentKey.self] = "child"
        let merged = parent.merging(child)
        #expect(parent[AccentKey.self] == "parent")
        #expect(merged[AccentKey.self] == "child")
    }

    @Test
    func buttonStyleConfigurationDoesNotChangeButtonSemantics() {
        let button = ButtonNode(title: "Continue", role: .primary)
        let before = button.accessibility
        let body = DefaultButtonStyle().makeBody(configuration: button.buttonConfiguration)
        #expect(!body.flattenedDescriptors.isEmpty)
        #expect(button.accessibility.role == before.role)
        #expect(button.accessibility.actions == before.actions)
    }
}
