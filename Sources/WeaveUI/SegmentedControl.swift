import Foundation

/// One selectable option within a `SegmentedControl`.
/// Ownership: an immutable value copied into the control's segment list. Isolation: none. Errors: none. Cancellation: not applicable.
public struct Segment<ID: Hashable & Sendable>: Sendable, Hashable {
    public let id: ID
    public let title: String

    /// Creates a segment description.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: ID, title: String) {
        self.id = id
        self.title = title
    }
}

/// Selection intent emitted when a segment is activated by touch, remote, or accessibility
/// activation. The control does not apply this to its own `selectedID`; the owner does, by
/// calling `setSelected(_:)` after reducing this intent through its own state.
/// Ownership: an immutable value copied into the bounded action pipe. Isolation: none. Errors: none. Cancellation: not applicable.
public struct SegmentSelection<ID: Hashable & Sendable>: Sendable, Hashable {
    public let id: ID
    public let index: Int

    /// Creates a selection intent.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(id: ID, index: Int) {
        self.id = id
        self.index = index
    }
}

/// One hit-testable segment inside a `SegmentedControl`. Each segment is its own `ControlNode`
/// so the platform-neutral `HitTester` (walking up from the exact touch point to the nearest
/// `ControlInputTarget` ancestor) resolves taps to the correct segment without the parent doing
/// its own position math. Never constructed outside `SegmentedControl`.
/// Ownership: owned by the parent `SegmentedControl` as a child node. Isolation: MainActor. Errors: none. Cancellation: disposal follows parent teardown.
@MainActor
private final class SegmentButton<ID: Hashable & Sendable>: ControlNode<Int> {
    let segmentIndex: Int
    let segmentID: ID
    var title: String {
        didSet { updateAccessibility() }
    }
    var isSegmentSelected: Bool = false {
        didSet { updateAccessibility() }
    }

    init(index: Int, segment: Segment<ID>) {
        segmentIndex = index
        segmentID = segment.id
        title = segment.title
        super.init(activation: { index })
        updateAccessibility()
    }

    override func updateSemantics() { updateAccessibility() }

    private func updateAccessibility() {
        var traits: AccessibilityTrait = [.button]
        if isSegmentSelected { traits.insert(.selected) }
        accessibility = AccessibilityProperties(
            isElement: true,
            label: title,
            traits: traits,
            role: .button,
            actions: [.activate],
            state: AccessibilityState(
                isEnabled: isEnabled && !isLoading,
                isSelected: isSegmentSelected
            )
        )
    }
}

/// Platform-neutral segmented control: N titled segments, one caller-selected, emitting a typed
/// selection intent per tap. Selection is owner-driven, matching `TableView.requestSort` — the
/// control emits intent and renders whatever selection it is given; it never self-selects.
///
/// Composition, not a single hit target: each segment is a child `ControlNode<Int>` laid out with
/// equal `flexGrow`, so real touch/pointer dispatch (which hit-tests to a point, then walks up to
/// the nearest `ControlInputTarget`) resolves to the tapped segment on its own — no adapter change
/// is required to route input correctly. Presentation (colors, selection indicator) is left to the
/// caller/theme layer, matching `ButtonNode`: this control supplies interaction and semantic state,
/// not paint.
/// Ownership: the control owns its segment buttons as children and its bounded selection pipe. Isolation: MainActor. Errors: an unknown `selectedID` is ignored (treated as no selection). Cancellation: disposal cancels every child button and pending activation.
@MainActor
public final class SegmentedControl<ID: Hashable & Sendable>: Node {
    public private(set) var segments: [Segment<ID>]
    public private(set) var selectedID: ID?
    public private(set) var focusedIndex: Int?
    public let selectionIntents: ActionPipe<SegmentSelection<ID>>

