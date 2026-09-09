import Testing
import Weave

@Test
@MainActor
func feedbackDispatcherHonorsPreferencesAndDeduplicatesActions() {
    let haptics = RecordingHaptics()
    let sounds = RecordingSounds()
    var environment = EnvironmentValues()
    environment[HapticsClientKey.self] = haptics
    environment[SoundClientKey.self] = sounds
    environment[SensoryPreferencesKey.self] = SensoryPreferences(
        hapticsEnabled: true, soundsEnabled: false)
    let dispatcher = FeedbackDispatcher()
    dispatcher.dispatch(
        actionID: "save", haptic: .selection, sound: .success, environment: environment)
    dispatcher.dispatch(
        actionID: "save", haptic: .selection, sound: .success, environment: environment)
    #expect(haptics.values == [.selection])
    #expect(sounds.values.isEmpty)
}

@Test
@MainActor
func noOpFeedbackIsSafeForUnsupportedCapabilities() {
    var environment = EnvironmentValues()
    environment[SensoryPreferencesKey.self] = SensoryPreferences()
    let dispatcher = FeedbackDispatcher()
    dispatcher.dispatch(
        actionID: "unsupported", haptic: .impact(intensity: 1), sound: .error,
        environment: environment)
}

@MainActor
private final class RecordingHaptics: HapticsClient {
    var values: [HapticFeedback] = []
    func play(_ feedback: HapticFeedback) { values.append(feedback) }
}

@MainActor
private final class RecordingSounds: SoundClient {
    var values: [SoundFeedback] = []
    func play(_ feedback: SoundFeedback) { values.append(feedback) }
}
