import AppIntents
import Foundation
import Observation

/// Hands launch requests from intents, widgets and URLs to the UI.
@MainActor
@Observable
final class LaunchRouter {
    static let shared = LaunchRouter()
    var pendingMachineID: UUID?

    func request(_ id: UUID) {
        pendingMachineID = id
    }
}

/// "Start Virtual Machine": the action used for Home Screen shortcuts.
struct StartVirtualMachineIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Virtual Machine"
    static let description = IntentDescription("Opens PocketVM and starts the chosen virtual machine.")
    static let openAppWhenRun = true

    @Parameter(title: "Virtual Machine")
    var machine: VirtualMachineEntity

    init() {}

    init(machine: VirtualMachineEntity) {
        self.machine = machine
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Start \(\.$machine)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.request(machine.id)
        return .result()
    }
}

/// Shortcuts that appear automatically in the Shortcuts app and Siri,
/// one per virtual machine.
struct PocketVMShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartVirtualMachineIntent(),
            phrases: [
                "Start \(\.$machine) in \(.applicationName)",
                "Open \(\.$machine) in \(.applicationName)",
                "Start a virtual machine in \(.applicationName)",
            ],
            shortTitle: "Start VM",
            systemImageName: "desktopcomputer")
    }

    static let shortcutTileColor: ShortcutTileColor = .blue
}
