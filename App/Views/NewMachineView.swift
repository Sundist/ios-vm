import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// "Create Virtual Machine" wizard.
struct NewMachineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = GuestOSType.windows11ARM.shortName
    @State private var osType: GuestOSType = .windows11ARM
    @State private var memoryMB = GuestOSType.windows11ARM.defaultMemoryMB
    @State private var createDisk = true
    @State private var diskSizeGB = GuestOSType.windows11ARM.defaultDiskGB
    @State private var bootArguments = ""
    @State private var cdromURL: URL?
    @State private var kernelURL: URL?
    @State private var importer: ImporterKind?
    @State private var cpuCount = 2

    private enum ImporterKind: Identifiable {
        case cdrom, kernel
        var id: Self { self }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $osType) {
                        Section("QEMU (64-bit, UEFI)") {
                            ForEach(GuestOSType.qemuTypes) { type in
                                Label(type.displayName, systemImage: type.symbolName).tag(type)
                            }
                        }
                        Section("PC (32-bit x86, v86)") {
                            ForEach(GuestOSType.pcTypes) { type in
                                Label(type.displayName, systemImage: type.symbolName).tag(type)
                            }
                        }
                        Section("RISC-V") {
                            ForEach(GuestOSType.riscvTypes) { type in
                                Label(type.displayName, systemImage: type.symbolName).tag(type)
                            }
                        }
                    }
                } header: {
                    Text("Name and Operating System")
                } footer: {
                    Text(osType.setupHint)
                }

                Section {
                    MemoryPicker(memoryMB: $memoryMB, platform: osType.platform)
                } header: {
                    Text("Hardware")
                } footer: {
                    Text("Guest RAM comes out of the iPhone's memory while the machine runs. If iOS stops the machine, use less.")
                }

                if osType.platform == .qemu {
                    Section {
                        Stepper(value: $cpuCount, in: 1...4) {
                            LabeledContent("Processors", value: "\(cpuCount)")
                        }
                    } footer: {
                        Text("Each emulated processor uses one iPhone CPU core while busy.")
                    }
                }

                if osType.platform == .pc || osType.platform == .qemu {
                    Section {
                        Button {
                            importer = .cdrom
                        } label: {
                            LabeledContent {
                                Text(cdromURL?.lastPathComponent ?? "Choose ISO…")
                                    .foregroundStyle(cdromURL == nil ? Color.accentColor : .secondary)
                                    .lineLimit(1)
                            } label: {
                                Label("CD/DVD", systemImage: "opticaldisc")
                            }
                        }
                        Toggle(isOn: $createDisk) {
                            Label("Create a hard disk", systemImage: "internaldrive")
                        }
                        if createDisk {
                            Stepper(value: $diskSizeGB, in: 1...(osType.platform == .qemu ? 256 : 64)) {
                                LabeledContent("Size", value: "\(diskSizeGB) GB")
                            }
                        }
                    } header: {
                        Text("Storage")
                    } footer: {
                        Text("The ISO stays where it is (Files, On My iPhone…) and is not copied. The hard disk grows as data is written; existing raw disk images and floppies can be attached in Settings.")
                    }
                } else if osType.requiresKernel {
                    Section {
                        Button {
                            importer = .kernel
                        } label: {
                            LabeledContent("Kernel Image") {
                                Text(kernelURL?.lastPathComponent ?? "Choose…")
                                    .foregroundStyle(kernelURL == nil ? Color.accentColor : .secondary)
                            }
                        }
                        TextField("Boot arguments", text: $bootArguments, axis: .vertical)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Storage")
                    } footer: {
                        Text("A flat binary RV32 no-MMU Linux kernel (Image) with a built-in initramfs, such as the images built for mini-rv32ima.")
                    }
                }
            }
            .navigationTitle("New Virtual Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onChange(of: osType) { oldValue, newValue in
                memoryMB = newValue.defaultMemoryMB
                cpuCount = newValue.platform == .qemu ? 2 : 1
                diskSizeGB = max(newValue.defaultDiskGB, 1)
                createDisk = newValue.defaultDiskGB > 0
                bootArguments = newValue.defaultBootArguments
                if name.isEmpty || name == oldValue.shortName {
                    name = newValue.shortName
                }
            }
            .fileImporter(
                isPresented: Binding(get: { importer != nil }, set: { if !$0 { importer = nil } }),
                allowedContentTypes: importer == .cdrom ? [.diskImage, .data, .item] : [.data, .item]
            ) { result in
                guard case let .success(url) = result else { return }
                switch importer {
                case .cdrom: cdromURL = url
                case .kernel: kernelURL = url
                case nil: break
                }
                importer = nil
            }
        }
    }

    private func create() {
        var config = VMConfiguration(
            name: name.trimmingCharacters(in: .whitespaces),
            osType: osType,
            memoryMB: memoryMB)
        config.bootArguments = osType.requiresKernel ? bootArguments : ""
        if osType.platform == .pc {
            config.bootDevice = cdromURL != nil ? .cdrom : .automatic
        }
        if osType.platform == .qemu {
            config.cpuCount = cpuCount
        }
        let usesDisks = osType.platform == .pc || osType.platform == .qemu
        let created = model.create(
            config,
            kernel: osType.requiresKernel ? kernelURL : nil,
            cdrom: usesDisks ? cdromURL : nil,
            diskSizeGB: usesDisks && createDisk ? diskSizeGB : 0)
        if created != nil {
            dismiss()
        }
    }
}

/// Memory slider with VirtualBox-style power-of-two presets.
struct MemoryPicker: View {
    @Binding var memoryMB: Int
    var platform: MachinePlatform = .riscv
    var isDisabled = false

    private var presets: [Int] {
        switch platform {
        case .pc: return [16, 32, 64, 128, 256, 512, 768, 1024, 1536, 2048]
        case .qemu: return [512, 1024, 2048, 3072, 4096, 6144, 8192]
        case .riscv: return [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]
        }
    }

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent("Base Memory", value: "\(memoryMB) MB")
            Slider(
                value: Binding(
                    get: { Double(presets.firstIndex(of: memoryMB) ?? nearestIndex(memoryMB)) },
                    set: { memoryMB = presets[min(max(Int($0.rounded()), 0), presets.count - 1)] }),
                in: 0...Double(presets.count - 1),
                step: 1
            ) {
                Text("Base Memory")
            } minimumValueLabel: {
                Text("\(presets.first!) MB").font(.caption2)
            } maximumValueLabel: {
                Text(presets.last! >= 1024 ? "\(presets.last! / 1024) GB" : "\(presets.last!) MB").font(.caption2)
            }
            .disabled(isDisabled)
            if (platform == .pc && memoryMB > 1024) || (platform == .qemu && memoryMB > 3072) {
                Text("iOS may stop the machine if it uses more memory than the device allows for one app.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func nearestIndex(_ value: Int) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }
}
