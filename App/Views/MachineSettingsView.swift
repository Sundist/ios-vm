import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// Machine settings (General / System / Storage / Description).
struct MachineSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var config: VMConfiguration
    private let original: VMConfiguration
    let isRunning: Bool
    @State private var importer: ImporterKind?
    @State private var newDiskSizeGB: Int
    @State private var confirmRemoveDisk = false

    private enum ImporterKind: Identifiable {
        case kernel, cdrom, hardDisk, floppy
        var id: Self { self }
    }

    init(config: VMConfiguration, isRunning: Bool) {
        _config = State(initialValue: config)
        _newDiskSizeGB = State(initialValue: max(config.osType.defaultDiskGB, 2))
        original = config
        self.isRunning = isRunning
    }

    /// Latest stored version (media changes are applied immediately).
    private var current: VMConfiguration { model.machine(config.id) ?? config }

    private var hardwareChanged: Bool {
        config.memoryMB != original.memoryMB || config.vgaMemoryMB != original.vgaMemoryMB
            || config.acpiEnabled != original.acpiEnabled || config.osType != original.osType
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
                        ForEach(config.platform == .pc ? GuestOSType.pcTypes : GuestOSType.riscvTypes) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .disabled(isRunning)
                }

                Section {
                    MemoryPicker(memoryMB: $config.memoryMB, platform: config.platform, isDisabled: isRunning)
                    if config.platform == .pc {
                        Picker("Video Memory", selection: $config.vgaMemoryMB) {
                            ForEach([2, 4, 8, 16, 32, 64], id: \.self) { Text("\($0) MB").tag($0) }
                        }
                        .disabled(isRunning)
                        Toggle("ACPI", isOn: $config.acpiEnabled)
                            .disabled(isRunning)
                        Picker("Boot Order", selection: $config.bootDevice) {
                            ForEach(BootDevice.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                } header: {
                    Text("System")
                } footer: {
                    if config.platform == .pc {
                        Text("Windows 95–XP need ACPI off. Vista/7 and most Linux distributions want it on.\(current.hasSavedState && hardwareChanged ? " Changing the hardware discards the saved state." : "")")
                    }
                }

                if config.platform == .pc {
                    pcStorage
                } else if config.osType.requiresKernel {
                    kernelStorage
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
            .fileImporter(
                isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                allowedContentTypes: importer == .cdrom ? [.diskImage, .data, .item] : [.data, .item]
            ) { result in
                guard case let .success(url) = result else { return }
                switch importer {
                case .kernel: model.importKernel(url, into: config.id)
                case .cdrom: model.attachCDROM(url, to: config.id)
                case .hardDisk: model.importHardDisk(url, into: config.id)
                case .floppy: model.importFloppy(url, into: config.id)
                case nil: break
                }
                importer = nil
            }
            .confirmationDialog("Delete the hard disk?", isPresented: $confirmRemoveDisk, titleVisibility: .visible) {
                Button("Delete Hard Disk", role: .destructive) { model.removeHardDisk(from: config.id) }
            } message: {
                Text("Everything installed on it will be lost.")
            }
        }
    }

    private func size(_ bytes: Int64?) -> String {
        ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file)
    }

    private var pcStorage: some View {
        Group {
            Section {
                LabeledContent("Image", value: current.cdromName ?? "Empty")
                Button(current.cdromName == nil ? "Choose ISO…" : "Change ISO…") { importer = .cdrom }
                if current.cdromName != nil {
                    Button("Eject", role: .destructive) { model.detachCDROM(from: config.id) }
                }
            } header: {
                Label("CD/DVD", systemImage: "opticaldisc")
            } footer: {
                Text("ISO images are used in place, without copying. Keep the file where it is.")
            }

            Section {
                if current.hardDiskFileName != nil {
                    LabeledContent("Size", value: size(current.hardDiskByteCount))
                    Button("Delete Hard Disk", role: .destructive) { confirmRemoveDisk = true }
                        .disabled(isRunning)
                } else {
                    Stepper(value: $newDiskSizeGB, in: 1...64) {
                        LabeledContent("New disk", value: "\(newDiskSizeGB) GB")
                    }
                    Button("Create Hard Disk") { model.createHardDisk(sizeGB: newDiskSizeGB, for: config.id) }
                        .disabled(isRunning)
                    Button("Use Existing Raw Image (.img)…") { importer = .hardDisk }
                        .disabled(isRunning)
                }
            } header: {
                Label("Hard Disk", systemImage: "internaldrive")
            } footer: {
                Text("Raw images only. Convert VirtualBox/QEMU disks first, e.g. qemu-img convert -O raw disk.vdi disk.img")
            }

            Section {
                if current.floppyFileName != nil {
                    LabeledContent("Image", value: size(current.floppyByteCount))
                    Button("Remove Floppy", role: .destructive) { model.removeFloppy(from: config.id) }
                        .disabled(isRunning)
                } else {
                    Button("Attach Floppy Image…") { importer = .floppy }
                        .disabled(isRunning)
                }
            } header: {
                Label("Floppy", systemImage: "square.and.arrow.down.on.square")
            }
        }
    }

    private var kernelStorage: some View {
        Section {
            LabeledContent("Kernel Image") {
                if let bytes = current.kernelByteCount {
                    Text(size(bytes))
                } else {
                    Text("Not attached").foregroundStyle(.red)
                }
            }
            Button(current.kernelFileName == nil ? "Attach Kernel Image…" : "Replace Kernel Image…") {
                importer = .kernel
            }
            .disabled(isRunning)
            if current.kernelFileName != nil {
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

    private func save() {
        // Media fields are managed by the store; keep their latest values.
        var updated = config
        let latest = current
        updated.kernelFileName = latest.kernelFileName
        updated.kernelByteCount = latest.kernelByteCount
        updated.cdromName = latest.cdromName
        updated.cdromBookmark = latest.cdromBookmark
        updated.cdromByteCount = latest.cdromByteCount
        updated.hardDiskFileName = latest.hardDiskFileName
        updated.hardDiskByteCount = latest.hardDiskByteCount
        updated.floppyFileName = latest.floppyFileName
        updated.floppyByteCount = latest.floppyByteCount
        updated.snapshots = latest.snapshots
        updated.lastRunAt = latest.lastRunAt
        updated.hasSavedState = latest.hasSavedState
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        model.update(updated)
        if latest.hasSavedState && hardwareChanged {
            model.discardSavedState(of: config.id)
        }
        dismiss()
    }
}
