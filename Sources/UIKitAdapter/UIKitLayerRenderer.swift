#if canImport(UIKit)
    import UIKit
    import WeaveAdapters
    import WeaveUI

    /// CALayer renderer for one committed logical node tree.
    /// Ownership: the renderer owns only native layers and weakly borrows the logical root.
    /// Isolation: MainActor. Errors: absent roots are ignored. Cancellation: `unmount()` releases
    /// every native layer and makes later renders no-ops.
    @MainActor
    final class UIKitLayerRenderer {
        private final class SwipePresentation {
            let container = CALayer()
            let content = CALayer()

            init() {
                container.masksToBounds = true
                container.addSublayer(content)
            }
        }

        private weak var root: Node?
        private var layers: [ElementID: CALayer] = [:]
        private var baseFrames: [ElementID: CGRect] = [:]
        private var swipePresentations: [ElementID: SwipePresentation] = [:]
        private var swipeLayers: [ElementID: [CALayer]] = [:]
        private var swipeConfigurations: [ElementID: SwipeActionsConfiguration] = [:]

        init(root: Node) { self.root = root }

        func applyCommitted(
            result: LayoutResult, on hostLayer: CALayer, scale: CGFloat,
            animation: Animation? = nil
        ) {
            guard let root else { return }
            var active: Set<ElementID> = []
            CATransaction.begin()
            if let animation, animation.duration > .zero {
                CATransaction.setDisableActions(false)
                CATransaction.setAnimationDuration(animation.duration.timeInterval)
                CATransaction.setAnimationTimingFunction(animation.curve.mediaTimingFunction)
            } else {
                CATransaction.setDisableActions(true)
            }
            update(
                node: root,
                result: result,
                parentLayer: hostLayer,
                parentFrame: nil,
                scale: scale,
                active: &active
            )
            let stale = Set(layers.keys).subtracting(active)
            stale.forEach { staleID in
                if let videoNode = root.findNode(id: staleID) as? VideoNode,
                    let attachingBackend = videoNode.backend as? (any CALayerAttachingVideoBackend)
                {
                    attachingBackend.detachVideoLayer()
                }
                layers[staleID]?.removeFromSuperlayer()
                layers[staleID] = nil
                baseFrames[staleID] = nil
                swipePresentations[staleID]?.container.removeFromSuperlayer()
                swipePresentations[staleID] = nil
                swipeLayers[staleID]?.forEach { $0.removeFromSuperlayer() }
                swipeLayers[staleID] = nil
                swipeConfigurations[staleID] = nil
            }
            CATransaction.commit()
        }

        func unmount() {
            for (nodeID, layer) in layers {
                if let videoNode = root?.findNode(id: nodeID) as? VideoNode,
                    let attachingBackend = videoNode.backend as? (any CALayerAttachingVideoBackend)
                {
                    attachingBackend.detachVideoLayer()
                }
                layer.removeFromSuperlayer()
            }
            layers.removeAll()
            baseFrames.removeAll()
            swipePresentations.values.forEach { $0.container.removeFromSuperlayer() }
            swipePresentations.removeAll()
            swipeLayers.values.flatMap { $0 }.forEach { $0.removeFromSuperlayer() }
            swipeLayers.removeAll()
            swipeConfigurations.removeAll()
            root = nil
        }

        private func update(
            node: Node,
            result: LayoutResult,
            parentLayer: CALayer?,
            parentFrame: LayoutFrame?,
            scale: CGFloat,
            active: inout Set<ElementID>
        ) {
            guard let frame = result.placement(for: node.id)?.frame ?? node.calculatedFrame else {
                return
            }
            active.insert(node.id)
            let layer = layers[node.id] ?? makeLayer(for: node)
            layers[node.id] = layer
            let parentOrigin = parentFrame?.origin ?? LayoutPoint(x: 0, y: 0)
            let baseFrame = CGRect(
                x: frame.origin.x - parentOrigin.x,
                y: frame.origin.y - parentOrigin.y,
                width: frame.width,
                height: frame.height
            )
            let previousSize = baseFrames[node.id]?.size
            baseFrames[node.id] = baseFrame
            if let presentation = swipePresentations[node.id] {
                configure(
                    presentation: presentation, rowLayer: layer, baseFrame: baseFrame,
                    parentLayer: parentLayer)
            } else {
                let newBounds = CGRect(origin: layer.bounds.origin, size: baseFrame.size)
                let newPosition = CGPoint(
                    x: baseFrame.origin.x + baseFrame.width * layer.anchorPoint.x,
                    y: baseFrame.origin.y + baseFrame.height * layer.anchorPoint.y
                )
                // A raster content layer (text glyphs, images, video frames) has no vector
                // geometry to interpolate: animating its bounds just stretches the existing
                // bitmap between the old and new size until the next display pass swaps it in,
                // which reads as smeared/stretched content snapping to correct at the end. Only
                // the surrounding (vector-painted) layers should pick up the transaction's
                // animation; raster content always snaps to its final geometry instantly.
                if node is TextNode || node is ImageNode || node is VideoNode {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.bounds = newBounds
                    layer.position = newPosition
                    layer.setAffineTransform(node.style.visual.transform.affineTransform)
                    // The new bitmap for this size lands later via a separate async display
                    // commit (`applyArtifact`). Left alone, the layer's default contentsGravity
                    // stretches the *stale* bitmap to fill the already-resized bounds in the
                    // meantime — visible as smeared/stretched glyphs until the new one arrives.
                    // Dropping stale contents the instant the size actually changes trades that
                    // for a brief blank gap, which reads far better than stretched content.
                    if let previousSize, previousSize != baseFrame.size {
                        layer.contents = nil
                    }
                    CATransaction.commit()
                } else {
                    layer.bounds = newBounds
                    layer.position = newPosition
                    layer.setAffineTransform(node.style.visual.transform.affineTransform)
                }
                if layer.superlayer !== parentLayer { parentLayer?.addSublayer(layer) }
            }
            applyVisualStyle(
                node.appearance,
                to: layer,
                theme: node.environmentSnapshot.values[ThemeKey.self]
            )
            // `style.visual.overflow`/`opacity`/`zIndex` were previously never consulted by any
            // renderer — the layout/hit-test side already understood them (HitTester sorts by
            // zIndex and inverse-transforms hit points), but nothing ever painted their effect.
            layer.masksToBounds = node.style.visual.overflow == .hidden
            layer.opacity = Float(node.style.visual.opacity)
            layer.zPosition = CGFloat(node.style.visual.zIndex)
            swipePresentations[node.id]?.container.cornerRadius = layer.cornerRadius
            if let scrollNode = node as? ScrollNode {
                layer.masksToBounds = true
                layer.bounds.origin = CGPoint(
                    x: CGFloat(scrollNode.state.offset.x),
                    y: CGFloat(scrollNode.state.offset.y)
                )
            }
            if let videoNode = node as? VideoNode,
                let attachingBackend = videoNode.backend as? (any CALayerAttachingVideoBackend)
            {
                attachingBackend.attachVideoLayer(to: layer)
                attachingBackend.updateVideoLayerBounds(layer.bounds)
            }
            node.subnodes.forEach {
                update(
                    node: $0,
                    result: result,
                    parentLayer: layer,
                    parentFrame: frame,
                    scale: scale,
                    active: &active
                )
            }
        }

        /// Applies paint-only presentation to an already materialized node layer.
        /// Ownership: the renderer owns the native layer. Isolation: MainActor. Errors: an
        /// unknown node is ignored. Cancellation: not applicable.
        func applyVisualOnly(nodeID: ElementID, appearance: VisualStyle) {
            guard let layer = layers[nodeID] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyVisualStyle(appearance, to: layer)
            CATransaction.commit()
        }

        /// Presents action layers behind one materialized row and applies its committed offset.
        /// Ownership: the renderer owns the temporary layers. Isolation: MainActor. Errors:
        /// unknown rows or empty configurations are ignored. Cancellation: a closed state removes
        /// all action layers for the row.
        func applySwipeReveal(
            node: Node,
            state: SwipeRevealState,
            configuration: SwipeActionsConfiguration?,
            theme: Theme
        ) {
            guard let rowLayer = layers[node.id] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            guard let configuration, !configuration.actions.isEmpty else {
                teardownSwipePresentation(nodeID: node.id, rowLayer: rowLayer)
                return
            }
            let edge: SwipeEdge
            let offset: Double
            switch state {
            case .closed, .cancelled:
                teardownSwipePresentation(nodeID: node.id, rowLayer: rowLayer)
                return
            case let .revealing(value, current), let .open(value, current),
                let .settling(value, current):
                edge = value
                offset = current
            }
            guard let presentation = ensureSwipePresentation(nodeID: node.id, rowLayer: rowLayer)
            else { return }
            if swipeConfigurations[node.id] != configuration {
                swipeLayers[node.id]?.forEach { $0.removeFromSuperlayer() }
                swipeLayers[node.id] = nil
            }
            let actionLayers =
                swipeLayers[node.id]
                ?? makeSwipeLayers(
                    configuration: configuration, theme: theme, rowFrame: rowLayer.bounds,
                    nodeID: node.id)
            swipeLayers[node.id] = actionLayers
            swipeConfigurations[node.id] = configuration
            let revealedWidth = abs(CGFloat(offset))
            let fullSwipePresentation =
                configuration.performsFirstActionWithFullSwipe
                && revealedWidth > CGFloat(actionLayers.count) * 72
            for (index, actionLayer) in actionLayers.enumerated() {
                let width = CGFloat(72)
                if fullSwipePresentation, index == 0 {
                    let fixedActionsWidth = CGFloat(max(0, actionLayers.count - 1)) * width
                    actionLayer.frame = CGRect(
                        x: edge == .leading
                            ? fixedActionsWidth
                            : presentation.container.bounds.width - revealedWidth,
                        y: 0,
                        width: max(width, revealedWidth - fixedActionsWidth),
                        height: presentation.container.bounds.height
                    )
                    actionLayer.opacity = 1
                    if let titleLayer = actionLayer.sublayers?.first {
                        titleLayer.frame.origin.x =
                            edge == .leading
                            ? 4
                            : max(4, revealedWidth - CGFloat(actionLayers.count) * width + 4)
                    }
                } else {
                    actionLayer.frame = CGRect(
                        x: edge == .leading
                            ? (index == 0
                                ? CGFloat(max(0, actionLayers.count - 1)) * width
                                : CGFloat(index - 1) * width)
                            : presentation.container.bounds.width
                                - CGFloat(actionLayers.count - index) * width,
                        y: 0,
                        width: width,
                        height: presentation.container.bounds.height
                    )
                    actionLayer.opacity = 1
                    if let titleLayer = actionLayer.sublayers?.first {
                        titleLayer.frame.origin.x = 4
                    }
                }
                if actionLayer.superlayer !== presentation.container {
                    presentation.container.insertSublayer(actionLayer, below: presentation.content)
                }
            }
            let scale = max(1, rowLayer.contentsScale)
            let alignedOffset = (CGFloat(offset) * scale).rounded() / scale
            presentation.content.setAffineTransform(
                CGAffineTransform(translationX: alignedOffset, y: 0))
        }

        private func ensureSwipePresentation(
            nodeID: ElementID,
            rowLayer: CALayer
        ) -> SwipePresentation? {
            if let presentation = swipePresentations[nodeID] { return presentation }
            guard let parent = rowLayer.superlayer, let baseFrame = baseFrames[nodeID] else {
                return nil
            }
            let presentation = SwipePresentation()
            swipePresentations[nodeID] = presentation
            parent.insertSublayer(presentation.container, below: rowLayer)
            rowLayer.removeFromSuperlayer()
            presentation.content.addSublayer(rowLayer)
            configure(
                presentation: presentation, rowLayer: rowLayer, baseFrame: baseFrame,
                parentLayer: parent)
            presentation.container.cornerRadius = rowLayer.cornerRadius
            return presentation
        }

        private func configure(
            presentation: SwipePresentation,
            rowLayer: CALayer,
            baseFrame: CGRect,
            parentLayer: CALayer?
        ) {
            presentation.container.bounds = CGRect(origin: .zero, size: baseFrame.size)
            presentation.container.position = CGPoint(x: baseFrame.midX, y: baseFrame.midY)
            if presentation.container.superlayer !== parentLayer {
                parentLayer?.addSublayer(presentation.container)
            }
            presentation.content.bounds = presentation.container.bounds
            presentation.content.position = CGPoint(
                x: presentation.container.bounds.midX, y: presentation.container.bounds.midY)
            rowLayer.bounds.size = baseFrame.size
            rowLayer.position = CGPoint(
                x: baseFrame.width * rowLayer.anchorPoint.x,
                y: baseFrame.height * rowLayer.anchorPoint.y)
            if rowLayer.superlayer !== presentation.content {
                presentation.content.addSublayer(rowLayer)
            }
        }

        private func teardownSwipePresentation(nodeID: ElementID, rowLayer: CALayer) {
            guard let presentation = swipePresentations.removeValue(forKey: nodeID) else {
                rowLayer.setAffineTransform(.identity)
                return
            }
            let parent = presentation.container.superlayer
            presentation.content.setAffineTransform(.identity)
            rowLayer.removeFromSuperlayer()
            if let parent { parent.insertSublayer(rowLayer, above: presentation.container) }
            presentation.container.removeFromSuperlayer()
            if let baseFrame = baseFrames[nodeID] {
                rowLayer.bounds.size = baseFrame.size
                rowLayer.position = CGPoint(
                    x: baseFrame.origin.x + baseFrame.width * rowLayer.anchorPoint.x,
                    y: baseFrame.origin.y + baseFrame.height * rowLayer.anchorPoint.y)
            }
            swipeLayers[nodeID]?.forEach { $0.removeFromSuperlayer() }
            swipeLayers[nodeID] = nil
            swipeConfigurations[nodeID] = nil
        }

        /// Commits a scroll offset without scheduling layout or replacing display artifacts.
        func applyScrollOffset(node: ScrollNode) {
            guard let layer = layers[node.id] else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.bounds.origin = CGPoint(x: node.state.offset.x, y: node.state.offset.y)
            CATransaction.commit()
        }

        func applyEdgePull(node: ScrollNode) {
            guard let layer = layers[node.id] else {
                return
            }
            let target: CGFloat
            switch node.edgePullState {
            case let .pulling(edge, _, distance), let .armed(edge, distance):
                target = edge == .start ? CGFloat(distance) : -CGFloat(distance)
            case .active(let edge):
                target =
                    edge == .start
                    ? CGFloat(node.edgePullPresentationDistance)
                    : -CGFloat(node.edgePullPresentationDistance)
            case .idle, .settling, .cancelled:
                target = 0
            }
            let current = layer.affineTransform().ty
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if target == 0, abs(current) > 0.01 {
                let animation = CABasicAnimation(keyPath: "transform.translation.y")
                animation.fromValue = current
                animation.toValue = 0
                animation.duration = 0.28
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: "weave.edgePull.settle")
                layer.setAffineTransform(.identity)
            } else {
                layer.removeAnimation(forKey: "weave.edgePull.settle")
                layer.setAffineTransform(CGAffineTransform(translationX: 0, y: target))
            }
            CATransaction.commit()
        }

        private func makeSwipeLayers(
            configuration: SwipeActionsConfiguration,
            theme: Theme,
            rowFrame: CGRect,
            nodeID: ElementID
        ) -> [CALayer] {
            configuration.actions.map { action in
                let layer = CALayer()
                layer.masksToBounds = true
                let color =
                    action.tint.map { resolveThemeColor($0, in: theme) } ?? theme.colors.accent
                layer.backgroundColor = CGColor(
                    red: CGFloat(color.red), green: CGFloat(color.green),
                    blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
                let scale = UIScreen.main.scale
                let title = CALayer()
                title.contentsGravity = .center
                title.contentsScale = scale
                title.frame = CGRect(
                    x: 4, y: max(0, rowFrame.height / 2 - 9), width: 64, height: 18)
                layer.addSublayer(title)
                renderSwipeActionTitle(
                    action.title, into: title, scale: Double(scale), nodeID: nodeID)
                return layer
            }
        }

        /// Rasterizes a swipe-action title off the main actor and applies it once ready.
        /// Ownership: `layer` is borrowed weakly so a stale action outlives its title harmlessly.
        /// Isolation: MainActor caller; rasterization runs on a background task. Errors: a failed
        /// or cancelled render leaves the layer without contents. Cancellation: not applicable.
        private func renderSwipeActionTitle(
            _ text: String, into layer: CALayer, scale: Double, nodeID: ElementID
        ) {
            let request = TextRenderRequest(
                nodeID: nodeID,
                text: text,
                style: TextStyle(pointSize: 14, color: ThemeColor(red: 1, green: 1, blue: 1)),
                bounds: LayoutFrame(width: layer.frame.width, height: layer.frame.height),
                scale: scale,
                direction: .leftToRight,
                localeIdentifier: "en_US_POSIX",
                maxLines: 1,
                truncation: .tail(ellipsis: "…"),
                generation: 0,
                geometryGeneration: 0,
                contentRevision: 0
            )
            Task { [weak layer] in
                guard let artifact = try? CoreTextRasterRenderer.render(request: request),
                    case .image(let image) = artifact.payload
                else { return }
                await MainActor.run { layer?.contents = image }
            }
        }

        /// Applies a committed asynchronous display artifact to the node's backing CALayer.
        /// Ownership: artifact is borrowed during commit. Isolation: MainActor. Errors: none. Cancellation: not applicable.
        public func applyArtifact(_ artifact: DisplayArtifact) {
            guard let layer = layers[artifact.nodeID] else { return }
            switch artifact.payload {
            case .image(let image):
                layer.contents = image
                layer.contentsScale = artifact.scale
            case .color(let themeColor):
                layer.backgroundColor = CGColor(
                    red: CGFloat(themeColor.red),
                    green: CGFloat(themeColor.green),
                    blue: CGFloat(themeColor.blue),
                    alpha: CGFloat(themeColor.alpha)
                )
            case .empty:
                layer.contents = nil
            case .bytes(let data, let width, let height, let bytesPerRow):
                guard width > 0, height > 0, bytesPerRow > 0,
                    let provider = CGDataProvider(data: data as CFData),
                    let image = CGImage(
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bitsPerPixel: 32,
                        bytesPerRow: bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(
                            rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider,
                        decode: nil,
                        shouldInterpolate: true,
                        intent: .defaultIntent
                    )
                else {
                    layer.contents = nil
                    break
                }
                layer.contents = image
                layer.contentsScale = artifact.scale
            }
        }

        private func makeLayer(for node: Node) -> CALayer {
            _ = node
            let layer = CALayer()
            layer.masksToBounds = false
            return layer
        }
    }
#endif
