#if canImport(AppKit)
    import AppKit
    import Testing
    import Weave
    @testable import AppKitAdapter
    @testable import WeaveAdapters

    @Suite("RenderCoordinatorLayoutTests")
    struct RenderCoordinatorLayoutTests {
        @Test
        @MainActor
        func layoutPassExecutesViaWorkerAndCoalescesDuplicateRequests() async {
            let node = Node()
            node.style = LayoutStyle(width: .points(120), height: .points(80))
            let coordinator = RenderCoordinator()
            coordinator.mount(root: node)

            let bounds = LayoutFrame(width: 200, height: 200)

            // First invalidation
            coordinator.invalidate(root: node, bounds: bounds, scale: 2.0)
            #expect(coordinator.requestedCount == 1)
            #expect(coordinator.coalescedCount == 0)

            // Immediate duplicate invalidation with identical parameters coalesces
            coordinator.invalidate(root: node, bounds: bounds, scale: 2.0)
            #expect(coordinator.requestedCount == 1)
            #expect(coordinator.coalescedCount == 1)

            // Invalidation with changed bounds cancels previous in-flight request
            let newBounds = LayoutFrame(width: 300, height: 250)
            coordinator.invalidate(root: node, bounds: newBounds, scale: 2.0)
            #expect(coordinator.requestedCount == 2)
            #expect(coordinator.cancelledCount == 1)

            // Wait for worker to complete
            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 1)
            #expect(coordinator.lastCommittedRequest?.bounds == newBounds)
            #expect(coordinator.lastCommittedResult != nil)
            #expect(node.calculatedFrame?.width == 300)
            #expect(node.calculatedFrame?.height == 250)

            // Invalidation after commit with identical request coalesces
            coordinator.invalidate(root: node, bounds: newBounds, scale: 2.0)
            #expect(coordinator.coalescedCount == 2)
            #expect(coordinator.requestedCount == 2)
        }
    }

    @Suite("RenderCoordinatorRevisionTests")
    struct RenderCoordinatorRevisionTests {
        @Test
        @MainActor
        func staleResultFromOutdatedRevisionsIsDiscarded() async {
            let node = Node()
            let engine = LayoutEngine(solver: { input, frame, _, _ in
                // Return an obsolete result with mismatched content revision
                LayoutResult(
                    placements: [LayoutPlacement(identity: input.identity, frame: frame)],
                    treeIdentity: input.identity,
                    environmentRevision: input.environmentRevision,
                    contentRevision: 9999
                )
            })
            let coordinator = RenderCoordinator(layoutEngine: engine)
            coordinator.mount(root: node)

            let bounds = LayoutFrame(width: 100, height: 100)
            coordinator.invalidate(root: node, bounds: bounds, scale: 1.0)

            for _ in 0..<30 where coordinator.staleCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.staleCount > 0)
            #expect(coordinator.committedCount == 0)
            #expect(coordinator.lastCommittedResult == nil)
        }

        @Test
        @MainActor
        func staleResultWithMismatchedTreeIdentityIsDiscarded() async {
            let node = Node()
            let engine = LayoutEngine(solver: { input, frame, _, _ in
                // Return an obsolete result with mismatched tree identity
                LayoutResult(
                    placements: [LayoutPlacement(identity: 999_999, frame: frame)],
                    treeIdentity: 999_999,
                    environmentRevision: input.environmentRevision,
                    contentRevision: input.contentRevision
                )
            })
            let coordinator = RenderCoordinator(layoutEngine: engine)
            coordinator.mount(root: node)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.staleCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.staleCount > 0)
            #expect(coordinator.committedCount == 0)
        }
    }

    @Suite("RenderCoordinatorLifecycleTests")
    struct RenderCoordinatorLifecycleTests {
        @Test
        @MainActor
        func unmountCancelsInFlightWorkAndPreventsCommit() async {
            let node = Node()
            let engine = LayoutEngine(solver: { input, frame, _, _ in
                LayoutResult(
                    placements: [LayoutPlacement(identity: input.identity, frame: frame)],
                    treeIdentity: input.identity,
                    environmentRevision: input.environmentRevision,
                    contentRevision: input.contentRevision
                )
            })
            let coordinator = RenderCoordinator(layoutEngine: engine)
            coordinator.mount(root: node)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )
            #expect(coordinator.requestedCount == 1)

            // Unmount while worker is in flight
            coordinator.unmount()
            #expect(!coordinator.isMounted)
            #expect(coordinator.cancelledCount == 1)

            for _ in 0..<20 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 0)
            #expect(coordinator.lastCommittedResult == nil)
        }

        @Test
        @MainActor
        func suspensionPreventsInvalidationUntilResumed() async {
            let node = Node()
            let coordinator = RenderCoordinator()
            coordinator.mount(root: node)

            coordinator.suspend()
            #expect(coordinator.isSuspended)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )
            #expect(coordinator.requestedCount == 0)

            coordinator.resume()
            #expect(!coordinator.isSuspended)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )
            #expect(coordinator.requestedCount == 1)

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            #expect(coordinator.committedCount == 1)
        }

        @Test
        @MainActor
        func replaceRootResetsCommittedStateAndCancelsActiveWork() async {
            let nodeA = Node()
            let nodeB = Node()
            let coordinator = RenderCoordinator()
            coordinator.mount(root: nodeA)

            coordinator.invalidate(
                root: nodeA,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }
            #expect(coordinator.committedCount == 1)
            #expect(coordinator.lastCommittedRequest != nil)

            coordinator.replaceRoot(newRoot: nodeB)
            #expect(coordinator.lastCommittedRequest == nil)
            #expect(coordinator.lastCommittedResult == nil)

            coordinator.invalidate(
                root: nodeB,
                bounds: LayoutFrame(width: 150, height: 150),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount == 1 {
                await Task.yield()
            }
            #expect(coordinator.committedCount == 2)
            #expect(coordinator.lastCommittedRequest?.bounds.width == 150)
        }

        @Test
        @MainActor
        func disposePermanentlyTerminatesCoordinator() {
            let node = Node()
            let coordinator = RenderCoordinator()
            coordinator.mount(root: node)
            coordinator.dispose()

            #expect(coordinator.isDisposed)
            #expect(!coordinator.isMounted)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )
            #expect(coordinator.requestedCount == 0)
        }

        @Test
        @MainActor
        func appKitWindowHostDoesNotDuplicateCoordinatorOnRemount() {
            let controller = Controller<Node, Never, Never>(node: Node())
            let logicalWindow = Window(rootController: controller)
            let nativeWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled],
                backing: .buffered,
                defer: true
            )
            let host = AppKitWindowHost(window: logicalWindow, nativeWindow: nativeWindow)
            let initialCoordinator = host.coordinator

            #expect(host.mount())
            #expect(host.coordinator === initialCoordinator)
            #expect(host.coordinator.isMounted)

            host.unmount()
            #expect(!host.coordinator.isMounted)

            #expect(host.mount())
            #expect(host.coordinator === initialCoordinator)
            #expect(host.coordinator.isMounted)

            host.unmount()
        }
    }

    @Suite("CoherentCommitTests")
    struct CoherentCommitTests {
        @Test
        @MainActor
        func coherentCommitAppliesNodeFramesAndTriggersCallbacksInOrder() async {
            let parent = Node()
            let child = Node()
            child.style = LayoutStyle(width: .points(50), height: .points(50))
            parent.addSubnode(child)

            let coordinator = RenderCoordinator()
            coordinator.mount(root: parent)

            var geometryApplied = false
            var postCommitFired = false
            var observedGeneration: UInt64 = 0

            coordinator.onCommitGeometry = { result, request in
                geometryApplied = true
                observedGeneration = request.generation
                #expect(!result.placements.isEmpty)
            }

            coordinator.onPostCommit = { request in
                postCommitFired = true
                #expect(geometryApplied)
                #expect(request.generation == observedGeneration)
            }

            coordinator.invalidate(
                root: parent,
                bounds: LayoutFrame(width: 200, height: 200),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 1)
            #expect(geometryApplied)
            #expect(postCommitFired)
            #expect(parent.calculatedFrame?.width == 200)
            #expect(parent.calculatedFrame?.height == 200)
        }

        @Test
        @MainActor
        func reentrantInvalidationInsidePostCommitCreatesNextGeneration() async {
            let node = Node()
            let coordinator = RenderCoordinator()
            coordinator.mount(root: node)

            var postCommitInvocations = 0

            coordinator.onPostCommit = { request in
                postCommitInvocations += 1
                if postCommitInvocations == 1 {
                    // Reentrant invalidation with different bounds
                    coordinator.invalidate(
                        root: node,
                        bounds: LayoutFrame(width: 300, height: 300),
                        scale: 1.0
                    )
                }
            }

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 200, height: 200),
                scale: 1.0
            )

            for _ in 0..<30 where coordinator.committedCount < 2 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 2)
            #expect(postCommitInvocations == 2)
            #expect(coordinator.lastCommittedRequest?.bounds.width == 300)
            #expect(node.calculatedFrame?.width == 300)
        }
    }

    @Suite("DirectionAndScaleTests")
    struct DirectionAndScaleTests {
        @Test
        @MainActor
        func directionAndScaleAreRecordedInHostRenderRequest() async {
            let scope = EnvironmentScope()
            scope.set(LayoutDirectionKey.self, .rightToLeft)
            let node = Node(environment: scope)

            let coordinator = RenderCoordinator()
            coordinator.mount(root: node)

            coordinator.invalidate(
                root: node,
                bounds: LayoutFrame(width: 250, height: 180),
                scale: 3.0
            )

            #expect(coordinator.currentRequest?.direction == .rightToLeft)
            #expect(coordinator.currentRequest?.scale == 3.0)
            #expect(coordinator.currentRequest?.bounds.width == 250)
            #expect(coordinator.currentRequest?.bounds.height == 180)

            for _ in 0..<30 where coordinator.committedCount == 0 {
                await Task.yield()
            }

            #expect(coordinator.committedCount == 1)
            #expect(coordinator.lastCommittedRequest?.direction == .rightToLeft)
            #expect(coordinator.lastCommittedRequest?.scale == 3.0)
        }
    }
#endif
