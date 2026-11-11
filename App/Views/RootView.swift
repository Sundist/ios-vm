import SwiftUI
import VMCore

/// The "VirtualBox Manager" window: machine list + details.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewMachine = false
    private var router: LaunchRouter { LaunchRouter.shared }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.machines) { machine in
                    NavigationLink(value: machine.id) {
                        MachineRow(config: machine, state: model.state(for: machine.id))
                    }
                    .contextMenu {
                        Button {
                            model.launch(machine.id)
                        } label: { Label("Start", systemImage: "play.fill") }
                        Button {
                            model.clone(machine.id)
                        } label: { Label("Clone", systemImage: "plus.square.on.square") }
                        Button(role: .destructive) {
                            model.delete(machine.id)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                .onDelete { offsets in
                    for id in offsets.map({ model.machines[$0].id }) { model.delete(id) }
                }
            }
            .navigationTitle("PocketVM")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewMachine = true
                    } label: {
                        Label("New Machine", systemImage: "plus")
                    }
                }
            }
            .overlay {
                if model.machines.isEmpty {
                    ContentUnavailableView {
                        Label("No Virtual Machines", systemImage: "desktopcomputer")
                    } description: {
                        Text("Tap + to create your first virtual machine.")
                    }
                }
            }
        } detail: {
            if let id = model.selection, model.machine(id) != nil {
                MachineDetailView(machineID: id)
                    .id(id)
            } else {
                ContentUnavailableView(
                    "Select a Machine",
                    systemImage: "sidebar.left",
                    description: Text("Choose a virtual machine from the list."))
            }
        }
        .sheet(isPresented: $showingNewMachine) {
            NewMachineView()
        }
        .fullScreenCover(item: $model.consoleTarget) { target in
            ConsoleWindow(machineID: target.id)
        }
        .overlay {
            if let message = model.busyMessage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message).font(.callout)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(
            "PocketVM",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }),
            presenting: model.errorMessage
        ) { _ in
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { message in
            Text(message)
        }
        // Home Screen widgets and shortcuts open pocketvm://start?id=…
        .onOpenURL { url in
            if let id = MachineCatalog.machineID(from: url) {
                router.request(id)
            }
        }
        .onChange(of: router.pendingMachineID) { handlePendingLaunch() }
        .onAppear { handlePendingLaunch() }
    }

    private func handlePendingLaunch() {
        guard let id = router.pendingMachineID else { return }
        router.pendingMachineID = nil
        showingNewMachine = false
        if model.consoleTarget != nil && model.consoleTarget?.id != id {
            // Close the current window first, then open the requested one.
            model.consoleTarget = nil
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                model.launch(id)
            }
        } else {
            model.launch(id)
        }
    }
}

/// Picks the right console for the machine's engine.
struct ConsoleWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let machineID: UUID

    var body: some View {
        let name = model.machine(machineID)?.name ?? "Virtual Machine"
        if let pc = model.pcSessions[machineID] {
            PCConsoleView(session: pc, machineName: name)
        } else if let qemu = model.qemuSessions[machineID] {
            QEMUConsoleView(session: qemu, machineName: name)
        } else if let session = model.sessions[machineID] {
            ConsoleView(session: session, machineName: name)
        } else {
            ContentUnavailableView {
                Label("Not Running", systemImage: "power")
            } actions: {
                Button("Close") { dismiss() }
            }
        }
    }
}

struct MachineIcon: View {
    let osType: GuestOSType
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: osType.symbolName)
            .font(size > 50 ? .largeTitle : .title2)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(osType.accentColor.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
    }
}

struct MachineRow: View {
    let config: VMConfiguration
    let state: VMEngine.State

    var body: some View {
        HStack(spacing: 12) {
            MachineIcon(osType: config.osType)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.headline)
                StateLabel(state: state, hasSnapshots: !config.snapshots.isEmpty, hasSavedState: config.hasSavedState)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StateLabel: View {
    let state: VMEngine.State
    var hasSnapshots = false
    var hasSavedState = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
    }

    private var title: String {
        switch state {
        case .running: return "Running"
        case .paused: return "Paused"
        case .halted: return "Guru Meditation"
        case .stopped, .poweredOff:
            if hasSavedState { return "Saved" }
            return hasSnapshots ? "Powered Off (snapshots)" : "Powered Off"
        }
    }

    private var symbol: String {
        switch state {
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .halted: return "exclamationmark.triangle.fill"
        case .stopped, .poweredOff: return hasSavedState ? "square.and.arrow.down.fill" : "power.circle"
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .paused: return .yellow
        case .halted: return .red
        case .stopped, .poweredOff: return hasSavedState ? .blue : .secondary
        }
    }
}
