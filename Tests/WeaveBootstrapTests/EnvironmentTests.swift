import Testing
import Weave

private enum ThemeKey: EnvironmentKey {
    static let defaultValue = "light"
    static let invalidation: EnvironmentInvalidation = .display
}

private enum LayoutScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
    static let invalidation: EnvironmentInvalidation = .layoutAndDisplay
}

private enum AccessibilityKey: EnvironmentKey {
    static let defaultValue = false
    static let invalidation: EnvironmentInvalidation = .accessibility
}

@Test @MainActor
func test_environment_childOverride_reparent_preservesOverride() {
    let root = EnvironmentScope()
    let child = EnvironmentScope(parent: root)
    root.set(ThemeKey.self, "dark")
    child.set(ThemeKey.self, "highContrast")

    #expect(child.snapshot.values[ThemeKey.self] == "highContrast")
    child.remove(ThemeKey.self)
    #expect(child.snapshot.values[ThemeKey.self] == "dark")
    child.set(ThemeKey.self, "highContrast")
    child.reparent(to: nil)
    #expect(child.snapshot.values[ThemeKey.self] == "highContrast")
    #expect(child.snapshot.revision >= root.snapshot.revision)
}

@Test @MainActor
func test_environment_resourceConfiguration_clampsUnsafeInputs() {
    let scope = EnvironmentScope()
    scope.set(
        ResourceConfigurationKey.self,
        EnvironmentResourceConfiguration(
            memoryBudgetBytes: -1,
            decodeConcurrency: 0,
            prefetchEnabled: false
        )
    )

    let configuration = scope.snapshot.values[ResourceConfigurationKey.self]
    #expect(configuration.memoryBudgetBytes == 0)
    #expect(configuration.decodeConcurrency == 1)
    #expect(!configuration.prefetchEnabled)
}

@Test @MainActor
func test_environment_snapshot_isFrozen_afterScopeMutation() {
    let scope = EnvironmentScope()
    scope.set(LayoutScaleKey.self, 2.0)
    let captured = scope.snapshot
    scope.set(LayoutScaleKey.self, 3.0)

    #expect(captured.values[LayoutScaleKey.self] == 2.0)
    #expect(scope.snapshot.values[LayoutScaleKey.self] == 3.0)
    #expect(scope.snapshot.revision > captured.revision)
}

@Test @MainActor
func test_environment_dependencies_ignoreUnrelatedKey() {
    let scope = EnvironmentScope()
    var dependencies = EnvironmentDependencies()
    let snapshot = scope.snapshot
    _ = snapshot.read(ThemeKey.self, recording: &dependencies)

    let unrelated = scope.set(AccessibilityKey.self, true)
    let relevant = scope.set(ThemeKey.self, "dark")

    #expect(!unrelated.affects(dependencies))
    #expect(relevant.affects(dependencies))
    #expect(unrelated.invalidation == .accessibility)
}

@Test @MainActor
func test_environment_changeBuffer_coalescesNewestState() {
    let scope = EnvironmentScope()
    let buffer = EnvironmentChangeBuffer()
    let first = scope.set(ThemeKey.self, "dark")
    let second = scope.set(ThemeKey.self, "highContrast")
    buffer.push(first)
    buffer.push(second)

    #expect(buffer.popLatest()?.revision == second.revision)
    #expect(buffer.popLatest() == nil)
}

@Test @MainActor
func test_safeAreaInsets_normalize_andUseLayoutAndDisplayInvalidation() {
    let insets = SafeAreaInsets(top: .infinity, leading: -2, bottom: 12, trailing: .nan)
    #expect(insets == SafeAreaInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
    #expect(SafeAreaInsetsKey.defaultValue == SafeAreaInsets())
    #expect(SafeAreaInsetsKey.invalidation == .layoutAndDisplay)
}

@Test @MainActor
func test_safeAreaEnvironment_isInherited_andRootPaddingDoesNotGrowFrame() {
    let scope = EnvironmentScope()
    scope.set(
        SafeAreaInsetsKey.self,
        SafeAreaInsets(top: 20, leading: 10, bottom: 30, trailing: 14)
    )
    let root = Node(environment: scope)
        .style {
            $0.flexDirection = .column
            $0.width = .fraction(1)
        }
        .addSubnodes {
            Node().frame(width: 40, height: 10)
        }

    let snapshot = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(200), height: .exact(100))
    )
    #expect(snapshot.style.padding.top == 20)
    #expect(snapshot.style.padding.leading == 10)
    #expect(snapshot.style.padding.bottom == 30)
    #expect(snapshot.style.padding.trailing == 14)

    let result = FlexSolver.layoutContainer(
        input: snapshot,
        frame: LayoutFrame(width: 200, height: 100)
    )
    #expect(result.placement(for: root.id)?.frame.width == 200)
    #expect(result.placement(for: root.id)?.frame.height == 100)
}

@Test @MainActor
func test_ignoresSafeArea_selectivelyRemovesExplicitBoundaryInsets() {
    let scope = EnvironmentScope()
    scope.set(SafeAreaInsetsKey.self, SafeAreaInsets(top: 20, bottom: 30))
    let root = Node(environment: scope)
        .style { $0.width = .fraction(1) }
        .ignoresSafeArea(edges: [.top, .bottom])
    let snapshot = root.makeLayoutInputSnapshot(
        constraint: SizeConstraint(width: .exact(200), height: .exact(100))
    )

    #expect(snapshot.style.padding.top == 0)
    #expect(snapshot.style.padding.bottom == 0)
}
