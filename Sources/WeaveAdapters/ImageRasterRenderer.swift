import CoreGraphics
import Foundation
import ImageIO
import WeaveUI

/// Immutable render request for an ImageNode display pass.
/// Ownership: request copies image data snapshot and layout values. Isolation: Sendable; safe to cross actor boundaries.
/// Errors: invalid dimensions or data are handled gracefully during rendering. Cancellation: callers can cancel the task holding this request.
public struct ImageRenderRequest: Sendable, Hashable {
    public let nodeID: ElementID
    public let data: Data?
    public let contentMode: ImageContentMode
    public let bounds: LayoutFrame
    public let scale: Double
    public let loadingState: ImageLoadingState
    public let generation: UInt64
    public let geometryGeneration: UInt64
    public let contentRevision: UInt64

    /// Creates an immutable image raster request.
    /// Ownership: all parameters are copied into this struct. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        nodeID: ElementID,
        data: Data?,
        contentMode: ImageContentMode,
        bounds: LayoutFrame,
        scale: Double,
        loadingState: ImageLoadingState,
        generation: UInt64,
        geometryGeneration: UInt64,
        contentRevision: UInt64
    ) {
        self.nodeID = nodeID
        self.data = data
        self.contentMode = contentMode
        self.bounds = bounds
        self.scale = scale
        self.loadingState = loadingState
        self.generation = generation
        self.geometryGeneration = geometryGeneration
        self.contentRevision = contentRevision
    }
}

/// Thread-safe image decoding, scaling, and raster compositing engine.
/// Ownership: engine owns no platform views or persistent caches. Isolation: Sendable; safe to invoke from background workers.
/// Errors: invalid or corrupt image data produces an empty display artifact without throwing.
/// Cancellation: cooperatively checks Task cancellation before expensive decode and raster operations.
public enum ImageRasterRenderer: Sendable {
    /// Renders an image into an immutable display artifact according to contentMode and target bounds.
    /// Ownership: returned artifact owns the rendered CGImage. Isolation: Sendable; executes on background workers.
    /// Errors: throws CancellationError if cancelled. Cancellation: checked cooperatively before and after image operations.
    public static func render(request: ImageRenderRequest) throws -> DisplayArtifact {
        try Task.checkCancellation()

        guard request.bounds.width > 0, request.bounds.height > 0, request.scale > 0 else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        guard let data = request.data, !data.isEmpty else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        try Task.checkCancellation()

        let sourceOptions =
            [
                kCGImageSourceShouldCache: false as CFBoolean
            ] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        guard CGImageSourceGetCount(source) > 0,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        try Task.checkCancellation()

        let pixelWidth = max(1, Int(ceil(request.bounds.width * request.scale)))
        let pixelHeight = max(1, Int(ceil(request.bounds.height * request.scale)))
        let maxPixelDimension = max(pixelWidth, pixelHeight)

        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true as CFBoolean,
                kCGImageSourceShouldCacheImmediately: true as CFBoolean,
                kCGImageSourceCreateThumbnailWithTransform: true as CFBoolean,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension as CFNumber,
            ] as CFDictionary

        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
                ?? CGImageSourceCreateImageAtIndex(source, 0, sourceOptions)
        else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        try Task.checkCancellation()

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        context.scaleBy(x: CGFloat(request.scale), y: CGFloat(request.scale))

        let targetRect = CGRect(
            x: 0, y: 0, width: request.bounds.width, height: request.bounds.height)
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        if imageWidth > 0 && imageHeight > 0 {
            let drawRect: CGRect
            switch request.contentMode {
            case .stretch:
                drawRect = targetRect
            case .fit:
                let scaleW = targetRect.width / imageWidth
                let scaleH = targetRect.height / imageHeight
                let fitScale = min(scaleW, scaleH)
                let drawnWidth = imageWidth * fitScale
                let drawnHeight = imageHeight * fitScale
                let originX = (targetRect.width - drawnWidth) / 2.0
                let originY = (targetRect.height - drawnHeight) / 2.0
                drawRect = CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight)
            case .fill:
                let scaleW = targetRect.width / imageWidth
                let scaleH = targetRect.height / imageHeight
                let fillScale = max(scaleW, scaleH)
                let drawnWidth = imageWidth * fillScale
                let drawnHeight = imageHeight * fillScale
                let originX = (targetRect.width - drawnWidth) / 2.0
                let originY = (targetRect.height - drawnHeight) / 2.0
                drawRect = CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight)
                context.clip(to: targetRect)
            }

            try Task.checkCancellation()
            context.draw(cgImage, in: drawRect)
            try Task.checkCancellation()
        }

        guard let composited = context.makeImage() else {
            return DisplayArtifact(
                nodeID: request.nodeID,
                generation: request.generation,
                geometryGeneration: request.geometryGeneration,
                contentRevision: request.contentRevision,
                payload: .empty,
                size: CGSize(width: request.bounds.width, height: request.bounds.height),
                scale: request.scale
            )
        }

        return DisplayArtifact(
            nodeID: request.nodeID,
            generation: request.generation,
            geometryGeneration: request.geometryGeneration,
            contentRevision: request.contentRevision,
            payload: .image(composited),
            size: CGSize(width: request.bounds.width, height: request.bounds.height),
            scale: request.scale
        )
    }
}
