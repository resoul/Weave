import Foundation

/// Typed input normalized from touch, mouse, keyboard, remote and accessibility activation.
/// Ownership: the input is an immutable snapshot. Isolation: MainActor when handled. Errors: unsupported paths are ignored. Cancellation: cancelled and capture-loss inputs reset interaction state.
public enum ControlInput: Sendable, Hashable {
    case pointerDown
    case pointerUp(inside: Bool)
    case pressSelect
    case accessibilityActivate
    case cancelled
    case captureLost
}

/// Presentation phase consumed by control styles.
/// Ownership: the value is copied by the control. Isolation: none. Errors: none. Cancellation: terminal interaction phases return to idle or disabled.
public enum ControlPhase: Sendable, Hashable {
    case idle
    case hovered
    case pressed
    case focused
    case disabled
    case loading
}

/// Typed activation event emitted by a ButtonNode.
/// Ownership: the event is copied into the bounded action pipe. Isolation: MainActor delivery. Errors: overflow is reported by the pipe. Cancellation: cancelled interactions emit no tap.
public enum ButtonEvent: Sendable, Hashable {
    case tap
}

/// Semantic action role for a button.
/// Ownership: the value is copied by configuration. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ButtonRole: Sendable, Hashable {
    case normal
    case primary
    case destructive
    case cancel
}

/// Immutable configuration passed to a button presentation style.
/// Ownership: strings and environment snapshot are copied. Isolation: none. Errors: none. Cancellation: style evaluation has no retained work.
public struct ButtonConfiguration: Sendable {
    public let title: String
    public let phase: ControlPhase
    public let role: ButtonRole
    public let environment: EnvironmentSnapshot

    /// Creates a presentation configuration.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: no work starts.
    public init(
        title: String,
        phase: ControlPhase,
        role: ButtonRole,
        environment: EnvironmentSnapshot
    ) {
        self.title = title
        self.phase = phase
        self.role = role
        self.environment = environment
    }
}

/// Protocol for nodes that expose typed interaction events without constraining Node inheritance.
/// Ownership: conformers own their bounded event pipe. Isolation: MainActor. Errors: event overflow is reported by the pipe. Cancellation: disposal terminates interaction state.
@MainActor
public protocol InteractiveNode: AnyObject {
    associatedtype Interaction: Sendable
    var events: ActionPipe<Interaction> { get }
}

/// Default typed event emission for an interactive node.
/// Ownership: the action is copied into the pipe. Isolation: MainActor. Errors: overflow is returned. Cancellation: disposed controls reject emission through their own state.
extension InteractiveNode {
    /// Emits one typed interaction event.
    /// Ownership: the action is copied into the bounded pipe. Isolation: MainActor. Errors: overflow is returned. Cancellation: disposed controls reject emission through their own state.
    @discardableResult
    public func emit(_ action: Interaction) -> AsyncStream<Interaction>.Continuation.YieldResult {
        events.send(action)
    }
}

/// Type-erased interface for a node that accepts platform-neutral control input.
///
/// Platform adapters hit-test a raw touch/pointer against the node tree and get back a
/// concrete `Node` whose generic `Interaction` type they cannot know; this lets them dispatch
/// `ControlInput` to whichever `ControlNode<_>` ancestor they find without that generic.
/// Ownership: conformers own their own interaction state. Isolation: MainActor. Errors: none.
/// Cancellation: not applicable.
@MainActor
public protocol ControlInputTarget: AnyObject {
    @discardableResult
    func handle(_ input: ControlInput) -> Bool
}

/// Reusable behavior layer for interactive controls.
/// Ownership: the control owns its event pipe and interaction state. Isolation: MainActor. Errors: disabled/loading controls reject activation. Cancellation: cancel, capture loss and disposal clear pressed state and pending activation.
@MainActor
open class ControlNode<Interaction: Sendable>: Node, InteractiveNode, ControlInputTarget {
    public let events: ActionPipe<Interaction>
    public private(set) var phase: ControlPhase = .idle
    public var isEnabled: Bool = true {
        didSet {
            if !isEnabled { isPressed = false }
            updatePhase()
        }
    }
    public var isLoading: Bool = false {
        didSet {
            if isLoading { isPressed = false }
            updatePhase()
        }
    }

    private var isFocused = false
    private var isPressed = false
    private let activation: @MainActor @Sendable () -> Interaction

