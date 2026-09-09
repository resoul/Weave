import Foundation
import Testing
import Weave

private struct NodeTreeTestImageLoader: ImageLoader, Sendable {
    func load(_ request: ImageRequest) async throws -> LoadedImage {
        LoadedImage(data: Data(), size: MeasuredSize(width: 1, height: 1))
    }
}

@Test
@MainActor
func style_chainedMutations_preserveEarlierFields() {
    let node = Node()
        .style { $0.flexDirection = .column }
        .style { $0.gap = 12 }

    #expect(node.style.flexDirection == .column)
    #expect(node.style.gap == 12)
}

@Test
@MainActor
func frame_nilAxis_preservesExistingValue() {
    let node = Node()
        .frame(width: 100, height: 50)
        .frame(width: 240)

    #expect(node.style.width == .points(240))
    #expect(node.style.height == .points(50))
}

@Test
@MainActor
func addSubnodes_conditionalsAndLoops_preserveSourceOrder() {
    let includeOptional = true
    let values = [1, 2]
    let first = Node()
    let second = Node()
    let optional = Node()
    let loopNodes = values.map { _ in Node() }
    let root = Node().addSubnodes {
        first
        if includeOptional {
            optional
        }
        second
        loopNodes
    }

    #expect(root.subnodes.count == 5)
    #expect(root.subnodes[0] === first)
    #expect(root.subnodes[1] === optional)
    #expect(root.subnodes[2] === second)
    #expect(root.subnodes[3] === loopNodes[0])
    #expect(root.subnodes[4] === loopNodes[1])
}

@Test
@MainActor
func addSubnodes_usesNodeCycleAndReparentPolicy() {
    let root = Node()
    let previousParent = Node()
    let child = Node()
    previousParent.addSubnode(child)

    root.addSubnodes {
        root
        previousParent
        child
    }

    #expect(root.subnodes.count == 2)
    #expect(root.subnodes[0] === previousParent)
    #expect(root.subnodes[1] === child)
    #expect(previousParent.subnodes.isEmpty)
    #expect(root.supernode == nil)
}

@Test
@MainActor
func configure_returnsSameDynamicType() {
    var calls = 0
    let node = TextNode(text: "Title").configure {
        calls += 1
        $0.maxLines = 2
    }

    #expect(node.maxLines == 2)
    #expect(calls == 1)
}

@Test
func textStyleDraft_selectedFields_preserveDefaults() {
    let style = TextStyle {
        $0.size = 30
        $0.bold = true
    }

    #expect(style.pointSize == 30)
    #expect(style.bold)
    #expect(style.fontName == "system")
    #expect(style.lineHeight == 0)
    #expect(style.color == nil)
}

@Test
func layoutStyleDraft_roundTripsEveryField() {
    let style = LayoutStyle {
        $0.flexDirection = .columnReverse
        $0.flexWrap = .wrapReverse
        $0.justifyContent = .spaceEvenly
        $0.alignContent = .spaceAround
        $0.alignItems = .baseline
        $0.alignSelf = .center
        $0.flexGrow = 2
        $0.flexShrink = 3
        $0.flexBasis = .points(10)
        $0.width = .fraction(0.5)
        $0.height = .points(80)
        $0.minWidth = .points(4)
        $0.maxWidth = .points(200)
        $0.minHeight = .points(5)
        $0.maxHeight = .points(160)
        $0.aspectRatio = 1.5
        $0.padding = DirectionalEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
        $0.margin = DirectionalEdgeInsets(top: 5, leading: 6, bottom: 7, trailing: 8)
        $0.gap = 9
        $0.crossGap = 10
        $0.positionType = .absolute
        $0.offsets = DirectionalEdgeOffsets(top: 11, leading: 12, bottom: 13, trailing: 14)
        $0.visual = LayoutVisualProperties(zIndex: 2, overflow: .hidden)
    }
    let roundTripped = LayoutStyle.bake(LayoutStyle.Draft(style))

    #expect(roundTripped == style)
}

@Test
func styleBuilders_preserveInitializerNormalization() {
    let textStyle = TextStyle {
        $0.size = -.infinity
    }
    let layoutStyle = LayoutStyle {
        $0.flexGrow = -.infinity
        $0.gap = .nan
        $0.aspectRatio = 0
    }

    #expect(textStyle.pointSize == 0)
    #expect(layoutStyle.flexGrow == 0)
    #expect(layoutStyle.gap == 0)
    #expect(layoutStyle.aspectRatio == nil)
}

@Test
func visualStyle_normalizesPaintMetrics() {
    let style = VisualStyle(
        border: Border(color: ThemeColor(red: 2, green: 0, blue: 0), width: -.infinity),
        cornerRadius: .nan,
        shadow: Shadow(
            color: ThemeColor(red: 0, green: 0, blue: 0),
            opacity: 2,
            radius: -.infinity,
            offset: LayoutPoint(x: .nan, y: 4)
        )
    )

    #expect(style.border?.width == 0)
    #expect(style.cornerRadius == 0)
    #expect(style.shadow?.opacity == 1)
    #expect(style.shadow?.radius == 0)
    #expect(style.shadow?.offset == LayoutPoint(x: 0, y: 4))
}

@Test
@MainActor
func visualStyle_invalidationIsIndependentAndReachesMountedRoot() {
    let root = Node()
    let child = Node()
    root.addSubnode(child)
    var target: Node?
    root.onInvalidateVisualStyle = { target = $0 }
    let layoutRevision = root.layoutRevision
    let displayRevision = root.displayRevision

    child.appearance = VisualStyle(background: .color(ThemeColor(red: 1, green: 0, blue: 0)))

    #expect(target === child)
    #expect(child.appearanceRevision == 1)
    #expect(root.layoutRevision == layoutRevision)
    #expect(root.displayRevision == displayRevision)
}

@Test
@MainActor
func visualStyleBuilder_preservesPreviousFields() {
    let node = Node()
        .appearance { $0.cornerRadius = 20 }
        .appearance { $0.background = .color(ThemeColor(red: 0, green: 0, blue: 1)) }

    #expect(node.appearance.cornerRadius == 20)
    #expect(node.appearance.background == .color(ThemeColor(red: 0, green: 0, blue: 1)))
}

@Test
@MainActor
func imperativeTreeBuild_doesNotStartLifecycleOrResourceWork() {
    let source = ImageSource(url: URL(string: "https://example.com/image.png")!)
    let image = ImageNode(source: source, loader: NodeTreeTestImageLoader())
    let root = Node().addSubnodes {
        image.configure { $0.contentMode = .fill }
    }

    #expect(root.lifecycleState == .created)
    #expect(image.lifecycleState == .created)
    #expect(image.loadingState == .idle)
    #expect(!image.isLoaded)
}
