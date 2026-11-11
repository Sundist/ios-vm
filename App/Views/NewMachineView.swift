import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// "Create Virtual Machine" wizard.
struct NewMachineView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var osType: GuestOSType = .linuxRV32
    @State private var memoryMB = GuestOSType.linuxRV32.defaultMemoryMB
    @State private var bootArguments = GuestOSType.linuxRV32.defaultBootArguments
    @State private var kernelURL: URL?
    @State private var showingImporter = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $osType) {
                        ForEach(GuestOSType.allCases) { type in
                            Label(type.displayName, systemImage: type.symbolName).tag(type)
                        }
                    }
                } header: {
                    Text("Name and Operating System")
                } footer: {
                    Text(osDescription)
                }

                Section {
                    MemoryPicker(memoryMB: $memoryMB)
                } header: {
                    Text("Hardware")
                } footer: {
                    Text("Guest RAM is allocated from the iPhone's memory while the machine runs.")
                }

                if osType.requiresKernel {
                    Section {
                        Button {
                            showingImporter = true
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
                        Text("A flat binary RV32 no-MMU Linux kernel (Image) with a built-in initramfs, such as the images built for mini-rv32ima. You can also attach it later.")
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
            .onChange(of: osType) { _, newValue in
                memoryMB = newValue.defaultMemoryMB
                bootArguments = newValue.defaultBootArguments
                if name.isEmpty || GuestOSType.allCases.map(\.shortName).contains(name) {
                    name = newValue.shortName
                }
            }
            .onAppear {
                if name.isEmpty { name = osType.shortName }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.data, .item]) { result in
                if case let .success(url) = result {
                    kernelURL = url
                }
            }
        }
    }

    private var osDescription: String {
        switch osType {
        case .builtInMonitor:
            return "A tiny built-in firmware with an echo console. Useful to try the app without any files."
        case .linuxRV32:
            return "Boots a 32-bit RISC-V Linux kernel on an emulated CPU with a 16550 serial console."
        }
    }

    private func create() {
        var config = VMConfiguration(
            name: name.trimmingCharacters(in: .whitespaces),
            osType: osType,
            memoryMB: memoryMB)
        config.bootArguments = osType.requiresKernel ? bootArguments : ""
        if model.create(config, kernel: osType.requiresKernel ? kernelURL : nil) != nil {
            dismiss()
        }
    }
}

/// Memory slider with VirtualBox-style power-of-two presets.
struct MemoryPicker: View {
    @Binding var memoryMB: Int
    var isDisabled = false

    private static let presets = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512]

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent("Base Memory", value: "\(memoryMB) MB")
            Slider(
                value: Binding(
                    get: { Double(Self.presets.firstIndex(of: memoryMB) ?? Self.nearestIndex(memoryMB)) },
                    set: { memoryMB = Self.presets[Int($0.rounded())] }),
                in: 0...Double(Self.presets.count - 1),
                step: 1
            ) {
                Text("Base Memory")
            } minimumValueLabel: {
                Text("1 MB").font(.caption2)
            } maximumValueLabel: {
                Text("512 MB").font(.caption2)
            }
            .disabled(isDisabled)
        }
    }

    private static func nearestIndex(_ value: Int) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }
}
