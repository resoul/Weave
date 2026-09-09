public import Flux

/// Transition state for a container operation.
/// Ownership: immutable value. Isolation: MainActor when read by a container. Errors: none.
/// Cancellation: cancelled means no second active screen was committed.
@MainActor
public enum NavigationTransitionState: Sendable, Hashable {
    case idle, pushing, popping, cancelled
}

/// Sendable observable identity snapshot of one navigation stack.
/// Ownership: the snapshot owns its IDs. Isolation: none. Errors: none. Cancellation: not applicable.
public struct NavigationStackSnapshot: Sendable, Hashable {
    public let controllerIDs: [ObjectIdentifier]

    /// Creates a stack identity snapshot.
    /// Ownership: IDs are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(controllerIDs: [ObjectIdentifier]) { self.controllerIDs = controllerIDs }
}

/// MainActor-owned base for platform-neutral containers.
/// Ownership: the container owns its root Node and child controller references. Isolation: MainActor.
/// Errors: invalid child operations are ignored. Cancellation: dispose terminates all children.
@MainActor
open class ContainerController: AnyController {
    public let containerNode: Node
    public private(set) var childControllers: [any AnyController] = []
    public private(set) var isDisposed = false

    /// Creates a container with a logical root node.
    /// Ownership: the container takes ownership of the node. Isolation: MainActor. Errors: none.
    /// Cancellation: no lifecycle work starts during initialization.
    public init(node: Node = Node()) { containerNode = node }

    public var anyNode: Node { containerNode }

    /// Connects an embedded container. Ownership: child scopes remain container-owned. Isolation: MainActor. Errors: disposed returns false. Cancellation: none until disposal.
    public func connectForContainer() -> Bool { !isDisposed }

    /// Activates a container when embedded by another container.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: container policy applies.
    public func activateForContainer() -> Bool { !isDisposed }

    /// Deactivates a container when embedded by another container.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: invalid state returns false.
    /// Cancellation: container policy applies.
    public func deactivateForContainer() -> Bool { !isDisposed }

    /// Adds an owned child reference once.
    /// Ownership: the container retains the child. Isolation: MainActor. Errors: duplicates are ignored.
    /// Cancellation: disposal releases the child.
    public func retainChild(_ controller: any AnyController) {
        guard !childControllers.contains(where: { $0 === controller }) else { return }
        childControllers.append(controller)
    }

    fileprivate func releaseChild(_ controller: any AnyController) {
        childControllers.removeAll { $0 === controller }
    }

    /// Disposes all child controllers and the container node exactly once.
    /// Ownership: all owned references are released. Isolation: MainActor. Errors: none.
    /// Cancellation: child lifecycles and bindings are terminated.
    open func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        childControllers.forEach { $0.dispose() }
        childControllers.removeAll()
        containerNode.dispose()
    }
}

/// Platform-neutral navigation stack with deterministic synchronous transition policy.
/// Ownership: the controller owns all pushed child controllers. Isolation: MainActor. Errors: empty
/// pop returns nil; reentrant operations during a transition are rejected. Cancellation: cancelled
/// transitions restore the previous active screen and never commit two active children.
@MainActor
public final class NavigationController<R: Route>: ContainerController {
    private final class WeakNode {
        weak var value: Node?
        init(_ value: Node) { self.value = value }
    }
    private var stackStorage: [any AnyController] = []
    private let stackPipe = Pipe<NavigationStackSnapshot>(bufferingPolicy: .bufferingNewest(32))
    private var savedFocus: [ObjectIdentifier: WeakNode] = [:]
    private var transitionGeneration: UInt64 = 0
    private let focusTree: FocusTree?

    public private(set) var transitionState: NavigationTransitionState = .idle

    /// Creates an empty navigation stack.
    /// Ownership: the container owns its root node. Isolation: MainActor. Errors: none.
    /// Cancellation: no transition starts during initialization.
    public init(node: Node = Node(), focusTree: FocusTree? = nil) {
        self.focusTree = focusTree
        super.init(node: node)
    }

    /// Current child stack in presentation order.
    public var stack: [any AnyController] { stackStorage }

    /// Bounded stream of committed stack identity snapshots.
    public var stackChanges: Flux<NavigationStackSnapshot> { stackPipe.flux }

