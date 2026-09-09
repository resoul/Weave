import Foundation

public import Flux

/// Localizable text value used by validation issues. Ownership: strings are copied. Isolation: none.
/// Errors: none. Cancellation: not applicable.
public struct LocalizedText: Sendable, Equatable, Hashable {
    public let key: String
    public let fallback: String
    public let table: String?
    public let arguments: [LocalizedArgument]

    /// Creates a localizable value. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        key: String,
        fallback: String,
        table: String? = nil,
        arguments: [LocalizedArgument] = []
    ) {
        self.key = key
        self.fallback = fallback
        self.table = table
        self.arguments = arguments
    }
}

/// Field interaction phase. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum FieldInteraction: Sendable, Equatable, Hashable {
    case pristine
    case touched
    case dirty
}

/// Validation severity. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public enum ValidationSeverity: Sendable, Equatable, Hashable {
    case error
    case warning
}

/// One localized validation issue. Ownership: immutable value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ValidationIssue: Sendable, Equatable, Hashable {
    public let code: String
    public let message: LocalizedText
    public let severity: ValidationSeverity

    /// Creates an issue. Ownership: arguments are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(code: String, message: LocalizedText, severity: ValidationSeverity = .error) {
        self.code = code
        self.message = message
        self.severity = severity
    }
}

/// Validation lifecycle for one field. Ownership: immutable snapshot. Isolation: none. Errors: issues are typed. Cancellation: validating work is owner-cancelled.
public enum ValidationState: Sendable, Equatable, Hashable {
    case idle
    case validating
    case valid
    case invalid([ValidationIssue])
}

/// Complete immutable state for one field. Ownership: value owns its snapshot. Isolation: none. Errors: validation is typed. Cancellation: not applicable.
public struct FieldState<Value: Sendable & Equatable>: Sendable, Equatable {
    public let value: Value
    public let interaction: FieldInteraction
    public let validation: ValidationState

    /// Creates field state. Ownership: value is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        value: Value,
        interaction: FieldInteraction = .pristine,
        validation: ValidationState = .idle
    ) {
        self.value = value
        self.interaction = interaction
        self.validation = validation
    }
}

/// Async validation rule supplied by the product/domain layer. Ownership: caller owns dependencies captured by the rule.
/// Isolation: Sendable async boundary. Errors: return typed issues. Cancellation: rule must observe task cancellation.
public protocol ValidationRule: Sendable {
    associatedtype Value: Sendable
    func validate(_ value: Value) async -> [ValidationIssue]
}

/// Injectable scheduling point for deterministic validation tests. Ownership: implementation owns its clock state.
/// Isolation: async Sendable boundary. Errors: none. Cancellation: caller cancellation propagates.
public protocol ValidationClock: Sendable {
    func yield() async
}

/// Clock that completes without delaying validation. Ownership: stateless value. Isolation: none. Errors: none. Cancellation: not applicable.
public struct ImmediateValidationClock: ValidationClock {
    /// Creates an immediate clock. Ownership: none. Isolation: none. Errors: none. Cancellation: not applicable.
    public init() {}

    /// Reaches the next scheduling point. Ownership: none. Isolation: async. Errors: none. Cancellation: caller-owned.
    public func yield() async { await Task.yield() }
}

/// Compact field summary used by aggregate form state. Ownership: immutable value. Isolation: none. Errors: issues are typed. Cancellation: not applicable.
public struct FieldValidationSnapshot: Sendable, Equatable, Hashable {
    public let interaction: FieldInteraction
    public let validation: ValidationState

    /// Creates a field summary. Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(interaction: FieldInteraction, validation: ValidationState) {
        self.interaction = interaction
        self.validation = validation
    }
}

/// Aggregate form state keyed by stable field identity. Ownership: immutable snapshot. Isolation: none.
/// Errors: invalid fields remain typed. Cancellation: not applicable.
public struct FormState<FieldID: Hashable & Sendable>: Sendable, Equatable {
    public let fields: [FieldID: FieldValidationSnapshot]
    public let isValid: Bool
    public let isValidating: Bool
    public let submitCount: Int

    /// Creates aggregate state. Ownership: dictionary is copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(
        fields: [FieldID: FieldValidationSnapshot] = [:],
        isValid: Bool = true,
        isValidating: Bool = false,
        submitCount: Int = 0
    ) {
        self.fields = fields
        self.isValid = isValid
        self.isValidating = isValidating
        self.submitCount = submitCount
    }
}

/// Announcement emitted only after interaction or submit. Ownership: immutable snapshot. Isolation: none.
/// Errors: carries localized issues. Cancellation: subscriber-owned.
public struct ValidationAnnouncement<FieldID: Hashable & Sendable>: Sendable, Equatable {
    public let fieldID: FieldID
    public let issues: [ValidationIssue]

