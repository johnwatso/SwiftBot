import AppIntents

/// Gives Shortcuts a SwiftBot-owned action to associate with the bundled
/// workflows. Shortcuts uses that association to display SwiftBot's app icon.
struct SwiftBotWorkflowAttributionIntent: AppIntent {
    static let title: LocalizedStringResource = "SwiftBot Workflow"
    static let description = IntentDescription(
        "Identifies an Apple Intelligence workflow supplied by SwiftBot."
    )

    static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult {
        .result()
    }
}