    /// Pushes a controller after deactivating the previous top screen.
    /// Ownership: the navigation controller retains the child. Isolation: MainActor. Errors: reentrant,
    /// disposed or duplicate pushes return false. Cancellation: failed transition restores previous top.
    @discardableResult
    public func push<N: Node, A: Action>(
        _ controller: Controller<N, A, R>,
        animated: Bool = true
    ) -> Bool {
        pushAny(controller, animated: animated)
    }

    /// Pushes a type-erased controller after deactivating the previous top screen.
    /// Ownership: navigation retains the child. Isolation: MainActor. Errors: disposed, duplicate,
    /// or failed activation returns false. Cancellation: failed transition restores previous top.
    @discardableResult
    public func push(
        _ controller: any AnyController,
        animated: Bool = true
    ) -> Bool {
        pushAny(controller, animated: animated)
    }

    private func pushAny(_ controller: any AnyController, animated: Bool) -> Bool {
        _ = animated
        guard !isDisposed, !controller.isDisposed,
            !stackStorage.contains(where: { $0 === controller })
        else { return false }
        guard begin(.pushing) else { return false }
        let previous = stackStorage.last
        saveFocus(for: previous)
        if let previous {
            _ = deactivate(previous)
            previous.anyNode.removeFromSupernode()
        }
        guard controller.connectForContainer(), controller.activateForContainer() else {
            _ = activate(previous)
            if let previous { containerNode.addSubnode(previous.anyNode) }
            end(.cancelled)
            return false
        }
        stackStorage.append(controller)
        retainChild(controller)
        containerNode.addSubnode(controller.anyNode)
        publish()
        end(.idle)
        return true
    }

    /// Pops the top controller and activates the previous screen.
    /// Ownership: the popped controller is disposed and released. Isolation: MainActor. Errors: empty
    /// stack or reentrant operations return nil. Cancellation: failed activation keeps the old stack.
    @discardableResult
    public func pop(animated: Bool = true) -> (any AnyController)? {
        _ = animated
        guard begin(.popping), let popped = stackStorage.last else {
            transitionState = .idle
            return nil
        }
        let previous = stackStorage.dropLast().last
        stackStorage.removeLast()
        _ = deactivate(popped)
        popped.anyNode.removeFromSupernode()
        if let previous, !activate(previous) {
            stackStorage.append(popped)
            _ = activate(popped)
            containerNode.addSubnode(popped.anyNode)
            publish()
            end(.cancelled)
            return nil
        }
        if let previous { containerNode.addSubnode(previous.anyNode) }
        publish()
        releaseChild(popped)
        popped.dispose()
        restoreFocus(for: previous)
        end(.idle)
        return popped
    }

    /// Pops to the root controller, disposing every removed child.
    /// Ownership: removed controllers are disposed. Isolation: MainActor. Errors: empty/root-only stacks return zero.
    /// Cancellation: an interrupted operation leaves one active root.
    @discardableResult
    public func popToRoot(animated: Bool = true) -> Int {
        _ = animated
        var count = 0
        while stackStorage.count > 1 {
            guard pop(animated: animated) != nil else { break }
            count += 1
        }
        return count
    }

    /// Presents a controller using the same stack transition path.
    /// Ownership: the presented controller is retained by the stack. Isolation: MainActor. Errors: push policy applies.
    /// Cancellation: failed presentation leaves the previous screen active.
    @discardableResult
    public func present<N: Node, A: Action>(
        _ controller: Controller<N, A, R>,
        animated: Bool = true
    ) -> Bool {
        push(controller, animated: animated)
    }

    /// Dismisses the presented top controller exactly once.
    /// Ownership: dismissed controller is disposed. Isolation: MainActor. Errors: empty stack returns nil.
    /// Cancellation: failed pop leaves the active screen unchanged.
    @discardableResult
    public func dismiss(animated: Bool = true) -> (any AnyController)? {
        pop(animated: animated)
    }

    /// Cancels an in-flight transition generation and restores idle policy.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: stale generations are ignored.
    /// Cancellation: no transition commits after cancellation.
    public func cancelTransition() {
        transitionGeneration &+= 1
        transitionState = .cancelled
        transitionState = .idle
    }

    private func begin(_ state: NavigationTransitionState) -> Bool {
        guard !isDisposed, transitionState == .idle else { return false }
        transitionGeneration &+= 1
        transitionState = state
        return true
    }

    private func end(_ state: NavigationTransitionState) {
        transitionState = state
        if state == .cancelled { transitionState = .idle }
    }

    private func activate(_ controller: (any AnyController)?) -> Bool {
        guard let controller else { return true }
        return controller.activateForContainer()
    }

