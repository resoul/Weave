import Foundation
import Testing
import Storage
import Weave

private actor ImageRecorder {
    var requests: [ImageRequest] = []
    func append(_ request: ImageRequest) { requests.append(request) }
    func last() -> ImageRequest? { requests.last }
    func count() -> Int { requests.count }
}

private struct FakeImageLoader: ImageLoader, Sendable {
    let recorder: ImageRecorder
    let shouldFail: Bool

    func load(_ request: ImageRequest) async throws -> LoadedImage {
        await recorder.append(request)
        if shouldFail { throw ImageFailure(message: "corrupt") }
        return LoadedImage(data: Data([1, 2, 3]), size: MeasuredSize(width: 40, height: 20))
    }
}

@Test
@MainActor
func imageNodeAppliesLatestLoadedImageAndDownsampleRequest() async {
    let recorder = ImageRecorder()
    let source = ImageSource(url: URL(string: "https://example.com/image.png")!)
    let node = ImageNode(
        source: source, loader: FakeImageLoader(recorder: recorder, shouldFail: false))
    node.targetSize = MeasuredSize(width: 80, height: 60)
    node.scale = 2
    node.reload()
    for _ in 0..<4 { await Task.yield() }
    #expect(node.image?.size == MeasuredSize(width: 40, height: 20))
    #expect(node.loadingState == .loaded(node.image!))
    #expect(await recorder.last()?.targetSize == MeasuredSize(width: 80, height: 60))
    #expect(await recorder.last()?.scale == 2)
}

@Test
@MainActor
func imageNodeExposesCorruptDataAndDecorativeAccessibility() async {
    let source = ImageSource(url: URL(string: "https://example.com/bad.png")!)
    let node = ImageNode(
        source: source,
        loader: FakeImageLoader(recorder: ImageRecorder(), shouldFail: true),
        semantic: .decorative)
    node.reload()
    for _ in 0..<4 { await Task.yield() }
    #expect(node.accessibility.isElement == false)
    #expect(node.loadingState == .failed(ImageFailure(message: "corrupt")))
}

@Test
@MainActor
func imageNodeCancellationDoesNotApplyHiddenResult() async {
    let recorder = ImageRecorder()
    let source = ImageSource(url: URL(string: "https://example.com/image.png")!)
    let node = ImageNode(
        source: source, loader: FakeImageLoader(recorder: recorder, shouldFail: false))
    node.setVisible(false)
    node.reload()
    for _ in 0..<4 { await Task.yield() }
    #expect(node.image == nil)
    #expect(node.loadingState == .idle)
}

@Test
func cachedImageLoaderUsesSharedBinaryStore() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "weave-image-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = try FileCacheStore(directory: directory, evictionPolicy: .none)
    let memory = ImageMemoryCache(maxBytes: 32)
    let recorder = ImageRecorder()
    let request = ImageRequest(
        source: ImageSource(url: URL(string: "https://example.com/cached.png")!))
    let first = CachedImageLoader(
        loader: FakeImageLoader(recorder: recorder, shouldFail: false), cache: cache,
        memoryCache: memory)
    _ = try await first.load(request)
    _ = try await first.load(request)
    #expect(await recorder.count() == 1)
    let secondRecorder = ImageRecorder()
    let second = CachedImageLoader(
        loader: FakeImageLoader(recorder: secondRecorder, shouldFail: true), cache: cache,
        memoryCache: memory)
    let warm = try await second.load(request)
    #expect(warm.data == Data([1, 2, 3]))
    #expect(await secondRecorder.last() == nil)
}

@Test
func imageMemoryCacheEvictsDecodedBytesWithoutChangingDiskBudget() async {
    let cache = ImageMemoryCache(maxBytes: 5)
    let first = LoadedImage(data: Data([1, 2, 3]), size: MeasuredSize(width: 1, height: 1))
    let second = LoadedImage(data: Data([4, 5, 6]), size: MeasuredSize(width: 1, height: 1))
    await cache.insert(first, for: "first")
    await cache.insert(second, for: "second")
    #expect(await cache.image(for: "first") == nil)
    #expect(await cache.image(for: "second") == second)
    #expect(await cache.byteUsage() == 3)
}
