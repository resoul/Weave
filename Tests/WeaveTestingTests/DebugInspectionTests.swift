import Testing
import Weave
@testable import WeaveTesting

@MainActor
@Test
func debugInspectorReportsCommittedTreeWithoutMutation() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    let revision = root.layoutRevision
    let inspector = DebugInspector()
    let snapshot = inspector.inspect(root: root)
    #expect(snapshot.map(\.identity) == [root.id, child.id])
    #expect(root.layoutRevision == revision)
}
