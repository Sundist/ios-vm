import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// Machine settings (General / System / Storage / Description).
struct MachineSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var config: VMConfiguration
    let isRunning: Bool
    @State private var showingImporter = false

    init(config: VMConfiguration, isRunning: Bool) {
        _config = State(initialValue: config)
        self.isRunning = isRunning
    }

    var body: some View {
        NavigationStack {
            Form {
                if isRunning {
                    Section {
                        Label("Hardware settings are locked while the machine is running.", systemImage: "lock.fill")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("General") {
                    TextField("Name", text: $config.name)
                    Picker("Type", selection: $config.osType) {
                        ForEach(GuestOSType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .disabled(isRunning)
                }

                Section("System") {
                    MemoryPicker(memoryMB: $config.memoryMB, isDisabled: isRunning)
                }

                if config.osType.requiresKernel {
                    Section {
                        let current = model.machine(config.id)
                        LabeledContent("Kernel Image") {
                            if let size = current?.kernelByteCount {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            } else {
                                Text("Not attached").foregroundStyle(.red)
                            }
                        }
                        Button(current?.kernelFileName == nil ? "Attach Kernel Image…" : "Replace Kernel Image…") {
                            showingImporter = true
                        }
                        .disabled(isRunning)
                        if current?.kernelFileName != nil {
                            Button("Remove Kernel Image", role: .destructive) {
                                model.removeKernel(from: config.id)
                            }
                            .disabled(isRunning)
                        }
                        TextField("Boot arguments", text: $config.bootArguments, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Restore Default Boot Arguments") {
                            config.bootArguments = config.osType.defaultBootArguments
                        }
                    } header: {
                        Text("Storage")
                    } footer: {
                        Text("Boot arguments are passed to Linux through the generated device tree and apply on the next start.")
                    }
                }

                Section("Description") {
                    TextField("Notes", text: $config.notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .item]) { result in
                if case let .success(url) = result {
                    model.importKernel(url, into: config.id)
                }
            }
        }
    }

    private func save() {
        // Kernel fields are managed by the store; keep the latest values.
        var updated = config
        if let current = model.machine(config.id) {
            updated.kernelFileName = current.kernelFileName
            updated.kernelByteCount = current.kernelByteCount
            updated.snapshots = current.snapshots
            updated.lastRunAt = current.lastRunAt
        }
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        model.update(updated)
        dismiss()
    }
}