    /// Creates a control with a typed activation event factory.
    /// Ownership: the control retains its bounded pipe and factory. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        activation: @escaping @MainActor @Sendable () -> Interaction,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.activation = activation
        events = ActionPipe()
        super.init(style: style, environment: environment)
    }

    /// Handles normalized input from any platform adapter.
    /// Ownership: input is borrowed for the synchronous call. Isolation: MainActor. Errors: invalid or blocked input is ignored. Cancellation: cancelled/capture-loss/up-outside never activates.
    @discardableResult
    public func handle(_ input: ControlInput) -> Bool {
        guard isEnabled, !isLoading else {
            if input == .cancelled || input == .captureLost { resetInteraction() }
            return false
        }
        switch input {
        case .pointerDown:
            guard !isPressed else { return false }
            isPressed = true
            updatePhase()
            return false
        case let .pointerUp(inside):
            guard isPressed else { return false }
            isPressed = false
            updatePhase()
            return inside ? activate() : false
        case .pressSelect, .accessibilityActivate:
            return activate()
        case .cancelled, .captureLost:
            resetInteraction()
            return false
        }
    }

    /// Sets directional/accessibility focus presentation without changing activation behavior.
    /// Ownership: focus state remains control-owned. Isolation: MainActor. Errors: none. Cancellation: disposal resets focus.
    public func setFocused(_ focused: Bool) {
        isFocused = focused
        updatePhase()
    }

    /// Clears pressed/focus state after capture loss or scope cancellation.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: pending interaction is discarded.
    public func resetInteraction() {
        isPressed = false
        isFocused = false
        updatePhase()
    }

    /// Emits one activation event when the control is eligible.
    /// Ownership: one event is copied into the pipe. Isolation: MainActor. Errors: blocked controls return false. Cancellation: no event is emitted after cancellation/disposal.
    @discardableResult
    public func activate() -> Bool {
        guard isEnabled, !isLoading, lifecycleState != .disposed else { return false }
        let action = activation()
        _ = emit(action)
        return true
    }

    /// Current style configuration for a concrete presentation layer.
    /// Ownership: the returned snapshot is owned by the caller. Isolation: MainActor. Errors: none. Cancellation: no work is retained.
    public func configuration(title: String, role: ButtonRole) -> ButtonConfiguration {
        ButtonConfiguration(
            title: title, phase: phase, role: role, environment: environmentSnapshot)
    }

    private func updatePhase() {
        if !isEnabled {
            phase = .disabled
        } else if isLoading {
            phase = .loading
        } else if isPressed {
            phase = .pressed
        } else if isFocused {
            phase = .focused
        } else {
            phase = .idle
        }
        updateSemantics()
        setNeedsDisplay()
        setNeedsAccessibilityUpdate()
    }

    /// Hook for concrete controls to keep semantic state aligned with interaction state.
    /// Ownership: no value escapes. Isolation: MainActor. Errors: none. Cancellation: no work is retained.
    open func updateSemantics() {}

    open override func dispose() {
        resetInteraction()
        super.dispose()
    }
}

/// Button control with default button semantics and a single typed tap action.
/// Ownership: the button owns title/role and its ControlNode event pipe. Isolation: MainActor. Errors: blocked activation is ignored. Cancellation: disposal and capture loss clear pressed state.
@MainActor
public final class ButtonNode: ControlNode<ButtonEvent> {
    public var title: String { didSet { updateAccessibility() } }
    public var role: ButtonRole { didSet { updateAccessibility() } }

    /// Creates a button with default button role and accessibility semantics.
    /// Ownership: the button owns copied title and role. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        title: String,
        role: ButtonRole = .normal,
        style: LayoutStyle = LayoutStyle(),
        environment: EnvironmentScope? = nil
    ) {
        self.title = title
        self.role = role
        super.init(activation: { .tap }, style: style, environment: environment)
        updateAccessibility()
    }

    /// Returns presentation configuration for the current control phase.
    /// Ownership: the returned snapshot is owned by the caller. Isolation: MainActor. Errors: none. Cancellation: none.
    public var buttonConfiguration: ButtonConfiguration {
        configuration(title: title, role: role)
    }

    public override func updateSemantics() { updateAccessibility() }

    private func updateAccessibility() {
        accessibility = AccessibilityProperties(
            isElement: true,
            label: title,
            traits: [.button],
            role: .button,
            actions: [.activate],
            state: AccessibilityState(
                isEnabled: isEnabled && !isLoading,
                value: isLoading ? "Loading" : nil
            )
        )
    }
}
