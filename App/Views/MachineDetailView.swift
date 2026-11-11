import SwiftUI
import VMCore

/// Details pane for one machine: summary, power controls, storage,
/// saved state / snapshots and Home Screen integration.
struct MachineDetailView: View {
    @Environment(AppModel.self) private var model
    let machineID: UUID

    @State private var showingSettings = false
    @State private var showingSnapshotPrompt = false
    @State private var showingHomeScreenGuide = false
    @State private var snapshotName = ""
    @State private var confirmDelete = false

    var body: some View {
        if let config = model.machine(machineID) {
            content(config)
        }
    }

    private func size(_ bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private func content(_ config: VMConfiguration) -> some View {
        let state = model.state(for: machineID)

        List {
            Section {
                HStack(spacing: 16) {
                    MachineIcon(osType: config.osType, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.name).font(.title2.bold())
                        Text(config.osType.displayName).font(.subheadline).foregroundStyle(.secondary)
                        StateLabel(state: state, hasSnapshots: !config.snapshots.isEmpty, hasSavedState: config.hasSavedState)
                    }
                }
                .padding(.vertical, 6)

                if case let .halted(reason) = state {
                    Text(reason)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.red)
                }

                powerControls(config: config, state: state)
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
                if config.platform == .pc {
                    LabeledContent("Processor", value: "1 × x86 (32-bit)")
                    LabeledContent("Acceleration", value: "WebAssembly JIT (v86)")
                    LabeledContent("Boot Order", value: config.bootDevice.displayName)
                    LabeledContent("ACPI", value: config.acpiEnabled ? "On" : "Off")
                    LabeledContent("Video Memory", value: "\(config.vgaMemoryMB) MB")
                } else if config.platform == .qemu {
                    LabeledContent("Processors", value: "\(config.cpuCount) × \(config.osType.qemuArchitecture.displayName)")
                    LabeledContent("Firmware", value: "UEFI")
                    LabeledContent("Acceleration", value: QEMURuntime.shared.flavor == .jit ? "QEMU TCG (JIT)" : "QEMU TCTI (no JIT)")
                    if config.osType.isWindows11 {
                        LabeledContent("Windows 11 checks", value: config.bypassWindowsRequirements ? "Bypassed" : "Enforced")
                    }
                } else {
                    LabeledContent("Processor", value: "1 × RV32IMA")
                    LabeledContent("Acceleration", value: "Interpreter")
                }
                if state.isActive, let speed = model.speedDescription(for: machineID) {
                    LabeledContent("Speed", value: speed)
                }
            }

            Section("Storage") {
                if config.platform == .pc || config.platform == .qemu {
                    LabeledContent {
                        Text(config.cdromName ?? "Empty").foregroundStyle(config.cdromName == nil ? .secondary : .primary)
                    } label: {
                        Label("CD/DVD", systemImage: "opticaldisc")
                    }
                    LabeledContent {
                        Text(config.hardDiskFileName == nil ? "None" : size(config.hardDiskByteCount))
                            .foregroundStyle(config.hardDiskFileName == nil ? .secondary : .primary)
                    } label: {
                        Label("Hard Disk", systemImage: "internaldrive")
                    }
                    if config.floppyFileName != nil {
                        LabeledContent {
                            Text(size(config.floppyByteCount))
                        } label: {
                            Label("Floppy", systemImage: "square.and.arrow.down.on.square")
                        }
                    }
                } else if config.osType.requiresKernel {
                    LabeledContent("Kernel Image") {
                        if config.kernelByteCount != nil {
                            Text(size(config.kernelByteCount))
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
                Button("Change Storage…") { showingSettings = true }
            }

            if config.platform == .pc {
                Section {
                    if config.hasSavedState {
                        LabeledContent("Saved State", value: size(model.store.savedStateSize(for: machineID)))
                        Button("Discard Saved State", role: .destructive) {
                            model.discardSavedState(of: machineID)
                        }
                        .disabled(state.isActive)
                    } else {
                        Text("Use “Save State and Close” in the machine window to continue later exactly where you left off.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Saved State")
                }
            } else if config.platform == .riscv {
                snapshotsSection(config: config, state: state)
            }

            Section {
                Button {
                    showingHomeScreenGuide = true
                } label: {
                    Label("Add to Home Screen…", systemImage: "apps.iphone.badge.plus")
                }
            } header: {
                Text("Home Screen")
            } footer: {
                Text("Start this machine like an app, straight from the Home Screen.")
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
        .sheet(isPresented: $showingHomeScreenGuide) {
            HomeScreenGuideView(config: config)
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
            Text("The hard disk, kernel image, saved state and snapshots stored for this machine will be removed. Attached ISO files are not deleted.")
        }
    }

    @ViewBuilder
    private func snapshotsSection(config: VMConfiguration, state: VMEngine.State) -> some View {
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
                        Text("\(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(size(snapshot.byteCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") {
                        model.start(machineID, from: snapshot)
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
    }

    @ViewBuilder
    private func powerControls(config: VMConfiguration, state: VMEngine.State) -> some View {
        if state.isActive {
            Button {
                model.consoleTarget = ConsoleTarget(id: machineID)
            } label: {
                Label("Show Machine Window", systemImage: config.platform == .pc ? "display" : "terminal.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            HStack {
                if state == .running {
                    Button { model.pause(machineID) } label: { Label("Pause", systemImage: "pause.fill") }
                } else {
                    Button { model.resume(machineID) } label: { Label("Resume", systemImage: "play.fill") }
                }
                Spacer()
                Button { model.reset(machineID) } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Spacer()
                Button(role: .destructive) { model.powerOff(machineID) } label: { Label("Power Off", systemImage: "power") }
            }
            .buttonStyle(.bordered)
        } else {
            if let problem = config.startProblem ?? model.qemuEngineProblem(for: config) {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Button {
                model.launch(machineID)
            } label: {
                Label(config.hasSavedState ? "Continue (Saved State)" : "Start", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(config.startProblem != nil)
        }
    }
}
