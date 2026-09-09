/// Framework-neutral haptic intent.
/// Ownership: immutable value. Isolation: none. Errors: unsupported intents are ignored by adapters. Cancellation: not applicable.
public enum HapticFeedback: Sendable, Hashable {
    case selection
    case impact(intensity: Double)
    case notification(NotificationKind)

    /// Notification category for haptic feedback.
    /// Ownership: immutable value. Isolation: none. Errors: unsupported category is ignored. Cancellation: not applicable.
    public enum NotificationKind: Sendable, Hashable { case success, warning, error }
}

/// Framework-neutral sound intent.
/// Ownership: immutable value. Isolation: none. Errors: unsupported sounds are ignored by adapters. Cancellation: not applicable.
public enum SoundFeedback: Sendable, Hashable { case selection, success, warning, error }

/// User preferences that suppress sensory feedback.
/// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct SensoryPreferences: Sendable, Hashable {
    public let hapticsEnabled: Bool
    public let soundsEnabled: Bool

    /// Creates sensory preferences.
    /// Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(hapticsEnabled: Bool = true, soundsEnabled: Bool = true) {
        self.hapticsEnabled = hapticsEnabled
        self.soundsEnabled = soundsEnabled
    }
}

/// MainActor haptic service contract.
/// Ownership: caller owns the intent. Isolation: MainActor. Errors: unsupported capability is a no-op. Cancellation: no asynchronous work is retained.
public protocol HapticsClient: Sendable {
    @MainActor func play(_ feedback: HapticFeedback)
}

/// MainActor sound service contract.
/// Ownership: caller owns the intent. Isolation: MainActor. Errors: unsupported capability is a no-op. Cancellation: no asynchronous work is retained.
public protocol SoundClient: Sendable {
    @MainActor func play(_ feedback: SoundFeedback)
}

/// Safe fallback when a platform has no sensory capability.
/// Ownership: stateless value. Isolation: MainActor method. Errors: none. Cancellation: not applicable.
public struct NoopHapticsClient: HapticsClient, Sendable {
    /// Creates a no-op haptics service.
    /// Ownership: stateless value. Isolation: none. Errors: none. Cancellation: none.
    public init() {}
    /// Ignores unsupported haptic feedback.
    /// Ownership: intent is borrowed. Isolation: MainActor. Errors: none. Cancellation: none.
    public func play(_ feedback: HapticFeedback) {}
}

/// Safe fallback when a platform has no sound capability.
/// Ownership: stateless value. Isolation: MainActor method. Errors: none. Cancellation: not applicable.
public struct NoopSoundClient: SoundClient, Sendable {
    /// Creates a no-op sound service.
    /// Ownership: stateless value. Isolation: none. Errors: none. Cancellation: none.
    public init() {}
    /// Ignores unsupported sound feedback.
    /// Ownership: intent is borrowed. Isolation: MainActor. Errors: none. Cancellation: none.
    public func play(_ feedback: SoundFeedback) {}
}

/// Environment key for sensory preferences.
/// Ownership: key is a stateless type. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SensoryPreferencesKey: EnvironmentKey {
    /// Default sensory preferences.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue = SensoryPreferences()
    /// Preference changes affect presentation only.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let invalidation: EnvironmentInvalidation = .display
}

/// Environment key for the haptic service.
/// Ownership: key is a stateless type. Isolation: none. Errors: none. Cancellation: not applicable.
public enum HapticsClientKey: EnvironmentKey {
    /// No-op fallback service.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue: any HapticsClient = NoopHapticsClient()
    /// Service replacement does not invalidate layout.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let invalidation: EnvironmentInvalidation = .none
}

/// Environment key for the sound service.
/// Ownership: key is a stateless type. Isolation: none. Errors: none. Cancellation: not applicable.
public enum SoundClientKey: EnvironmentKey {
    /// No-op fallback service.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let defaultValue: any SoundClient = NoopSoundClient()
    /// Service replacement does not invalidate layout.
    /// Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
    public static let invalidation: EnvironmentInvalidation = .none
}

/// MainActor dispatcher that deduplicates one logical feedback action.
/// Ownership: dispatcher owns handled action identities. Isolation: MainActor. Errors: unsupported services are no-ops. Cancellation: no asynchronous work is retained.
@MainActor
public final class FeedbackDispatcher {
    private var handled: Set<String> = []

    /// Creates an empty dispatcher.
    /// Ownership: dispatcher owns its identity set. Isolation: MainActor. Errors: none. Cancellation: none.
    public init() {}

    /// Plays each requested channel at most once for `actionID` while honoring preferences.
    /// Ownership: intents are borrowed. Isolation: MainActor. Errors: none. Cancellation: repeated action IDs are ignored.
    public func dispatch(
        actionID: String,
        haptic: HapticFeedback? = nil,
        sound: SoundFeedback? = nil,
        environment: EnvironmentValues
    ) {
        guard handled.insert(actionID).inserted else { return }
        let preferences = environment[SensoryPreferencesKey.self]
        if preferences.hapticsEnabled, let haptic {
            environment[HapticsClientKey.self].play(haptic)
        }
        if preferences.soundsEnabled, let sound {
            environment[SoundClientKey.self].play(sound)
        }
    }

    /// Clears one identity so a later lifecycle can dispatch the same logical action.
    /// Ownership: dispatcher releases the identity. Isolation: MainActor. Errors: none. Cancellation: none.
    public func reset(actionID: String) { handled.remove(actionID) }
}
