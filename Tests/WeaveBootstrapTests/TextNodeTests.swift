import Testing
import Weave

@MainActor
private final class FakeTextBackend: TextLayoutBackend {
    private(set) var inputs: [TextLayoutInput] = []

    func display(_ input: TextLayoutInput, generation: UInt64) async throws -> TextDisplayResult {
        inputs.append(input)
        let lines = max(
            1, input.text.split(separator: "\n", omittingEmptySubsequences: false).count)
        return TextDisplayResult(
            renderedText: input.text,
            metrics: TextMetrics(
                size: MeasuredSize(width: Double(input.text.count), height: Double(lines * 20)),
                firstBaseline: 16,
                lineCount: lines),
            generation: generation)
    }
}

@MainActor
private func settleTextTasks() async {
    for _ in 0..<4 { await Task.yield() }
}

@Test
@MainActor
func textNodePublishesLatestImmutableDisplayAndAccessibilityDefaults() async {
    let backend = FakeTextBackend()
    let node = TextNode(text: "שלום 👋", style: TextStyle(pointSize: 20), backend: backend)
    node.maxLines = 2
    node.setLayoutInputs(
        constraint: SizeConstraint(width: .atMost(120), height: .unspecified),
        direction: .rightToLeft,
        localeIdentifier: "he_IL",
        scale: 2)
    node.scheduleDisplay()
    await settleTextTasks()
    #expect(backend.inputs.last?.direction == .rightToLeft)
    #expect(backend.inputs.last?.localeIdentifier == "he_IL")
    #expect(node.displayResult?.renderedText == "שלום 👋")
    #expect(node.accessibility.role == .text)
    #expect(node.accessibility.value == "שלום 👋")
}

@Test
@MainActor
func textNodeCancelsStaleGenerationBeforeApplyingReplacement() async {
    let backend = FakeTextBackend()
    let node = TextNode(text: "old", backend: backend)
    node.scheduleDisplay()
    node.setText("new")
    await settleTextTasks()
    #expect(node.displayResult?.renderedText == "new")
    #expect(node.textRevision == 1)
}

@Test
@MainActor
func defaultTextBackendAndLayoutSnapshotProvideIntrinsicMetrics() async throws {
    let backend = DefaultTextLayoutBackend()
    let input = TextLayoutInput(text: "Weave", style: TextStyle(pointSize: 20))
    let display = try await backend.display(input, generation: 7)
    let node = TextNode(
        text: "Weave",
        style: TextStyle(pointSize: 20),
        backend: DefaultTextLayoutBackend()
    )

    #expect(abs(display.metrics.size.width - 55) < 0.000_001)
    #expect(display.metrics.size.height == 24)
    #expect(node.makeLayoutInputSnapshot().content.intrinsic == display.metrics.size)
}
