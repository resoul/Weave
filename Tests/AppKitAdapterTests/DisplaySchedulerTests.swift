#if canImport(AppKit)
    import AppKit
    import Testing
    import Weave
    @testable import AppKitAdapter
    @testable import WeaveAdapters

    @Suite("DisplaySchedulerTests")
    struct DisplaySchedulerTests {
        @Test
        @MainActor
        func schedulerEnforcesMaxConcurrency() async {
            let scheduler = DisplayScheduler(maxConcurrency: 2, maxQueueDepth: 10)
            var maxObservedInFlight = 0

            for i: UInt64 in 1...6 {
                let request = DisplayRequest(
                    nodeID: i,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 100, height: 100),
                    scale: 1.0,
                    priority: .visible
                )
                scheduler.schedule(
                    request: request,
                    render: {
                        for _ in 0..<5 {
                            await Task.yield()
                        }
                        return DisplayArtifact(
                            nodeID: request.nodeID,
                            generation: 1,
                            geometryGeneration: 1,
                            contentRevision: 1,
                            payload: .empty,
                            size: CGSize(width: 100, height: 100),
                            scale: 1.0
                        )
                    },
                    completion: { _ in }
                )
                maxObservedInFlight = max(maxObservedInFlight, scheduler.inFlightCount)
            }

            #expect(maxObservedInFlight <= 2)
            await scheduler.quiescence()
            #expect(scheduler.completedCount == 6)
            #expect(scheduler.inFlightCount == 0)
            #expect(scheduler.queueDepth == 0)
        }

        @Test
        @MainActor
        func schedulerPrioritizesVisibleOverBackground() async {
            let scheduler = DisplayScheduler(maxConcurrency: 1, maxQueueDepth: 10)
            var executionOrder: [UInt64] = []

            // Submit 1 slow task that blocks the 1-worker slot
            let blockerRequest = DisplayRequest(
                nodeID: 100,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 50, height: 50),
                scale: 1.0,
                priority: .visible
            )
            scheduler.schedule(
                request: blockerRequest,
                render: {
                    for _ in 0..<5 {
                        await Task.yield()
                    }
                    return DisplayArtifact(
                        nodeID: 100,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 50, height: 50),
                        scale: 1.0
                    )
                },
                completion: { _ in executionOrder.append(100) }
            )

            // Queue background task first
            let bgRequest = DisplayRequest(
                nodeID: 1,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 50, height: 50),
                scale: 1.0,
                priority: .background
            )
            scheduler.schedule(
                request: bgRequest,
                render: {
                    DisplayArtifact(
                        nodeID: 1,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 50, height: 50),
                        scale: 1.0
                    )
                },
                completion: { _ in executionOrder.append(1) }
            )

            // Queue visible task second
            let visibleRequest = DisplayRequest(
                nodeID: 2,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 50, height: 50),
                scale: 1.0,
                priority: .visible
            )
            scheduler.schedule(
                request: visibleRequest,
                render: {
                    DisplayArtifact(
                        nodeID: 2,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 50, height: 50),
                        scale: 1.0
                    )
                },
                completion: { _ in executionOrder.append(2) }
            )

            await scheduler.quiescence()

            // Block task 100 finished first, then visible task 2 before background task 1
            #expect(executionOrder == [100, 2, 1])
        }

        @Test
        @MainActor
        func schedulerDropsLowerPriorityOnQueueOverflow() async {
            let scheduler = DisplayScheduler(maxConcurrency: 1, maxQueueDepth: 2)

            // Fill slot with 1 blocker
            let blocker = DisplayRequest(
                nodeID: 99,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 10, height: 10),
                scale: 1.0,
                priority: .visible
            )
            scheduler.schedule(
                request: blocker,
                render: {
                    for _ in 0..<10 {
                        await Task.yield()
                    }
                    return DisplayArtifact(
                        nodeID: 99,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 10, height: 10),
                        scale: 1.0
                    )
                },
                completion: { _ in }
            )

            // Fill queue to capacity (2 items)
            for i: UInt64 in 1...2 {
                let req = DisplayRequest(
                    nodeID: i,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 10, height: 10),
                    scale: 1.0,
                    priority: .background
                )
                scheduler.schedule(
                    request: req,
                    render: {
                        DisplayArtifact(
                            nodeID: req.nodeID,
                            generation: 1,
                            geometryGeneration: 1,
                            contentRevision: 1,
                            payload: .empty,
                            size: CGSize(width: 10, height: 10),
                            scale: 1.0
                        )
                    },
                    completion: { _ in }
                )
            }
            #expect(scheduler.queueDepth == 2)

            // Overfill with a higher priority visible request
            let highPri = DisplayRequest(
                nodeID: 10,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 10, height: 10),
                scale: 1.0,
                priority: .visible
            )
            scheduler.schedule(
                request: highPri,
                render: {
                    DisplayArtifact(
                        nodeID: 10,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 10, height: 10),
                        scale: 1.0
                    )
                },
                completion: { _ in }
            )

            #expect(scheduler.overflowCount == 1)
            await scheduler.quiescence()
        }

        @Test
        @MainActor
        func schedulerCancelsTargetedNodeJob() async {
            let scheduler = DisplayScheduler(maxConcurrency: 1, maxQueueDepth: 5)
            var node2Completed = false

            // Blocker
            scheduler.schedule(
                request: DisplayRequest(
                    nodeID: 1,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 10, height: 10),
                    scale: 1.0
                ),
                render: {
                    for _ in 0..<5 {
                        await Task.yield()
                    }
                    return DisplayArtifact(
                        nodeID: 1,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 10, height: 10),
                        scale: 1.0
                    )
                },
                completion: { _ in }
            )

            // Node 2 in queue
            scheduler.schedule(
                request: DisplayRequest(
                    nodeID: 2,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 10, height: 10),
                    scale: 1.0
                ),
                render: {
                    DisplayArtifact(
                        nodeID: 2,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 10, height: 10),
                        scale: 1.0
                    )
                },
                completion: { result in
                    if case .success = result {
                        node2Completed = true
                    }
                }
            )

            #expect(scheduler.queueDepth == 1)
            scheduler.cancel(nodeID: 2)
            #expect(scheduler.cancelledCount >= 1)
            #expect(scheduler.queueDepth == 0)

            await scheduler.quiescence()
            #expect(!node2Completed)
        }
    }

    @Suite("DisplayGenerationTests")
    struct DisplayGenerationTests {
        @Test
        @MainActor
        func transactionRejectsMismatchedGenerationArtifact() async {
            let scheduler = DisplayScheduler()
            let transaction = DisplayTransaction(
                hostID: 1,
                generation: 5,
                geometryGeneration: 5,
                scheduler: scheduler
            )

            var committedArtifact: DisplayArtifact?
            transaction.onCommitArtifact = { artifact in
                committedArtifact = artifact
            }

            let staleRequest = DisplayRequest(
                nodeID: 10,
                generation: 4,  // Old generation
                geometryGeneration: 5,
                contentRevision: 1,
                bounds: LayoutFrame(width: 50, height: 50),
                scale: 1.0
            )

            transaction.schedule(request: staleRequest) {
                DisplayArtifact(
                    nodeID: 10,
                    generation: 4,
                    geometryGeneration: 5,
                    contentRevision: 1,
                    payload: .empty,
                    size: CGSize(width: 50, height: 50),
                    scale: 1.0
                )
            }

            await transaction.quiescence()

            #expect(committedArtifact == nil)
            #expect(transaction.staleCount == 1)
            #expect(transaction.committedCount == 0)
        }

        @Test
        @MainActor
        func transactionRejectsArtifactWhenNodeDisplayRevisionAdvanced() async {
            let scheduler = DisplayScheduler()
            let node = Node()
            let transaction = DisplayTransaction(
                hostID: 1,
                generation: 1,
                geometryGeneration: 1,
                scheduler: scheduler
            )

            var committed = false
            transaction.onCommitArtifact = { _ in committed = true }
            transaction.nodeRevisionValidator = { nodeID, revision in
                nodeID == node.id && revision == node.displayRevision
            }

            let request = DisplayRequest(
                nodeID: node.id,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: node.displayRevision,
                bounds: LayoutFrame(width: 100, height: 100),
                scale: 1.0
            )

            transaction.schedule(request: request) {
                for _ in 0..<3 {
                    await Task.yield()
                }
                return DisplayArtifact(
                    nodeID: request.nodeID,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: request.contentRevision,
                    payload: .empty,
                    size: CGSize(width: 100, height: 100),
                    scale: 1.0
                )
            }

            // Node display revision advances while worker is in flight
            node.setNeedsDisplay()

            await transaction.quiescence()

            #expect(!committed)
            #expect(transaction.staleCount == 1)
        }
    }

    @Suite("DisplayTransactionTests")
    struct DisplayTransactionTests {
        @Test
        @MainActor
        func progressiveCommitAppliesFastArtifactsImmediately() async {
            let scheduler = DisplayScheduler(maxConcurrency: 2)
            let transaction = DisplayTransaction(
                hostID: 1,
                generation: 1,
                geometryGeneration: 1,
                scheduler: scheduler
            )

            var committedNodeIDs: [UInt64] = []
            transaction.onCommitArtifact = { artifact in
                committedNodeIDs.append(artifact.nodeID)
            }

            // Node 1 is fast, Node 2 is slow
            let fast = DisplayRequest(
                nodeID: 1,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 20, height: 20),
                scale: 1.0
            )
            let slow = DisplayRequest(
                nodeID: 2,
                generation: 1,
                geometryGeneration: 1,
                contentRevision: 1,
                bounds: LayoutFrame(width: 20, height: 20),
                scale: 1.0
            )

            transaction.schedule(request: slow) {
                for _ in 0..<10 {
                    await Task.yield()
                }
                return DisplayArtifact(
                    nodeID: 2,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    payload: .empty,
                    size: CGSize(width: 20, height: 20),
                    scale: 1.0
                )
            }

            transaction.schedule(request: fast) {
                DisplayArtifact(
                    nodeID: 1,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    payload: .empty,
                    size: CGSize(width: 20, height: 20),
                    scale: 1.0
                )
            }

            // Allow fast job to finish
            for _ in 0..<2 {
                await Task.yield()
            }

            #expect(committedNodeIDs.contains(1))

            await transaction.quiescence()
            #expect(transaction.committedCount == 2)
            #expect(Set(committedNodeIDs) == [1, 2])
        }
    }

    @Suite("DisplayResourcePolicyTests")
    struct DisplayResourcePolicyTests {
        @Test
        @MainActor
        func suspensionCancelsActiveWorkersAndPausesScheduling() async {
            let scheduler = DisplayScheduler(maxConcurrency: 1)

            scheduler.schedule(
                request: DisplayRequest(
                    nodeID: 1,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 50, height: 50),
                    scale: 1.0
                ),
                render: {
                    for _ in 0..<10 {
                        await Task.yield()
                    }
                    return DisplayArtifact(
                        nodeID: 1,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 50, height: 50),
                        scale: 1.0
                    )
                },
                completion: { _ in }
            )

            #expect(scheduler.inFlightCount == 1)
            scheduler.suspend()
            #expect(scheduler.isSuspended)
            #expect(scheduler.inFlightCount == 0)

            scheduler.resume()
            #expect(!scheduler.isSuspended)
            await scheduler.quiescence()
        }
    }

    @Suite("MainActorResponsivenessTests")
    struct MainActorResponsivenessTests {
        @Test
        @MainActor
        func heavyRasterWorkerDoesNotBlockMainActorInteractions() async {
            let scheduler = DisplayScheduler(maxConcurrency: 1)
            var mainActorTicks = 0

            scheduler.schedule(
                request: DisplayRequest(
                    nodeID: 50,
                    generation: 1,
                    geometryGeneration: 1,
                    contentRevision: 1,
                    bounds: LayoutFrame(width: 200, height: 200),
                    scale: 2.0
                ),
                render: {
                    // Simulate non-trivial CPU work on worker thread
                    var sum = 0
                    for i in 0..<10_000 {
                        sum &+= i
                    }
                    _ = sum
                    return DisplayArtifact(
                        nodeID: 50,
                        generation: 1,
                        geometryGeneration: 1,
                        contentRevision: 1,
                        payload: .empty,
                        size: CGSize(width: 200, height: 200),
                        scale: 2.0
                    )
                },
                completion: { _ in }
            )

            // MainActor tasks run concurrently while background worker executes
            for _ in 0..<5 {
                mainActorTicks += 1
                await Task.yield()
            }

            #expect(mainActorTicks == 5)
            await scheduler.quiescence()
            #expect(scheduler.completedCount == 1)
        }
    }
#endif
