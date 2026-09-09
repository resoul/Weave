#if canImport(AppKit)
    import AppKit
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing
    import Weave
    @testable import AppKitAdapter
    @testable import WeaveAdapters

    private func makeTestPngData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else { return Data() }
        context.setFillColor(red: 0, green: 0.8, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, "public.png" as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private struct IntegrationImageLoader: ImageLoader, Sendable {
        let data: Data

        func load(_ request: ImageRequest) async throws -> LoadedImage {
            LoadedImage(data: data, size: MeasuredSize(width: 50, height: 50))
        }
    }

    @Suite("AsyncRenderPipelineTests")
    struct AsyncRenderPipelineTests {
        @Test
        @MainActor
        func endToEndRenderPipelineTrace() async throws {
            let container = Node()
            container.style = LayoutStyle(
                flexDirection: .column,
                width: .points(300),
                height: .points(200)
            )

            let textNode = TextNode(text: "Async Production Render Pipeline")
            textNode.style = LayoutStyle(width: .points(250), height: .points(30))

            let pngData = makeTestPngData(width: 50, height: 50)
            let imageNode = ImageNode(
                source: ImageSource(url: URL(string: "https://weave.local/icon.png")!),
                loader: IntegrationImageLoader(data: pngData)
            )
            imageNode.style = LayoutStyle(width: .points(50), height: .points(50))

            container.addSubnode(textNode)
            container.addSubnode(imageNode)

            imageNode.reload()
            for _ in 0..<30 where imageNode.image == nil {
                await Task.yield()
            }

            let coordinator = RenderCoordinator()
            coordinator.mount(root: container)

            var geometryCommitted = false
            var committedDisplayArtifacts: [DisplayArtifact] = []
            var postCommitFired = false

            coordinator.onCommitGeometry = { result, request in
                geometryCommitted = true
                #expect(result.placement(for: textNode.id) != nil)
                #expect(result.placement(for: imageNode.id) != nil)
            }

            coordinator.onCommitDisplayArtifact = { artifact in
                committedDisplayArtifacts.append(artifact)
            }

            coordinator.onPostCommit = { request in
                postCommitFired = true
            }

            // Invalidate layout and display
            coordinator.invalidate(
                root: container,
                bounds: LayoutFrame(width: 300, height: 200),
                scale: 2.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()

            #expect(coordinator.committedCount == 1)
            #expect(geometryCommitted)
            #expect(postCommitFired)
            #expect(!committedDisplayArtifacts.isEmpty)

            // Both TextNode and ImageNode must have committed display artifacts
            let artifactNodeIDs = Set(committedDisplayArtifacts.map(\.nodeID))
            #expect(artifactNodeIDs.contains(textNode.id))
            #expect(artifactNodeIDs.contains(imageNode.id))

            for artifact in committedDisplayArtifacts {
                guard case .image = artifact.payload else {
                    Issue.record(
                        "Expected raster image payload in committed display artifact for node \(artifact.nodeID)"
                    )
                    return
                }
            }
        }

        @Test
        func boundaryScanEnsuresNoSynchronousFlexSolverOrCATextLayerInLayerRenderers() throws {
            let repoRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // AppKitAdapterTests
                .deletingLastPathComponent()  // Tests
                .deletingLastPathComponent()  // repo root
            let appKitRendererPath =
                repoRoot.appendingPathComponent(
                    "Sources/AppKitAdapter/AppKitLayerRenderer.swift"
                ).path
            let uiKitRendererPath =
                repoRoot.appendingPathComponent(
                    "Sources/UIKitAdapter/UIKitLayerRenderer.swift"
                ).path

            let appKitCode = try String(contentsOfFile: appKitRendererPath, encoding: .utf8)
            let uiKitCode = try String(contentsOfFile: uiKitRendererPath, encoding: .utf8)

            #expect(!appKitCode.contains("FlexSolver.layoutContainer"))
            #expect(!appKitCode.contains("CATextLayer"))

            #expect(!uiKitCode.contains("FlexSolver.layoutContainer"))
            #expect(!uiKitCode.contains("CATextLayer"))
        }
    }

    private final class TestGate: @unchecked Sendable {
        private let lock = NSLock()
        private var opened = false

        func open() {
            lock.withLock { opened = true }
        }

        func wait() {
            while true {
                let isDone = lock.withLock { opened }
                if isDone { break }
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
    }

    @Suite("CoherentInteractionDuringDelayedRenderTests")
    struct CoherentInteractionDuringDelayedRenderTests {
        @Test
        @MainActor
        func interactionRetainsCommittedGenerationDuringWorkerDelay() async throws {
            let button = ButtonNode(title: "Commit Generation 1")
            button.style = LayoutStyle(width: .points(100), height: .points(40))

            let coordinator = RenderCoordinator()
            coordinator.mount(root: button)

            coordinator.invalidate(
                root: button,
                bounds: LayoutFrame(width: 100, height: 40),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 1)
            #expect(button.calculatedFrame?.width == 100)

            // Now schedule a second invalidation that delays inside worker until gate opens
            let gate = TestGate()
            let delayedEngine = LayoutEngine(solver: { input, frame, rounding, cache in
                gate.wait()
                return FlexSolver.layoutContainer(
                    input: input, frame: frame, roundingPolicy: rounding, cache: &cache)
            })
            let delayedCoordinator = RenderCoordinator(layoutEngine: delayedEngine)
            delayedCoordinator.mount(root: button)

            delayedCoordinator.invalidate(
                root: button,
                bounds: LayoutFrame(width: 250, height: 50),
                scale: 1.0
            )

            // Immediately while worker is paused on gate, active frame remains previous value
            #expect(button.calculatedFrame?.width == 100)

            // Open gate to permit worker to finish
            gate.open()

            for _ in 0..<200 where delayedCoordinator.committedCount == 0 {
                await Task.yield()
            }

            #expect(delayedCoordinator.committedCount == 1)
            #expect(button.calculatedFrame?.width == 250)
        }

        @Test
        @MainActor
        func noGhostPixelsOrArtifactsAfterRootReplacement() async throws {
            let rootA = TextNode(text: "Old Root A")
            let rootB = TextNode(text: "New Root B")

            let coordinator = RenderCoordinator()
            coordinator.mount(root: rootA)

            var committedForRootA = 0
            var committedForRootB = 0

            coordinator.onCommitDisplayArtifact = { artifact in
                if artifact.nodeID == rootA.id { committedForRootA += 1 }
                if artifact.nodeID == rootB.id { committedForRootB += 1 }
            }

            coordinator.invalidate(
                root: rootA,
                bounds: LayoutFrame(width: 200, height: 40),
                scale: 2.0
            )

            // Immediately replace root before A's display completes
            coordinator.replaceRoot(newRoot: rootB)

            coordinator.invalidate(
                root: rootB,
                bounds: LayoutFrame(width: 200, height: 40),
                scale: 2.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()

            #expect(coordinator.committedCount == 1)
            #expect(committedForRootA == 0)
            #expect(committedForRootB == 1)
        }
    }

    @Suite("BoundedQueueAndMemoryStressTests")
    struct BoundedQueueAndMemoryStressTests {
        @Test
        @MainActor
        func rapidInvalidationsRemainStrictlyBounded() async throws {
            let root = Node()
            root.style = LayoutStyle(width: .points(200), height: .points(100))

            let coordinator = RenderCoordinator()
            coordinator.mount(root: root)

            // Fire 50 rapid invalidations
            for i in 1...50 {
                coordinator.invalidate(
                    root: root,
                    bounds: LayoutFrame(width: Double(100 + i), height: Double(50 + i)),
                    scale: 1.0
                )
            }

            for _ in 0..<40 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            await coordinator.displayScheduler.quiescence()

            // Due to request coalescing and superseding, committed count is small (1 or 2), never 50
            #expect(coordinator.committedCount <= 2)
            #expect(coordinator.cancelledCount + coordinator.coalescedCount >= 48)
        }
    }

    @Suite("QuiescenceAndTimeoutTests")
    struct QuiescenceAndTimeoutTests {
        @Test
        @MainActor
        func quiescenceWaitsForBothLayoutAndDisplayPipelines() async throws {
            let text = TextNode(text: "Quiescence Barrier Test")
            let coordinator = RenderCoordinator()
            coordinator.mount(root: text)

            coordinator.invalidate(
                root: text,
                bounds: LayoutFrame(width: 200, height: 40),
                scale: 2.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }

            // Await quiescence of display scheduler
            await coordinator.displayScheduler.quiescence()

            #expect(coordinator.committedCount == 1)
            #expect(coordinator.currentRequest == nil)
        }
    }
#endif
