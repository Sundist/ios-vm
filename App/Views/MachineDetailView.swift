import SwiftUI
import VMCore

/// Details pane for one machine: summary, power controls and snapshots.
struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    let machineID: UUID

    @State private var showingConsole = false
    @State private var showingSettings = false
    @State private var showingSnapshotPrompt = false
    @State private var snapshotName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let config = model.machine(machineID) {
            content(config)
        }
    }

    @ViewBuilder
    private func content(_ config: VMConfiguration) -> some View {
        let state = model.state(for: machineID)
        let session = model.sessions[machineID]

        List {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: config.osType.symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(.white)
                        .frame(width: 64, height: 64)
                        .background(config.osType == .linuxRV32 ? Color.orange.gradient : Color.blue.gradient,
                                    in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.name).font(.title2.bold())
                        Text(config.osType.displayName).font(.subheadline).foregroundStyle(.secondary)
                        StateLabel(state: state, hasSnapshots: !config.snapshots.isEmpty)
                    }
                }
                .padding(.vertical, 6)

                if case let .halted(reason) = state {
                    Text(reason)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                }

                powerControls(config: config, state: state, session: session)
            }

            Section("General") {
                LabeledContent("Name", value: config.name)
                LabeledContent("Operating System", value: config.osType.shortName)
                if let lastRun = config.lastRunAt {
                    LabeledContent("Last Started", value: lastRun.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("System") {
                LabeledContent("Base Memory", value: "\(config.memoryMB) MB")
                LabeledContent("Processors", value: "1 × RV32IMA")
                LabeledContent("Acceleration", value: "Interpreter")
                if let session, state.isActive {
                    LabeledContent("Speed", value: session.mipsDescription)
                }
            }

            Section("Storage") {
                if config.osType.requiresKernel {
                    LabeledContent("Kernel Image") {
                        if let size = config.kernelByteCount {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        } else {
                            Text("Not attached").foregroundStyle(.red)
                        }
                    }
                    if !config.bootArguments.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Boot Arguments")
                            Text(config.bootArguments).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    LabeledContent("Firmware", value: "Built-in monitor")
                }
            }

            Section("Serial Port") {
                LabeledContent("Port 1", value: "16550A UART → Console")
            }

            Section {
                if config.snapshots.isEmpty {
                    Text(state.isActive
                         ? "Take a snapshot to save the current machine state."
                         : "Start the machine to take snapshots.")
                        .foregroundStyle(.secondary)
                }
                ForEach(config.snapshots.sorted { $0.createdAt > $1.createdAt }) { snapshot in
                    HStack {
                        Image(systemName: "camera")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(snapshot.name)
                            Text("\(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: snapshot.byteCount, countStyle: .file))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore") {
                            if model.start(machineID, from: snapshot) != nil {
                                showingConsole = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteSnapshot(snapshot, of: machineID)
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                if state.isActive {
                    Button {
                        snapshotName = "Snapshot \(config.snapshots.count + 1)"
                        showingSnapshotPrompt = true
                    } label: {
                        Label("Take Snapshot", systemImage: "camera.badge.ellipsis")
                    }
                }
            } header: {
                Text("Snapshots")
            }

            if !config.notes.isEmpty {
                Section("Description") {
                    Text(config.notes)
                }
            }
        }
        .navigationTitle(config.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Menu {
                    Button {
                        model.clone(machineID)
                    } label: { Label("Clone", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: { Label("Delete…", systemImage: "trash") }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            MachineSettingsView(config: config, isRunning: state.isActive)
        }
        .fullScreenCover(isPresented: $showingConsole) {
            if let session = model.sessions[machineID] {
                ConsoleView(session: session, machineName: config.name)
            }
        }
        .alert("Take Snapshot", isPresented: $showingSnapshotPrompt) {
            TextField("Name", text: $snapshotName)
            Button("Cancel", role: .cancel) {}
            Button("Take") {
                let name = snapshotName.isEmpty ? "Snapshot" : snapshotName
                Task { await model.takeSnapshot(of: machineID, named: name) }
            }
        } message: {
            Text("The complete machine state (\(config.memoryMB) MB RAM) will be saved.")
        }
        .confirmationDialog("Delete “\(config.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Machine and Files", role: .destructive) {
                model.delete(machineID)
            }
        } message: {
            Text("The kernel image and all snapshots stored for this machine will be removed.")
        }
    }

    @ViewBuilder
    private func powerControls(config: VMConfiguration, state: VMEngine.State, session: VMSession?) -> some View {
        if state.isActive, let session {
            Button {
                showingConsole = true
            } label: {
                Label("Show Console", systemImage: "terminal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                if state == .running {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                } else {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                }
                Spacer()
                Button { session.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Spacer()
                Button(role: .destructive) { session.powerOff() } label: { Label("Power Off", systemImage: "power") }
            }
            .buttonStyle(.bordered)
        } else {
            if let problem = config.startProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                if model.start(machineID) != nil {
                    showingConsole = true
                }
            } label: {
                Label("Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(config.startProblem != nil)
        }
    }
}