    private func deactivate(_ controller: any AnyController) -> Bool {
        return controller.deactivateForContainer()
    }

    private func saveFocus(for controller: (any AnyController)?) {
        guard let controller, let focused = focusTree?.focusedNode else { return }
        guard isDescendantOrSame(focused, of: controller.anyNode) else { return }
        savedFocus[ObjectIdentifier(controller)] = WeakNode(focused)
    }

    private func restoreFocus(for controller: (any AnyController)?) {
        guard let controller,
            let node = savedFocus[ObjectIdentifier(controller)]?.value
        else { return }
        _ = focusTree?.moveFocus(to: node)
    }

    private func isDescendantOrSame(_ node: Node, of root: Node) -> Bool {
        var current: Node? = node
        while let value = current {
            if value === root { return true }
            current = value.supernode
        }
        return false
    }

    private func publish() {
        let ids = stackStorage.map { ObjectIdentifier($0) }
        let snapshot = NavigationStackSnapshot(controllerIDs: ids)
        _ = stackPipe.sendObservingOverflow(snapshot)
    }
}

/// Stable presentation mode for a split container.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SplitStyle: Sendable, Hashable {
    case sideBySide
    case primaryOverlay
    case collapsed
}

/// MainActor-owned tab container with one active child at a time.
/// Hidden children remain retained and preserve lifecycle state for later restoration.
/// Ownership: the container owns its tabs and root node. Isolation: MainActor. Errors: invalid
/// selection is rejected. Cancellation: disposal terminates child lifecycles.
@MainActor
public final class TabController: ContainerController {
    /// Actor-backed replaying selected index. Ownership: Flux actor owns value. Isolation: actor. Errors: none. Cancellation: subscription cancellation.
    public let selectedIndex: CurrentValueDistinct<Int>
    /// Synchronous MainActor selection used by container transitions. Ownership: container-owned value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var selectedIndexValue: Int
    private var tabsStorage: [any AnyController]
    private var savedFocus: [ObjectIdentifier: WeakNode] = [:]
    private let focusTree: FocusTree?

    private final class WeakNode {
        weak var value: Node?
        init(_ value: Node) { self.value = value }
    }

    /// Creates tabs and retains each child. Ownership: container owns children. Isolation: MainActor. Errors: out-of-range initial selection clamps. Cancellation: no effects start.
    public init(
        tabs: [any AnyController] = [],
        selectedIndex: Int = 0,
        node: Node = Node(),
        focusTree: FocusTree? = nil
    ) {
        self.tabsStorage = tabs
        let valid = tabs.isEmpty ? 0 : min(max(0, selectedIndex), tabs.count - 1)
        self.selectedIndexValue = valid
        self.selectedIndex = CurrentValueDistinct(valid)
        self.focusTree = focusTree
        super.init(node: node)
        tabs.forEach { retainChild($0) }
    }

    /// Current tabs in stable identity order. Setting tabs disposes removed children and selects a valid fallback.
    public var tabs: [any AnyController] {
        get { tabsStorage }
        set { replaceTabs(with: newValue) }
    }

    /// Replaces tab composition while preserving retained children that remain present.
    /// Replaces tab composition. Ownership: removed children are disposed; retained identities remain owned. Isolation: MainActor. Errors: duplicate identities are ignored. Cancellation: removed work is cancelled by disposal.
    public func replaceTabs(with tabs: [any AnyController]) {
        guard !isDisposed else { return }
        var unique: [any AnyController] = []
        for tab in tabs where !unique.contains(where: { $0 === tab }) { unique.append(tab) }
        let old = tabsStorage
        let selected = selectedIndexValue
        tabsStorage = unique
        unique.forEach { retainChild($0) }
        old.filter { oldTab in !unique.contains(where: { newTab in oldTab === newTab }) }.forEach {
            $0.dispose()
        }
        childControllers.filter { child in !unique.contains(where: { newTab in child === newTab }) }
            .forEach { releaseChild($0) }
        let fallback = unique.isEmpty ? 0 : min(selected, unique.count - 1)
        if fallback != selectedIndexValue { _ = select(index: fallback) } else { syncActiveChild() }
    }