    /// Creates an announcement. Ownership: values are copied. Isolation: none. Errors: none. Cancellation: not applicable.
    public init(fieldID: FieldID, issues: [ValidationIssue]) {
        self.fieldID = fieldID
        self.issues = issues
    }
}

/// Form submit result. Ownership: immutable value. Isolation: none. Errors: invalid identity is typed. Cancellation: caller-owned.
public enum FormSubmitResult<FieldID: Hashable & Sendable>: Sendable, Equatable {
    case submitted
    case blocked(firstInvalid: FieldID)
}

@MainActor
private protocol AnyFieldController: AnyObject {
    var snapshot: FieldValidationSnapshot { get }
    var onChange: (@MainActor @Sendable () -> Void)? { get set }
    func markTouched()
    func validate() async
    func dispose()
}

/// Main-actor field orchestrator with sync validation and latest-wins async validation.
/// Ownership: field owns its value, validation task and cancellation generation. Isolation: MainActor.
/// Errors: validation is exposed in state. Cancellation: replacing value, dispose and deinit cancel work.
@MainActor
public final class FieldController<Value: Sendable & Equatable>: AnyFieldController {
    public private(set) var state: FieldState<Value>
    public var onChange: (@MainActor @Sendable () -> Void)?

    private let syncRules: [@Sendable (Value) -> [ValidationIssue]]
    private let asyncValidator: (@Sendable (Value) async -> [ValidationIssue])?
    private let clock: any ValidationClock
    private var validationTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var disposed = false

    /// Creates a field without starting validation. Ownership: rules and clock are retained. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init(
        value: Value,
        syncRules: [@Sendable (Value) -> [ValidationIssue]] = [],
        asyncValidator: (@Sendable (Value) async -> [ValidationIssue])? = nil,
        clock: any ValidationClock = ImmediateValidationClock()
    ) {
        self.state = FieldState(value: value)
        self.syncRules = syncRules
        self.asyncValidator = asyncValidator
        self.clock = clock
    }

    /// Replaces the value and starts a new validation generation. Ownership: value is copied. Isolation: MainActor. Errors: state becomes invalid when rules report issues. Cancellation: prior validation is cancelled.
    public func setValue(_ value: Value) {
        guard !disposed else { return }
        generation &+= 1
        validationTask?.cancel()
        let issues = syncRules.flatMap { $0(value) }
        let interaction: FieldInteraction = state.interaction == .pristine ? .dirty : .dirty
        state = FieldState(
            value: value,
            interaction: interaction,
            validation: asyncValidator == nil
                ? (issues.isEmpty ? .valid : .invalid(issues)) : .validating)
        notifyChange()
        guard let asyncValidator else { return }
        let expected = generation
        validationTask = Task { @MainActor [weak self] in
            await self?.clock.yield()
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            let asyncIssues = await asyncValidator(value)
            guard !Task.isCancelled, self.generation == expected, self.state.value == value else {
                return
            }
            let allIssues = issues + asyncIssues
            self.state = FieldState(
                value: value,
                interaction: self.state.interaction,
                validation: allIssues.isEmpty ? .valid : .invalid(allIssues))
            self.notifyChange()
        }
    }

    /// Marks the field as touched and validates its current value. Ownership: no value escapes. Isolation: MainActor. Errors: issues remain in state. Cancellation: prior async validation is replaced.
    public func markTouched() {
        guard !disposed else { return }
        if state.interaction == .pristine {
            state = FieldState(
                value: state.value, interaction: .touched, validation: state.validation)
            notifyChange()
        }
        validateNow()
    }

    /// Runs current sync/async rules. Ownership: field owns the generation. Isolation: MainActor. Errors: issues are stored. Cancellation: latest generation wins.
    public func validate() async { validateNow(); await validationTask?.value }

    /// Cancels all owned validation work. Ownership: field releases its task. Isolation: MainActor. Errors: none. Cancellation: terminal.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        generation &+= 1
        validationTask?.cancel()
        validationTask = nil
        onChange = nil
    }

    var snapshot: FieldValidationSnapshot {
        FieldValidationSnapshot(interaction: state.interaction, validation: state.validation)
    }

    private func validateNow() {
        let value = state.value
        let issues = syncRules.flatMap { $0(value) }
        generation &+= 1
        validationTask?.cancel()
        guard let asyncValidator else {
            state = FieldState(
                value: value, interaction: state.interaction,
                validation: issues.isEmpty ? .valid : .invalid(issues))
            notifyChange()
            return
        }
        let expected = generation
        state = FieldState(value: value, interaction: state.interaction, validation: .validating)
        notifyChange()
        validationTask = Task { @MainActor [weak self] in
            await self?.clock.yield()
            guard !Task.isCancelled, let self, self.generation == expected else { return }
            let asyncIssues = await asyncValidator(value)
            guard !Task.isCancelled, self.generation == expected else { return }
            let allIssues = issues + asyncIssues
            self.state = FieldState(
                value: value, interaction: self.state.interaction,
                validation: allIssues.isEmpty ? .valid : .invalid(allIssues))
            self.notifyChange()
        }
    }

    private func notifyChange() { onChange?() }
}

