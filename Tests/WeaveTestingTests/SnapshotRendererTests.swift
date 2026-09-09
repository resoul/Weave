import Foundation
import Testing
import Weave
import WeaveTesting

private final class NeverQuiescent: @unchecked Sendable {
    @MainActor func wait() async -> Bool { false }
}

@Test
@MainActor
func snapshotRendererLayoutIsDeterministicWithoutWindow() async throws {
    let root = Node(style: LayoutStyle(width: .points(120), height: .points(80)))
    let renderer = SnapshotRenderer()
    let request = RenderRequest(
        size: SizeConstraint(width: .exact(120), height: .exact(80)), mode: .layoutOnly)
    let first = try await renderer.render(root, request: request)
    let second = try await renderer.render(root, request: request)
    #expect(SnapshotComparator.compareLayout(first.layoutTree, second.layoutTree) == nil)
    #expect(first.image == nil)
    #expect(first.accessibilityTree == nil)
}

@Test
@MainActor
func snapshotRendererSemanticModePublishesAccessibilityArtifact() async throws {
    let root = Node(style: LayoutStyle(width: .points(20), height: .points(20)))
    root.accessibility = AccessibilityProperties(isElement: true, label: "Root")
    let artifact = try await SnapshotRenderer().render(
        root,
        request: RenderRequest(
            size: SizeConstraint(width: .exact(20), height: .exact(20)), mode: .semantic))
    #expect(artifact.accessibilityTree?.readingOrder == [root.id])
}

@Test
@MainActor
func snapshotRendererReportsQuiescenceTimeout() async {
    let never = NeverQuiescent()
    let renderer = SnapshotRenderer(quiescence: { @MainActor in await never.wait() })
    let root = Node()
    do {
        _ = try await renderer.render(
            root, request: RenderRequest(size: SizeConstraint(), timeout: .zero))
        Issue.record("expected quiescence timeout")
    } catch let error as SnapshotRenderError {
        #expect(error == .quiescenceTimeout(generation: 1, mode: .layoutOnly))
    } catch {
        Issue.record("unexpected error: \(error)")
    }
}