    /// Selects a tab. Invalid indexes are rejected; selecting the current tab is a no-op.
    @discardableResult
    /// Selects a tab and updates lifecycle/focus. Ownership: no child ownership changes. Isolation: MainActor. Errors: invalid or duplicate selection returns false. Cancellation: failed activation restores the previous child.
    public func select(index: Int) -> Bool {
        guard !isDisposed, tabsStorage.indices.contains(index), index != selectedIndexValue else {
            return false
        }
        let previous = tabsStorage[selectedIndexValue]
        saveFocus(for: previous)
        _ = previous.deactivateForContainer()
        let next = tabsStorage[index]
        guard !next.isDisposed, next.connectForContainer(), next.activateForContainer() else {
            _ = previous.activateForContainer()
            return false
        }
        selectedIndexValue = index
        Task { await selectedIndex.set(index) }
        restoreFocus(for: next)
        return true
    }

    public override func dispose() {
        tabsStorage.removeAll()
        super.dispose()
    }

    private func syncActiveChild() {
        guard let active = tabsStorage[safe: selectedIndexValue] else { return }
        _ = active.connectForContainer()
        _ = active.activateForContainer()
        for (index, tab) in tabsStorage.enumerated() where index != selectedIndexValue {
            _ = tab.deactivateForContainer()
        }
    }

    private func saveFocus(for controller: any AnyController) {
        guard let focused = focusTree?.focusedNode,
            isDescendantOrSame(focused, of: controller.anyNode)
        else { return }
        savedFocus[ObjectIdentifier(controller)] = WeakNode(focused)
    }

    private func restoreFocus(for controller: any AnyController) {
        guard let node = savedFocus[ObjectIdentifier(controller)]?.value else { return }
        _ = focusTree?.moveFocus(to: node)
    }

    private func isDescendantOrSame(_ node: Node, of root: Node) -> Bool {
        var current: Node? = node
        while let value = current { if value === root { return true }; current = value.supernode }
        return false
    }
}

/// MainActor-owned primary/secondary split container. Collapsing only deactivates secondary content.
/// Ownership: the split owns both children and its root node. Isolation: MainActor. Errors: duplicate
/// replacements are ignored. Cancellation: disposal terminates child lifecycles.
@MainActor
public final class SplitController: ContainerController {
    /// Primary child. Ownership: split retains it. Isolation: MainActor. Errors: none. Cancellation: disposal terminates it.
    public private(set) var primary: any AnyController
    /// Secondary child. Ownership: split retains it. Isolation: MainActor. Errors: none. Cancellation: disposal terminates it.
    public private(set) var secondary: any AnyController
    /// Current platform-neutral presentation style. Ownership: copied value. Isolation: MainActor. Errors: none. Cancellation: not applicable.
    public private(set) var style: SplitStyle

    /// Creates a split with two owned children. Ownership: split retains both. Isolation: MainActor. Errors: none. Cancellation: no asynchronous work starts.
    public init(
        primary: any AnyController, secondary: any AnyController, style: SplitStyle = .sideBySide,
        node: Node = Node()
    ) {
        self.primary = primary
        self.secondary = secondary
        self.style = style
        super.init(node: node)
        retainChild(primary); retainChild(secondary)
        apply(style: style)
    }

    /// Replaces primary and disposes the previous child. Ownership: new child is retained. Isolation: MainActor. Errors: duplicate child is ignored. Cancellation: old child disposal cancels work.
    public func setPrimary(_ controller: any AnyController) {
        guard !isDisposed, controller !== secondary, controller !== primary else { return }
        let old = primary; primary = controller; retainChild(controller); releaseChild(old);
        old.dispose(); apply(style: style)
    }

    /// Replaces secondary and disposes the previous child. Ownership: new child is retained. Isolation: MainActor. Errors: duplicate child is ignored. Cancellation: old child disposal cancels work.
    public func setSecondary(_ controller: any AnyController) {
        guard !isDisposed, controller !== primary, controller !== secondary else { return }
        let old = secondary; secondary = controller; retainChild(controller); releaseChild(old);
        old.dispose(); apply(style: style)
    }

    /// Applies a style; collapse deactivates but retains secondary state. Ownership: children remain split-owned. Isolation: MainActor. Errors: disposed split ignores update. Cancellation: deactivation follows child policy.
    public func apply(style: SplitStyle) {
        guard !isDisposed else { return }
        self.style = style
        _ = primary.connectForContainer()
        _ = primary.activateForContainer()
        _ = secondary.connectForContainer()
        if style == .collapsed {
            _ = secondary.deactivateForContainer()
        } else {
            _ = secondary.activateForContainer()
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
