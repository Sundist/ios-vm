import SwiftUI
import UniformTypeIdentifiers
import VMCore
import WebKit

/// Hosts the session's web view (the PC screen).
struct PCWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// The VM window for x86 machines: screen, trackpad, keyboard and key bar.
struct PCConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let session: PCSession
    let machineName: String

    @State private var confirmPowerOff = false
    @State private var showingCDImporter = false
    @State private var showingHelp = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                    PCWebView(webView: session.webView)
                        .ignoresSafeArea(.container, edges: [.bottom, .horizontal])
                    banners
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
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(machineName).font(.headline)
                        if session.state == .running && session.instructionsPerSecond > 0 {
                            Text(session.speedDescription)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    machineMenu
                }
            }
            .confirmationDialog("Power off “\(machineName)”?", isPresented: $confirmPowerOff, titleVisibility: .visible) {
                Button("Save State and Close") {
                    Task {
                        await model.saveState(of: session.id)
                        dismiss()
                    }
                }
                Button("Power Off", role: .destructive) {
                    Task { await model.powerOffPC(session.id) }
                }
            } message: {
                Text("Saving the state lets you continue exactly where you left off. Powering off is like pulling the plug; disk contents are kept.")
            }
            .fileImporter(isPresented: $showingCDImporter, allowedContentTypes: [.diskImage, .data, .item]) { result in
                if case let .success(url) = result {
                    model.insertCD(url, into: session.id)
                }
            }
            .sheet(isPresented: $showingHelp) { PCControlsHelp() }
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
                Label("Machine powered off", systemImage: "power")
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
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("Ctrl+Alt+Del", wide: true) { session.sendCtrlAltDel() }
                key("esc") { session.press(["Escape"]) }
                key("tab") { session.press(["Tab"]) }
                modifier("ctrl", name: "ControlLeft")
                modifier("alt", name: "AltLeft")
                modifier("shift", name: "ShiftLeft")
                key("⊞") { session.press(["MetaLeft"]) }
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

    private func key(_ title: String, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, wide ? 10 : 12).padding(.vertical, 8)
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
                Button { model.ejectCD(from: session.id) } label: { Label("Eject CD/DVD", systemImage: "eject") }
                Divider()
                Button {
                    Task {
                        await model.saveState(of: session.id)
                        dismiss()
                    }
                } label: { Label("Save State and Close", systemImage: "square.and.arrow.down") }
                Button(role: .destructive) { confirmPowerOff = true } label: { Label("Power Off…", systemImage: "power") }
            } else {
                Button {
                    model.start(session.id)
                } label: { Label("Start Again", systemImage: "play.fill") }
            }
            Divider()
            Button { showingHelp = true } label: { Label("Touch Controls", systemImage: "hand.tap") }
        } label: {
            Label("Machine", systemImage: "ellipsis.circle")
        }
    }
}

struct PCControlsHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Mouse (trackpad)") {
                    Label("Drag one finger to move the pointer", systemImage: "hand.point.up.left")
                    Label("Tap to click, tap twice to double-click", systemImage: "hand.tap")
                    Label("Tap, then touch again and drag to drag", systemImage: "hand.draw")
                    Label("Two-finger tap to right-click", systemImage: "hand.tap.fill")
                    Label("Two-finger drag to scroll", systemImage: "arrow.up.and.down")
                }
                Section("Keyboard") {
                    Label("Tap ⌨︎ in the bottom-right corner of the screen to show the keyboard", systemImage: "keyboard")
                    Label("ctrl / alt / shift stay pressed for the next key (e.g. ctrl, then c)", systemImage: "command")
                    Label("Hardware keyboards work directly once the screen has focus", systemImage: "keyboard.badge.ellipsis")
                }
                Section("Windows") {
                    Text("Windows 2000/XP setup: press F5 when “Press F6 if you need to install a third party SCSI…” appears and choose “Standard PC”.")
                    Text("Only 32-bit Windows versions can run; Windows 10/11 64-bit cannot.")
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
