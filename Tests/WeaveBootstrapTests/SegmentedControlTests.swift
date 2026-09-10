import Testing
@testable import Weave

@MainActor
struct SegmentedControlTests {
    private func makeControl(selected: String? = "chats") -> SegmentedControl<String> {
        SegmentedControl<String>(
            segments: [
                Segment(id: "chats", title: "Chats"),
                Segment(id: "media", title: "Media"),
                Segment(id: "files", title: "Files"),
            ],
            selectedID: selected
        )
    }

    private func target(_ control: SegmentedControl<String>, _ index: Int) -> any ControlInputTarget
    {
        guard let target = control.subnodes[index] as? any ControlInputTarget else {
            fatalError("segment \(index) is not a ControlInputTarget")
        }
        return target
    }

    @Test
    func segmentTapEmitsSelectionIntentWithoutSelfSelecting() async {
        let control = makeControl(selected: "chats")
        var received: [SegmentSelection<String>] = []
        let subscription = control.selectionIntents.flux.sinkOnMain { received.append($0) }

        _ = target(control, 1).handle(.pointerDown)
        _ = target(control, 1).handle(.pointerUp(inside: true))
        for _ in 0..<10 { await Task.yield() }

        #expect(received == [SegmentSelection(id: "media", index: 1)])
        #expect(control.selectedID == "chats", "control must not self-select on tap")
        subscription.cancel()
    }

    @Test
    func disabledSegmentedControlEmitsNothing() async {
        let control = makeControl()
        control.isEnabled = false
        var received: [SegmentSelection<String>] = []
        let subscription = control.selectionIntents.flux.sinkOnMain { received.append($0) }

        #expect(!target(control, 0).handle(.pressSelect))
        for _ in 0..<10 { await Task.yield() }
        #expect(received.isEmpty)
        subscription.cancel()
    }

    @Test
    func loadingSegmentedControlEmitsNothing() async {
        let control = makeControl()
        control.isLoading = true
        var received: [SegmentSelection<String>] = []
        let subscription = control.selectionIntents.flux.sinkOnMain { received.append($0) }

        #expect(!target(control, 2).handle(.accessibilityActivate))
        for _ in 0..<10 { await Task.yield() }
        #expect(received.isEmpty)
        subscription.cancel()
    }

    @Test
    func updateSegmentsDroppingSelectedIDClearsSelection() {
        let control = makeControl(selected: "chats")
        control.updateSegments(
            [Segment(id: "media", title: "Media"), Segment(id: "files", title: "Files")],
            selectedID: "chats"
        )
        #expect(control.selectedID == nil)
        #expect(control.segments.map(\.id) == ["media", "files"])
    }

    @Test
    func setSelectedIgnoresUnknownID() {
        let control = makeControl(selected: "chats")
        control.setSelected("unknown")
        #expect(control.selectedID == "chats")
        control.setSelected("media")
        #expect(control.selectedID == "media")
        control.setSelected(nil)
        #expect(control.selectedID == nil)
    }

    @Test
    func segmentFocusMovementIsClampedAndEmitsNothing() async {
        let control = makeControl()
        var received: [SegmentSelection<String>] = []
        let subscription = control.selectionIntents.flux.sinkOnMain { received.append($0) }

        #expect(control.moveFocus(by: -1))
        #expect(control.focusedIndex == 0)
        #expect(control.moveFocus(by: -1))
        #expect(control.focusedIndex == 0)
        #expect(control.moveFocus(by: 1))
        #expect(control.focusedIndex == 1)
        #expect(control.moveFocus(by: 10))
        #expect(control.focusedIndex == 2)
        #expect(control.moveFocus(by: 1))
        #expect(control.focusedIndex == 2)

        for _ in 0..<10 { await Task.yield() }
        #expect(received.isEmpty)
        subscription.cancel()
    }

    @Test
    func segmentedControlExposesAccessibilitySelectionPerSegment() {
        let control = makeControl(selected: "media")
        #expect(control.subnodes.count == 3)
        #expect(control.subnodes[0].accessibility.label == "Chats")
        #expect(control.subnodes[1].accessibility.state.isSelected)
        #expect(!control.subnodes[0].accessibility.state.isSelected)

        control.setSelected("files")
        #expect(control.subnodes[2].accessibility.state.isSelected)
        #expect(!control.subnodes[1].accessibility.state.isSelected)
    }

    @Test
    func disposeDisposesEverySegmentButton() {
        let control = makeControl()
        let firstButton = control.subnodes[0]
        control.dispose()
        #expect(firstButton.lifecycleState == .disposed)
        #expect(control.subnodes.isEmpty)
    }
}
