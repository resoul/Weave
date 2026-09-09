import Testing
import Weave

@Test
@MainActor
func editableTextAppliesOneEditSelectionAndSubmit() {
    let node = EditableTextNode(text: "hello")
    #expect(node.apply(.setSelection(TextRange(location: 5, length: 0))))
    #expect(node.apply(.replace(range: TextRange(location: 5, length: 0), text: "!")))
    #expect(node.editingState.text == "hello!")
    #expect(node.apply(.deleteBackward))
    #expect(node.editingState.text == "hello")
    #expect(node.apply(.submit))
}

@Test
@MainActor
func editableTextPreservesMarkedCompositionAndSecureAccessibility() {
    let node = TextFieldNode(text: "secret", placeholder: "Password", isSecure: true)
    #expect(node.apply(.setMarkedRange(TextRange(location: 0, length: 2))))
    #expect(!node.setExternalText("changed"))
    #expect(node.commitComposition(text: "新"))
    #expect(node.editingState.text == "新cret")
    #expect(node.accessibility.value == nil)
    #expect(node.placeholder == "Password")
}
