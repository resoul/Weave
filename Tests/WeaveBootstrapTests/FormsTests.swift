import Testing
import Weave

private let requiredIssue = ValidationIssue(
    code: "required",
    message: LocalizedText(key: "form.required", fallback: "Required"))

@MainActor
private final class FocusFlag {
    var value = false
}

@Test
@MainActor
func formDoesNotAnnouncePristineErrorsButSubmitFocusesFirstInvalid() async {
    let form = FormController<String>()
    let focused = FocusFlag()
    let field = FieldController<String>(
        value: "",
        syncRules: [
            { value in
                value.isEmpty ? [requiredIssue] : []
            }
        ])
    form.register("name", field: field) { focused.value = true }
    #expect(field.state.interaction == .pristine)
    #expect(field.state.validation == .idle)

    let result = await form.submit()
    #expect(result == .blocked(firstInvalid: "name"))
    #expect(focused.value)
    #expect(field.state.validation == .invalid([requiredIssue]))
    form.dispose()
}

@Test
@MainActor
func asyncValidationUsesLatestValueAndDisposeCancelsOwnerWork() async {
    let field = FieldController<String>(
        value: "",
        asyncValidator: { value in
            await Task.yield()
            return value == "old" ? [requiredIssue] : []
        })
    field.setValue("old")
    field.setValue("new")
    await field.validate()
    #expect(field.state.value == "new")
    #expect(field.state.validation == .valid)
    field.dispose()
    field.setValue("old")
    #expect(field.state.value == "new")
}

@Test
@MainActor
func syncValidationPublishesValidFormStateAndSubmitCanSucceed() async {
    let form = FormController<String>()
    let field = FieldController<String>(
        value: "ok",
        syncRules: [
            { value in
                value == "ok" ? [] : [requiredIssue]
            }
        ])
    form.register("name", field: field)
    field.markTouched()
    let result = await form.submit()
    #expect(result == .submitted)
    #expect(field.state.validation == .valid)
    form.dispose()
}
