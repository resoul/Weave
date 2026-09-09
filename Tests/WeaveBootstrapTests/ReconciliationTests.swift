import Testing
import Weave

@Test
func test_reconciler_keyedMovePreservesIdentity_andAppliesUpdate() {
    let old = [
        NodeDescriptor(typeName: "Row", key: "a"),
        NodeDescriptor(typeName: "Row", key: "b"),
    ]
    let new = [
        NodeDescriptor(typeName: "Row", key: "b"),
        NodeDescriptor(typeName: "Row", key: "a"),
    ]
    let diff = Reconciler.diff(old: old, new: new)
    #expect(
        diff.patches.contains {
            if case .move = $0 { true } else { false }
        }
    )
    #expect(
        !diff.patches.contains {
            if case .insert = $0 { true } else { false }
        }
    )
}

@Test
func test_reconciler_identicalInputProducesNoPatches() {
    let values = [NodeDescriptor(typeName: "Leaf", key: "x")]
    #expect(Reconciler.diff(old: values, new: values).patches.isEmpty)
}

@Test
func test_reconcilerTypeChangeReplaces_andDuplicateKeysDiagnose() {
    let old = [NodeDescriptor(typeName: "Row", key: "x")]
    let changed = [NodeDescriptor(typeName: "Card", key: "x")]
    let replacement = Reconciler.diff(old: old, new: changed)
    #expect(
        replacement.patches.contains {
            if case .replace = $0 { true } else { false }
        }
    )

    let duplicate = Reconciler.diff(
        old: [],
        new: [
            NodeDescriptor(typeName: "Row", key: "x"),
            NodeDescriptor(typeName: "Row", key: "x"),
        ]
    )
    #expect(duplicate.diagnostics.duplicateKeys == ["x"])
}

@Test
func test_reconcilerPatchesApplyToTheNewSequence() {
    let old = [
        NodeDescriptor(typeName: "Row", key: "a"),
        NodeDescriptor(typeName: "Row", key: "b"),
        NodeDescriptor(typeName: "Row", key: "c"),
    ]
    let new = [
        NodeDescriptor(typeName: "Row", key: "c"),
        NodeDescriptor(typeName: "Row", key: "a"),
        NodeDescriptor(typeName: "Card", key: "d"),
    ]
    var applied = old
    for patch in Reconciler.diff(old: old, new: new).patches {
        switch patch {
        case let .insert(descriptor, index):
            applied.insert(descriptor, at: index)
        case let .remove(_, index):
            applied.remove(at: index)
        case let .update(index, descriptor), let .replace(index, descriptor):
            applied[index] = descriptor
        case let .move(_, from, to):
            let descriptor = applied.remove(at: from)
            applied.insert(descriptor, at: to)
        }
    }
    #expect(applied == new)
}
