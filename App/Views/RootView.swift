import SwiftUI
import VMCore

/// The "VirtualBox Manager" window: machine list + details.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingNewMachine = false

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
                            model.start(machine.id)
                            model.selection = machine.id
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
    }
}

struct MachineRow: View {
    let config: VMConfiguration
    let state: VMEngine.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: config.osType.symbolName)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(config.osType == .linuxRV32 ? Color.orange.gradient : Color.blue.gradient,
                            in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.headline)
                StateLabel(state: state, hasSnapshots: !config.snapshots.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StateLabel: View {
    let state: VMEngine.State
    var hasSnapshots = false

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
        case .stopped, .poweredOff: return hasSnapshots ? "Powered Off (snapshots)" : "Powered Off"
        }
    }

    private var symbol: String {
        switch state {
        case .running: return "play.circle.fill"
        case .paused: return "pause.circle.fill"
        case .halted: return "exclamationmark.triangle.fill"
        case .stopped, .poweredOff: return "power.circle"
        }
    }

    private var color: Color {
        switch state {
        case .running: return .green
        case .paused: return .yellow
        case .halted: return .red
        case .stopped, .poweredOff: return .secondary
        }
    }
}
