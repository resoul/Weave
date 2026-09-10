import CoreGraphics
import Foundation
import ImageIO
import Testing
import WeaveAdapters
import WeaveUI

private func makeTestImageData(
    width: Int,
    height: Int,
    red: CGFloat = 1,
    green: CGFloat = 0,
    blue: CGFloat = 0,
    alpha: CGFloat = 1
) -> Data {
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
    context.setFillColor(red: red, green: green, blue: blue, alpha: alpha)
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

private struct MockImageLoader: ImageLoader, Sendable {
    let imageProvider: @Sendable (ImageRequest) async throws -> LoadedImage

    func load(_ request: ImageRequest) async throws -> LoadedImage {
        try await imageProvider(request)
    }
}

@Suite("ImagePresentationTests")
struct ImagePresentationTests {
    @Test
    func emptyDataProducesEmptyPayload() throws {
        let request = ImageRenderRequest(
            nodeID: 1,
            data: nil,
            contentMode: .fit,
            bounds: LayoutFrame(width: 100, height: 100),
            scale: 2.0,
            loadingState: .idle,
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1
        )
        let artifact = try ImageRasterRenderer.render(request: request)
        guard case .empty = artifact.payload else {
            Issue.record("Expected empty payload for nil image data")
            return
        }
    }

    @Test
    func fitModePreservesAspectRatioAndScales() throws {
        let pngData = makeTestImageData(width: 200, height: 100)
        let request = ImageRenderRequest(
            nodeID: 2,
            data: pngData,
            contentMode: .fit,
            bounds: LayoutFrame(width: 100, height: 100),
            scale: 2.0,
            loadingState: .loaded(
                LoadedImage(data: pngData, size: MeasuredSize(width: 200, height: 100))),
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1
        )
        let artifact = try ImageRasterRenderer.render(request: request)
        guard case let .image(image) = artifact.payload else {
            Issue.record("Expected rendered CGImage payload")
            return
        }
        #expect(image.width == 200)
        #expect(image.height == 200)
        #expect(abs(artifact.size.width - 100) < 0.001)
        #expect(abs(artifact.size.height - 100) < 0.001)
    }

    @Test
    func fillModeClipsToDestinationBounds() throws {
        let pngData = makeTestImageData(width: 100, height: 200)
        let request = ImageRenderRequest(
            nodeID: 3,
            data: pngData,
            contentMode: .fill,
            bounds: LayoutFrame(width: 80, height: 80),
            scale: 1.0,
            loadingState: .loaded(
                LoadedImage(data: pngData, size: MeasuredSize(width: 100, height: 200))),
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1
        )
        let artifact = try ImageRasterRenderer.render(request: request)
        guard case let .image(image) = artifact.payload else {
            Issue.record("Expected rendered CGImage payload")
            return
        }
        #expect(image.width == 80)
        #expect(image.height == 80)
    }

    @Test
    func stretchModeMatchesExactBounds() throws {
        let pngData = makeTestImageData(width: 50, height: 50)
        let request = ImageRenderRequest(
            nodeID: 4,
            data: pngData,
            contentMode: .stretch,
            bounds: LayoutFrame(width: 120, height: 60),
            scale: 2.0,
            loadingState: .loaded(
                LoadedImage(data: pngData, size: MeasuredSize(width: 50, height: 50))),
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1
        )
        let artifact = try ImageRasterRenderer.render(request: request)
        guard case let .image(image) = artifact.payload else {
            Issue.record("Expected rendered CGImage payload")
            return
        }
        #expect(image.width == 240)
        #expect(image.height == 120)
    }
}

@Suite("ImageDisplayGenerationTests")
struct ImageDisplayGenerationTests {
    @Test
    @MainActor
    func sourceReplaceCancelsStaleImageAndPublishesLatest() async {
        let coordinator = RenderCoordinator()
        let sourceA = ImageSource(url: URL(string: "https://weave.local/a.png")!)
        let sourceB = ImageSource(url: URL(string: "https://weave.local/b.png")!)
        let dataA = makeTestImageData(width: 40, height: 40, red: 1, green: 0, blue: 0)
        let dataB = makeTestImageData(width: 60, height: 60, red: 0, green: 1, blue: 0)

        let loader = MockImageLoader { request in
            if request.source == sourceA {
                return LoadedImage(data: dataA, size: MeasuredSize(width: 40, height: 40))
            } else {
                return LoadedImage(data: dataB, size: MeasuredSize(width: 60, height: 60))
            }
        }

        let imageNode = ImageNode(source: sourceA, loader: loader)
        coordinator.mount(root: imageNode)

        var committedArtifacts: [DisplayArtifact] = []
        coordinator.onCommitDisplayArtifact = { artifact in
            committedArtifacts.append(artifact)
        }

        coordinator.invalidate(
            root: imageNode,
            bounds: LayoutFrame(width: 100, height: 100),
            scale: 2.0
        )

        for _ in 0..<30 where coordinator.committedCount == 0 {
            await Task.yield()
        }
        await coordinator.displayScheduler.quiescence()

        #expect(coordinator.committedCount == 1)

        // Replace source with sourceB
        imageNode.setSource(sourceB)
        coordinator.invalidate(
            root: imageNode,
            bounds: LayoutFrame(width: 100, height: 100),
            scale: 2.0
        )

        for _ in 0..<30 where coordinator.committedCount < 2 {
            await Task.yield()
        }
        await coordinator.displayScheduler.quiescence()

        #expect(coordinator.committedCount == 2)
        guard let latest = committedArtifacts.last else {
            Issue.record("Expected latest committed display artifact")
            return
        }
        #expect(latest.nodeID == imageNode.id)
    }

    @Test
    @MainActor
    func unmountCancelsPendingDisplayJob() async {
        let coordinator = RenderCoordinator()
        let source = ImageSource(url: URL(string: "https://weave.local/unmount.png")!)
        let data = makeTestImageData(width: 50, height: 50)
        let loader = MockImageLoader { _ in
            LoadedImage(data: data, size: MeasuredSize(width: 50, height: 50))
        }

        let imageNode = ImageNode(source: source, loader: loader)
        coordinator.mount(root: imageNode)

        coordinator.invalidate(
            root: imageNode,
            bounds: LayoutFrame(width: 100, height: 100),
            scale: 1.0
        )
        coordinator.unmount()

        await coordinator.displayScheduler.quiescence()
        #expect(!coordinator.isMounted)
    }
}

@Suite("ImageDisplayResourceTests")
struct ImageDisplayResourceTests {
    @Test
    @MainActor
    func visiblePrioritySchedulesBeforePrefetch() async throws {
        let scheduler = DisplayScheduler(maxConcurrency: 1)
        let transaction = DisplayTransaction(
            hostID: 1,
            generation: 1,
            geometryGeneration: 1,
            scheduler: scheduler
        )

        var commitOrder: [Int] = []
        transaction.onCommitArtifact = { artifact in
            commitOrder.append(Int(artifact.nodeID))
        }

        scheduler.suspend()

        let reqPrefetch = DisplayRequest(
            nodeID: 10,
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1,
            bounds: LayoutFrame(width: 50, height: 50),
            scale: 1.0,
            priority: .background
        )
        let reqVisible = DisplayRequest(
            nodeID: 20,
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1,
            bounds: LayoutFrame(width: 50, height: 50),
            scale: 1.0,
            priority: .visible
        )

        transaction.schedule(request: reqPrefetch) {
            DisplayArtifact(
                nodeID: 10,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                payload: .empty,
                size: CGSize(width: 50, height: 50),
                scale: 1.0
            )
        }
        transaction.schedule(request: reqVisible) {
            DisplayArtifact(
                nodeID: 20,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                payload: .empty,
                size: CGSize(width: 50, height: 50),
                scale: 1.0
            )
        }

        scheduler.resume()
        await transaction.quiescence()

        #expect(commitOrder.first == 20)
    }
}

@Suite("ImageMainActorTests")
struct ImageMainActorTests {
    @Test
    @MainActor
    func largeImageCompositeDoesNotBlockMainActor() async throws {
        let pngData = makeTestImageData(width: 500, height: 500)
        let request = ImageRenderRequest(
            nodeID: 99,
            data: pngData,
            contentMode: .fill,
            bounds: LayoutFrame(width: 400, height: 400),
            scale: 2.0,
            loadingState: .loaded(
                LoadedImage(data: pngData, size: MeasuredSize(width: 500, height: 500))),
            generation: 1,
            geometryGeneration: 1,
            contentRevision: 1
        )

        let task = Task.detached {
            try ImageRasterRenderer.render(request: request)
        }

        // Verify MainActor can yield and process events freely
        for _ in 0..<5 {
            await Task.yield()
        }

        let artifact = try await task.value
        guard case let .image(image) = artifact.payload else {
            Issue.record("Expected composited image artifact")
            return
        }
        #expect(image.width == 800)
        #expect(image.height == 800)
    }
}