    public var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            for button in buttons { button.isEnabled = isEnabled }
        }
    }
    public var isLoading: Bool = false {
        didSet {
            guard isLoading != oldValue else { return }
            for button in buttons { button.isLoading = isLoading }
        }
    }

    private var buttons: [SegmentButton<ID>] = []

    /// Creates a segmented control with an initial segment list and selection.
    /// Ownership: segments are copied; the control retains its child buttons and bounded pipe. Isolation: MainActor. Errors: a `selectedID` absent from `segments` is dropped. Cancellation: no work starts.
    public init(
        segments: [Segment<ID>],
        selectedID: ID?,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.segments = segments
        self.selectedID = segments.contains { $0.id == selectedID } ? selectedID : nil
        selectionIntents = ActionPipe(capacity: 16)
        var draft = LayoutStyle.Draft(style)
        draft.flexDirection = .row
        super.init(style: LayoutStyle.bake(draft), environment: environment)
        accessibility = AccessibilityProperties(isElement: false, childrenPolicy: .contain)
        rebuildButtons()
    }

    /// Replaces the segment list and selection without changing enabled/loading state.
    /// A `selectedID` no longer present in `segments` clears selection rather than being retained
    /// against a segment that no longer exists.
    /// Ownership: segments are copied; old child buttons are disposed and replaced. Isolation: MainActor. Errors: none — an absent `selectedID` clears selection. Cancellation: focus is cleared.
    public func updateSegments(_ segments: [Segment<ID>], selectedID: ID?) {
        self.segments = segments
        self.selectedID = segments.contains { $0.id == selectedID } ? selectedID : nil
        focusedIndex = nil
        rebuildButtons()
    }

    /// Moves the applied selection without emitting a selection intent. This is the only way
    /// `selectedID` changes — the control never applies its own tap intents.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: an `id` absent from `segments` is ignored, leaving selection unchanged. Cancellation: not applicable.
    public func setSelected(_ id: ID?) {
        guard id == nil || segments.contains(where: { $0.id == id }) else { return }
        selectedID = id
        for (index, button) in buttons.enumerated() {
            button.isSegmentSelected = segments[index].id == id
        }
    }

    /// Moves directional/accessibility focus presentation by an offset, clamped to the segment
    /// range. Mirrors `TableView.moveRowFocus`'s contract. Does not change selection or emit
    /// anything.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: an empty control or zero offset returns false. Cancellation: not applicable.
    @discardableResult
    public func moveFocus(by offset: Int) -> Bool {
        guard !buttons.isEmpty, offset != 0 else { return false }
        let current = focusedIndex ?? 0
        let target = min(max(0, current + offset), buttons.count - 1)
        guard buttons.indices.contains(target) else { return false }
        for (index, button) in buttons.enumerated() {
            button.setFocused(index == target)
        }
        focusedIndex = target
        return true
    }

    public override func dispose() {
        buttons.removeAll()
        super.dispose()
    }

    private func rebuildButtons() {
        for button in buttons {
            button.removeFromSupernode()
            button.dispose()
        }
        buttons.removeAll()
        var built: [SegmentButton<ID>] = []
        for (index, segment) in segments.enumerated() {
            let button = SegmentButton<ID>(index: index, segment: segment)
            button.isSegmentSelected = segment.id == selectedID
            button.isEnabled = isEnabled
            button.isLoading = isLoading
            var buttonDraft = LayoutStyle.Draft(button.style)
            buttonDraft.flexGrow = 1
            buttonDraft.flexShrink = 1
            buttonDraft.flexBasis = .points(0)
            button.style = LayoutStyle.bake(buttonDraft)
            addSubnode(button)
            bind(id: "segment-\(index)", button.events.flux) { [weak self] tappedIndex in
                self?.handleSegmentActivated(index: tappedIndex)
            }
            built.append(button)
        }
        buttons = built
    }

    private func handleSegmentActivated(index: Int) {
        guard buttons.indices.contains(index) else { return }
        let button = buttons[index]
        _ = selectionIntents.send(SegmentSelection(id: button.segmentID, index: index))
    }
}