/// Main-actor form coordinator connecting field values, validation, announcements and submit focus policy.
/// Ownership: form owns registered fields and bounded output pipes. Isolation: MainActor. Errors: submit reports first invalid field. Cancellation: dispose cancels all validators.
@MainActor
public final class FormController<FieldID: Hashable & Sendable> {
    public let state: Flux<FormState<FieldID>>
    public let announcements: Flux<ValidationAnnouncement<FieldID>>
    public let submissions: Flux<FormSubmitResult<FieldID>>

    private let statePipe = Pipe<FormState<FieldID>>(bufferingPolicy: .bufferingNewest(1))
    private let announcementPipe = Pipe<ValidationAnnouncement<FieldID>>(
        bufferingPolicy: .bufferingNewest(32))
    private let submissionPipe = Pipe<FormSubmitResult<FieldID>>(
        bufferingPolicy: .bufferingNewest(16))
    private var fields: [FieldID: any AnyFieldController] = [:]
    private var order: [FieldID] = []
    private var focusHandlers: [FieldID: @MainActor @Sendable () -> Void] = [:]
    private var current = FormState<FieldID>()
    private var submitAttempted = false
    private var disposed = false

    /// Creates an empty form. Ownership: form owns registered field references and pipes. Isolation: MainActor. Errors: none. Cancellation: no work starts.
    public init() {
        state = statePipe.flux
        announcements = announcementPipe.flux
        submissions = submissionPipe.flux
    }

    /// Registers a field in deterministic focus order. Ownership: form retains the field. Isolation: MainActor. Errors: duplicate IDs replace existing registration. Cancellation: disposal remains form-owned.
    public func register<Value: Sendable & Equatable>(
        _ fieldID: FieldID,
        field: FieldController<Value>,
        focus: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        guard !disposed else { return }
        if fields[fieldID] == nil { order.append(fieldID) }
        field.onChange = { [weak self] in self?.publish() }
        fields[fieldID] = field
        focusHandlers[fieldID] = focus
        publish()
    }

    /// Marks a field touched and emits only interaction-eligible issue announcements. Ownership: field remains form-owned. Isolation: MainActor. Errors: validation stays in field state. Cancellation: field policy applies.
    public func touch(_ fieldID: FieldID) {
        guard let field = fields[fieldID] else { return }
        field.markTouched()
        publish()
        announce(fieldID)
    }

    /// Validates all fields and focuses the first invalid field by registration order. Ownership: form owns orchestration. Isolation: MainActor. Errors: result reports first invalid field. Cancellation: caller cancellation propagates.
    public func submit() async -> FormSubmitResult<FieldID> {
        guard !disposed else { return .submitted }
        submitAttempted = true
        for fieldID in order { await fields[fieldID]?.validate() }
        publish()
        for fieldID in order {
            announce(fieldID)
            if let snapshot = fields[fieldID]?.snapshot,
                case .invalid = snapshot.validation
            {
                focusHandlers[fieldID]?()
                let result: FormSubmitResult<FieldID> = .blocked(firstInvalid: fieldID)
                submissionPipe.send(result)
                return result
            }
        }
        let result: FormSubmitResult<FieldID> = .submitted
        submissionPipe.send(result)
        return result
    }

    /// Releases every registered field and finishes form outputs. Ownership: form releases fields. Isolation: MainActor. Errors: none. Cancellation: all validators are cancelled.
    public func dispose() {
        guard !disposed else { return }
        disposed = true
        fields.values.forEach { $0.dispose() }
        fields.removeAll()
        order.removeAll()
        focusHandlers.removeAll()
        statePipe.finish(); announcementPipe.finish(); submissionPipe.finish()
    }

    private func publish() {
        guard !disposed else { return }
        var snapshots: [FieldID: FieldValidationSnapshot] = [:]
        var validating = false
        var valid = true
        for fieldID in order {
            guard let field = fields[fieldID] else { continue }
            snapshots[fieldID] = field.snapshot
            if case .validating = field.snapshot.validation { validating = true }
            if case .invalid = field.snapshot.validation { valid = false }
        }
        current = FormState(
            fields: snapshots, isValid: valid, isValidating: validating,
            submitCount: submitAttempted ? 1 : 0)
        statePipe.send(current)
    }

    private func announce(_ fieldID: FieldID) {
        guard let field = fields[fieldID],
            field.snapshot.interaction != .pristine || submitAttempted,
            case let .invalid(issues) = field.snapshot.validation,
            !issues.isEmpty
        else { return }
        announcementPipe.send(ValidationAnnouncement(fieldID: fieldID, issues: issues))
    }
}
