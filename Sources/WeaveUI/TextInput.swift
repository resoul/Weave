import Foundation

/// UTF-16 independent selection range represented as character offsets.
/// Ownership: immutable value. Isolation: none. Errors: invalid ranges are clamped by the node. Cancellation: not applicable.
public struct TextRange: Sendable, Hashable {
    public let location: Int
    public let length: Int

    /// Creates a non-negative range. Ownership: value is copied. Isolation: none. Errors: negative values clamp to zero. Cancellation: none.
    public init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }

    public var end: Int { location + length }
}

/// Immutable editing state shared by Core and a native text bridge.
/// Ownership: state is copied between actors. Isolation: none. Errors: none. Cancellation: not applicable.
public struct TextEditingState: Sendable, Hashable {
    public let text: String
    public let selection: TextRange
    public let markedRange: TextRange?
    public let isEditing: Bool
    public let isSecure: Bool

    /// Creates text state. Ownership: strings and ranges are copied. Isolation: none. Errors: none. Cancellation: none.
    public init(
        text: String = "", selection: TextRange = TextRange(location: 0, length: 0),
        markedRange: TextRange? = nil, isEditing: Bool = false, isSecure: Bool = false
    ) {
        self.text = text
        self.selection = selection
        self.markedRange = markedRange
        self.isEditing = isEditing
        self.isSecure = isSecure
    }
}

/// Typed input action emitted by native adapters or tests.
/// Ownership: immutable action snapshot. Isolation: none. Errors: invalid ranges are normalized by the node. Cancellation: submit/focus actions are cancellable by lifecycle.
public enum TextEditingAction: Sendable, Hashable {
    case replace(range: TextRange, text: String)
    case setSelection(TextRange)
    case setMarkedRange(TextRange?)
    case beginEditing
    case endEditing
    case submit
    case deleteBackward
}

/// Typed text output emitted after one committed edit or submit.
/// Ownership: immutable output snapshot. Isolation: none. Errors: none. Cancellation: stream subscription cancellation.
public enum TextEditingOutput: Sendable, Hashable {
    case changed(TextEditingState)
    case submitted(TextEditingState)
}

/// Platform-neutral bridge contract for UIKit/AppKit text controls.
/// Ownership: bridge borrows node state and emits typed actions. Isolation: MainActor. Errors: unsupported operations are ignored. Cancellation: detach stops delivery.
@MainActor
public protocol TextInputBridge: AnyObject {
    func apply(_ state: TextEditingState)
    func send(_ action: TextEditingAction)
}

/// MainActor text editing node that owns value, selection and IME composition state.
/// Ownership: node owns state and bounded output pipes. Isolation: MainActor. Errors: invalid ranges are clamped. Cancellation: disposal stops edits and stream delivery.
@MainActor
open class EditableTextNode: Node {
    public private(set) var editingState: TextEditingState
    public let actions = ActionPipe<TextEditingAction>(capacity: 64)
    public let outputs = ActionPipe<TextEditingOutput>(capacity: 64)
    public private(set) var editRevision: UInt64 = 0

    /// Creates an editable node without allocating native controls. Ownership: node owns initial state. Isolation: MainActor. Errors: selection is normalized on first action. Cancellation: no work starts.
    public init(text: String = "", isSecure: Bool = false) {
        editingState = TextEditingState(text: text, isSecure: isSecure)
        super.init()
        accessibility = AccessibilityProperties(
            isElement: true, role: .text, state: AccessibilityState(value: text))
    }

    public override var focusable: FocusableSpec? { FocusableSpec() }

    /// Applies one typed editing action exactly once. Ownership: action is copied. Isolation: MainActor. Errors: malformed ranges are clamped. Cancellation: disposed nodes drop actions.
    @discardableResult
    public func apply(_ action: TextEditingAction) -> Bool {
        guard lifecycleState != .disposed else { return false }
        let changed: Bool
        switch action {
        case let .replace(range, text): changed = replace(range: range, with: text)
        case let .setSelection(range): changed = update(selection: range)
        case let .setMarkedRange(range): changed = update(markedRange: range)
        case .beginEditing: changed = update(isEditing: true)
        case .endEditing: changed = update(isEditing: false)
        case .deleteBackward: changed = deleteBackward()
        case .submit:
            _ = outputs.send(.submitted(editingState))
            return true
        }
        if changed { publishChange() }
        return changed
    }

