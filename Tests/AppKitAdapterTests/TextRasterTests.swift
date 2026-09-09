#if canImport(AppKit)
    import AppKit
    import Testing
    import Weave
    @testable import AppKitAdapter
    @testable import WeaveAdapters

    @Suite("CoreTextRasterTests")
    struct CoreTextRasterTests {
        @Test
        @MainActor
        func measurableTextUsesCoreTextForConstrainedHeightAndBaseline() {
            let backend = CoreTextLayoutBackend()
            let input = TextLayoutInput(
                text: String(repeating: "wrapped text ", count: 12),
                style: TextStyle(pointSize: 14),
                constraint: SizeConstraint(width: .atMost(100))
            )
            let metrics = backend.measure(input)

            #expect(metrics.size.width <= 100)
            #expect(metrics.lineCount > 1)
            #expect(metrics.firstBaseline > 0)
        }

        @Test
        @MainActor
        func baselineTextNodesAlignUsingCoreTextBaselines() {
            let backend = CoreTextLayoutBackend()
            let small = TextNode(
                text: "small", style: TextStyle(pointSize: 14), backend: backend)
            let large = TextNode(
                text: "large", style: TextStyle(pointSize: 28), backend: backend)
            let root = LayoutInputSnapshot(
                identity: 100,
                style: LayoutStyle(
                    alignItems: .baseline, width: .points(300), height: .points(80)),
                children: [small.makeLayoutInputSnapshot(), large.makeLayoutInputSnapshot()]
            )
            let result = FlexSolver.layoutContainer(
                input: root, frame: LayoutFrame(width: 300, height: 80))
            let measured = FlexSolver.measureContainer(input: root)
            #expect(measured.lines[0].items.compactMap(\.baseline).count == 2)
            let smallSnapshot = root.children[0]
            let largeSnapshot = root.children[1]
            guard let smallPlacement = result.placement(for: smallSnapshot.identity),
                let largePlacement = result.placement(for: largeSnapshot.identity),
                let smallBaselineOffset = smallSnapshot.content.firstBaseline,
                let largeBaselineOffset = largeSnapshot.content.firstBaseline
            else {
                Issue.record("Expected placements and CoreText baselines for both text nodes")
                return
            }
            let smallBaseline = smallPlacement.frame.origin.y + smallBaselineOffset
            let largeBaseline = largePlacement.frame.origin.y + largeBaselineOffset

            // Layout applies the platform pixel rounding policy after baseline alignment.
            #expect(
                abs(smallBaseline - largeBaseline) <= 0.5,
                "small=\(smallBaseline), large=\(largeBaseline)")
        }

        @Test
        @MainActor
        func constrainedCoreTextMeasurementHasReferenceTwoLineRange() {
            let backend = CoreTextLayoutBackend()
            let text = "The quick brown fox jumps"
            let style = TextStyle(pointSize: 16)
            let singleLine = backend.measure(
                TextLayoutInput(text: text, style: style, constraint: SizeConstraint()))
            let wrapped = backend.measure(
                TextLayoutInput(
                    text: text, style: style,
                    constraint: SizeConstraint(width: .atMost(100))))

            // The range guards against both no-wrap regression (height ~= single line) and
            // over-wrapping/broken measurement (height far above two lines).
            #expect(wrapped.size.height > singleLine.size.height * 1.5)
            #expect(wrapped.size.height < singleLine.size.height * 2.5)
        }

        @Test
        @MainActor
        func snapshotBuilderRecreatesCoreTextMeasurementForConstraintReflow() {
            let backend = CoreTextLayoutBackend()
            let node = TextNode(
                text: String(repeating: "reflow text ", count: 8), backend: backend)
            let wide = node.makeLayoutInputSnapshot(
                constraint: SizeConstraint(width: .atMost(240)))
            let narrow = node.makeLayoutInputSnapshot(
                constraint: SizeConstraint(width: .atMost(100)))

            #expect(narrow.content.intrinsic.height > wide.content.intrinsic.height * 1.5)
            #expect(narrow.content.firstBaseline == wide.content.firstBaseline)
        }

        @Test
        func emptyTextProducesEmptyPayload() throws {
            let request = TextRenderRequest(
                nodeID: 1,
                text: "",
                style: TextStyle(),
                bounds: LayoutFrame(width: 100, height: 20),
                scale: 2.0,
                direction: .leftToRight,
                localeIdentifier: "en_US",
                maxLines: nil,
                truncation: .clip,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1
            )
            let artifact = try CoreTextRasterRenderer.render(request: request)
            guard case .empty = artifact.payload else {
                Issue.record("Expected empty display payload for empty text")
                return
            }
        }

        @Test
        func singleLineAndMultilineTextRendersValidImage() throws {
            let text = "Hello Weave\nAsync CoreText Rendering"
            let request = TextRenderRequest(
                nodeID: 2,
                text: text,
                style: TextStyle(pointSize: 16),
                bounds: LayoutFrame(width: 200, height: 60),
                scale: 2.0,
                direction: .leftToRight,
                localeIdentifier: "en_US",
                maxLines: nil,
                truncation: .clip,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1
            )
            let artifact = try CoreTextRasterRenderer.render(request: request)
            guard case let .image(image) = artifact.payload else {
                Issue.record("Expected CGImage display payload")
                return
            }
            #expect(image.width == 400)
            #expect(image.height == 120)
        }

        @Test
        func emojiAndCombiningMarksRenderWithoutError() throws {
            let text = "Weave UI 🚀🎉👨‍👩‍👧‍👦 e\u{0301}a\u{0300}"
            let request = TextRenderRequest(
                nodeID: 3,
                text: text,
                style: TextStyle(pointSize: 18),
                bounds: LayoutFrame(width: 250, height: 40),
                scale: 2.0,
                direction: .leftToRight,
                localeIdentifier: "en_US",
                maxLines: 1,
                truncation: .clip,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1
            )
            let artifact = try CoreTextRasterRenderer.render(request: request)
            guard case let .image(image) = artifact.payload else {
                Issue.record("Expected CGImage display payload for emoji")
                return
            }
            #expect(image.width > 0)
            #expect(image.height > 0)
        }

        @Test
        func arabicAndHebrewBidiRendersValidImage() throws {
            let text = "English مرحبا بالعالم שלום עולם mixed"
            let request = TextRenderRequest(
                nodeID: 4,
                text: text,
                style: TextStyle(pointSize: 16),
                bounds: LayoutFrame(width: 300, height: 50),
                scale: 1.0,
                direction: .rightToLeft,
                localeIdentifier: "ar_SA",
                maxLines: nil,
                truncation: .clip,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1
            )
            let artifact = try CoreTextRasterRenderer.render(request: request)
            guard case let .image(image) = artifact.payload else {
                Issue.record("Expected CGImage display payload for RTL text")
                return
            }
            #expect(image.width == 300)
            #expect(image.height == 50)
        }

        @Test
        func truncationProducesBoundedHeight() {
            let longText = String(
                repeating: "The quick brown fox jumps over the lazy dog. ", count: 10)
            let metrics = CoreTextRasterRenderer.measure(
                text: longText,
                style: TextStyle(pointSize: 14),
                constraint: SizeConstraint(width: .atMost(150)),
                maxLines: 2,
                truncation: .tail(ellipsis: "...")
            )
            #expect(metrics.lineCount <= 2)
            #expect(metrics.didTruncate)
            #expect(metrics.size.width <= 150)
        }
    }

    @Suite("TextDisplayGenerationTests")
    struct TextDisplayGenerationTests {
        @Test
        @MainActor
        func rapidTextUpdatesCommitOnlyLatestArtifact() async {
            let coordinator = RenderCoordinator()
            let textNode = TextNode(text: "Initial")
            coordinator.mount(root: textNode)

            var committedArtifacts: [DisplayArtifact] = []
            coordinator.onCommitDisplayArtifact = { artifact in
                committedArtifacts.append(artifact)
            }

            coordinator.invalidate(
                root: textNode,
                bounds: LayoutFrame(width: 200, height: 40),
                scale: 2.0
            )

            // Allow layout and display to commit
            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()

            #expect(coordinator.committedCount == 1)
            #expect(!committedArtifacts.isEmpty)

            // Now update text twice rapidly
            textNode.setText("Second Text")
            textNode.setText("Third Text Final")

            coordinator.invalidate(
                root: textNode,
                bounds: LayoutFrame(width: 200, height: 40),
                scale: 2.0
            )

            for _ in 0..<30 where coordinator.committedCount < 2 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()

            #expect(coordinator.committedCount == 2)
            guard let lastArtifact = committedArtifacts.last else {
                Issue.record("Expected committed display artifact")
                return
            }
            #expect(lastArtifact.nodeID == textNode.id)
            #expect(lastArtifact.contentRevision == textNode.displayRevision)
        }
    }

    @Suite("TextMeasureDisplayConsistencyTests")
    struct TextMeasureDisplayConsistencyTests {
        @Test
        func measureAndRenderMatchDimensions() throws {
            let text = "Consistency Test String"
            let style = TextStyle(pointSize: 15)
            let metrics = CoreTextRasterRenderer.measure(
                text: text,
                style: style,
                constraint: SizeConstraint(width: .atMost(200))
            )

            let request = TextRenderRequest(
                nodeID: 10,
                text: text,
                style: style,
                bounds: LayoutFrame(width: metrics.size.width, height: metrics.size.height),
                scale: 2.0,
                direction: .leftToRight,
                localeIdentifier: "en_US",
                maxLines: nil,
                truncation: .clip,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1
            )
            let artifact = try CoreTextRasterRenderer.render(request: request)
            #expect(abs(artifact.size.width - metrics.size.width) < 0.001)
            #expect(abs(artifact.size.height - metrics.size.height) < 0.001)
        }
    }

    @Suite("TextMainActorTests")
    struct TextMainActorTests {
        @Test
        @MainActor
        func suspendedDisplaySchedulerDoesNotBlockMainActor() async {
            let coordinator = RenderCoordinator()
            let textNode = TextNode(text: "MainActor Responsiveness")
            coordinator.mount(root: textNode)

            coordinator.suspend()
            #expect(coordinator.isSuspended)

            coordinator.invalidate(
                root: textNode,
                bounds: LayoutFrame(width: 150, height: 30),
                scale: 1.0
            )

            var mainActorTicks = 0
            for _ in 0..<5 {
                mainActorTicks += 1
                await Task.yield()
            }
            #expect(mainActorTicks == 5)
            #expect(coordinator.committedCount == 0)

            coordinator.resume()
            #expect(!coordinator.isSuspended)

            coordinator.invalidate(
                root: textNode,
                bounds: LayoutFrame(width: 150, height: 30),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()
            #expect(coordinator.committedCount == 1)
        }
    }
#endif
