import SwiftUI
import UniformTypeIdentifiers
import VMCore

/// The VM window for QEMU machines.
struct QEMUConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let session: QEMUSession
    let machineName: String

    @State private var keyboardFocused = false
    @State private var showingCDImporter = false
    @State private var confirmPowerOff = false
    @State private var showingHelp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    QEMUScreen(session: session)
                        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
                    banners
                    TerminalInputView(
                        isFocused: $keyboardFocused,
                        onText: { session.type($0) },
                        onBytes: { session.sendTerminalBytes($0) })
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }
                keyBar
            }
            .background(Color.black)
            .navigationTitle(machineName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    machineMenu
                }
            }
            .confirmationDialog("Turn off “\(machineName)”?", isPresented: $confirmPowerOff, titleVisibility: .visible) {
                Button("Shut Down (ACPI)") { session.shutDown() }
                Button("Power Off", role: .destructive) { session.powerOff() }
            } message: {
                Text("Shut Down asks the guest to turn off cleanly. Power Off stops it immediately, like pulling the plug.")
            }
            .fileImporter(isPresented: $showingCDImporter, allowedContentTypes: [.diskImage, .data, .item]) { result in
                if case let .success(url) = result {
                    model.attachCDROM(url, to: session.id)
                    session.changeCD(to: url)
                }
            }
            .sheet(isPresented: $showingHelp) { QEMUControlsHelp() }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if let message = session.statusMessage {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(message)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
            if case let .halted(reason) = session.state {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .padding(10)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            } else if session.state == .poweredOff {
                VStack(spacing: 6) {
                    Label("Machine powered off", systemImage: "power")
                    Text("QEMU can run once per app launch. Reopen PocketVM to start a QEMU machine again.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
            if let warning = session.warning {
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .padding(8)
                    .background(Color.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { session.warning = nil }
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
        .padding(.horizontal)
        .allowsHitTesting(session.warning != nil)
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key(keyboardFocused ? "⌨︎↓" : "⌨︎") { keyboardFocused.toggle() }
                key("Ctrl+Alt+Del") { session.sendCtrlAltDel() }
                key("esc") { session.press(["Escape"]) }
                key("tab") { session.press(["Tab"]) }
                modifier("ctrl", name: "ControlLeft")
                modifier("alt", name: "AltLeft")
                modifier("shift", name: "ShiftLeft")
                modifier("⊞", name: "MetaLeft")
                key("⊞ menu") { session.press(["MetaLeft"]) }
                key("↑") { session.press(["ArrowUp"]) }
                key("↓") { session.press(["ArrowDown"]) }
                key("←") { session.press(["ArrowLeft"]) }
                key("→") { session.press(["ArrowRight"]) }
                key("⏎") { session.press(["Enter"]) }
                key("del") { session.press(["Delete"]) }
                key("home") { session.press(["Home"]) }
                key("end") { session.press(["End"]) }
                key("pgup") { session.press(["PageUp"]) }
                key("pgdn") { session.press(["PageDown"]) }
                ForEach(1...12, id: \.self) { n in
                    key("F\(n)") { session.press(["F\(n)"]) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
        .disabled(!session.state.isActive)
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func modifier(_ title: String, name: String) -> some View {
        let active = session.activeModifiers.contains(name)
        return Button {
            session.toggleModifier(name)
        } label: {
            Text(title)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(active ? Color.accentColor : Color(white: 0.22), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var machineMenu: some View {
        Menu {
            if session.state.isActive {
                if session.state == .running {
                    Button { session.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                } else {
                    Button { session.resume() } label: { Label("Resume", systemImage: "play.fill") }
                }
                Button { session.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Button { session.sendCtrlAltDel() } label: { Label("Send Ctrl+Alt+Del", systemImage: "keyboard") }
                Divider()
                Button { showingCDImporter = true } label: { Label("Insert CD/DVD Image…", systemImage: "opticaldisc") }
                Button {
                    session.ejectCD()
                    model.detachCDROM(from: session.id)
                } label: { Label("Eject CD/DVD", systemImage: "eject") }
                Divider()
                Button { session.shutDown() } label: { Label("Shut Down (ACPI)", systemImage: "power.dotted") }
                Button(role: .destructive) { confirmPowerOff = true } label: { Label("Power Off…", systemImage: "power") }
            }
            Divider()
            Button { showingHelp = true } label: { Label("Touch Controls", systemImage: "hand.tap") }
        } label: {
            Label("Machine", systemImage: "ellipsis.circle")
        }
    }
}

struct QEMUControlsHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Touch") {
                    Label("Tap to click where you touch", systemImage: "hand.tap")
                    Label("Touch and hold, or tap with two fingers, to right-click", systemImage: "hand.tap.fill")
                    Label("Drag with one finger to drag", systemImage: "hand.draw")
                    Label("Drag with two fingers to scroll", systemImage: "arrow.up.and.down")
                }
                Section("Keyboard") {
                    Label("⌨︎ shows the keyboard; hardware keyboards work too", systemImage: "keyboard")
                    Label("ctrl / alt / shift / ⊞ stay pressed for the next key", systemImage: "command")
                    Text("Keys are sent with a US layout.")
                }
                Section("Windows 11") {
                    Text("PocketVM attaches an answer disk that skips the TPM, Secure Boot, RAM and CPU checks and allows a local account without network.")
                    Text("If the firmware shows “Press any key to boot from CD or DVD”, tap ⌨︎ and press a key quickly.")
                    Text("Without JIT the installation takes many hours. Use the JIT build on a sideloaded app for usable speed.")
                }
            }
            .navigationTitle("Touch Controls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