    /// Applies external state while preserving active IME composition by default. Ownership: state values are copied. Isolation: MainActor. Errors: composing state rejects conflicting external updates. Cancellation: disposed nodes reject updates.
    @discardableResult
    public func setExternalText(_ text: String, preserveComposition: Bool = true) -> Bool {
        guard lifecycleState != .disposed else { return false }
        if preserveComposition, editingState.markedRange != nil { return false }
        guard text != editingState.text else { return false }
        let position = min(editingState.selection.location, text.count)
        editingState = TextEditingState(
            text: text, selection: TextRange(location: position, length: 0),
            isEditing: editingState.isEditing, isSecure: editingState.isSecure)
        publishChange()
        return true
    }

    /// Ends composition and optionally commits its replacement. Ownership: action is copied. Isolation: MainActor. Errors: range is clamped. Cancellation: disposed nodes ignore it.
    @discardableResult
    public func commitComposition(text: String? = nil) -> Bool {
        guard lifecycleState != .disposed else { return false }
        let hadMarkedRange = editingState.markedRange != nil
        if let text, let marked = editingState.markedRange {
            _ = replace(range: marked, with: text)
        }
        guard hadMarkedRange else { return false }
        if editingState.markedRange == nil { publishChange(); return true }
        editingState = TextEditingState(
            text: editingState.text, selection: editingState.selection,
            isEditing: editingState.isEditing, isSecure: editingState.isSecure)
        publishChange()
        return true
    }

    open override func dispose() {
        actions.finish(); outputs.finish(); super.dispose()
    }

    private func update(selection: TextRange) -> Bool {
        let normalized = normalize(selection)
        guard normalized != editingState.selection else { return false }
        editingState = TextEditingState(
            text: editingState.text, selection: normalized, markedRange: editingState.markedRange,
            isEditing: editingState.isEditing, isSecure: editingState.isSecure)
        return true
    }

    private func update(markedRange: TextRange?) -> Bool {
        guard markedRange != editingState.markedRange else { return false }
        editingState = TextEditingState(
            text: editingState.text, selection: editingState.selection,
            markedRange: markedRange.map(normalize), isEditing: editingState.isEditing,
            isSecure: editingState.isSecure)
        return true
    }

    private func update(isEditing: Bool) -> Bool {
        guard isEditing != editingState.isEditing else { return false }
        editingState = TextEditingState(
            text: editingState.text, selection: editingState.selection,
            markedRange: editingState.markedRange, isEditing: isEditing,
            isSecure: editingState.isSecure)
        return true
    }

    private func replace(range: TextRange, with replacement: String) -> Bool {
        let normalized = normalize(range)
        var characters = Array(editingState.text)
        characters.replaceSubrange(normalized.location..<normalized.end, with: replacement)
        let selection = TextRange(location: normalized.location + replacement.count, length: 0)
        editingState = TextEditingState(
            text: String(characters), selection: selection, markedRange: nil,
            isEditing: editingState.isEditing, isSecure: editingState.isSecure)
        return true
    }

    private func deleteBackward() -> Bool {
        let selection = editingState.selection
        if selection.length > 0 { return replace(range: selection, with: "") }
        guard selection.location > 0 else { return false }
        return replace(range: TextRange(location: selection.location - 1, length: 1), with: "")
    }

    private func normalize(_ range: TextRange) -> TextRange {
        let location = min(range.location, editingState.text.count)
        let length = min(range.length, editingState.text.count - location)
        return TextRange(location: location, length: length)
    }

    private func publishChange() {
        editRevision &+= 1
        accessibility = AccessibilityProperties(
            isElement: true, value: editingState.isSecure ? nil : editingState.text, role: .text,
            state: AccessibilityState(value: editingState.isSecure ? nil : editingState.text))
        _ = outputs.send(.changed(editingState))
    }
}

/// Text field specialization with placeholder and secure-entry policy.
/// Ownership: field owns its placeholder and editing node state. Isolation: MainActor. Errors: none. Cancellation: inherited node disposal cancels editing.
@MainActor
public final class TextFieldNode: EditableTextNode {
    public let placeholder: String?

    /// Creates a single-line text field contract. Ownership: field owns placeholder and state. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(text: String = "", placeholder: String? = nil, isSecure: Bool = false) {
        self.placeholder = placeholder
        super.init(text: text, isSecure: isSecure)
    }
}

/// Multiline editable text contract. Newline insertion is owned by the native editor;
/// submit is not synthesized for Return. Ownership: node owns state. Isolation: MainActor.
/// Errors: invalid ranges are clamped. Cancellation: inherited disposal stops editing.
@MainActor
public final class TextEditorNode: EditableTextNode {
    public let placeholder: String?

    /// Creates a multiline editor without allocating a native control.
    /// Ownership: node owns placeholder and state. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(text: String = "", placeholder: String? = nil) {
        self.placeholder = placeholder
        super.init(text: text)
    }
}
