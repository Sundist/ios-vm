import SwiftUI
import UIKit
import VMCore

/// Full-screen serial console for a running machine (the VM "window").
struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let session: VMSession
    let machineName: String

    @State private var keyboardFocused = true
    @State private var controlLatched = false
    @State private var showingSnapshotPrompt = false
    @State private var snapshotName = ""
    @AppStorage("consoleFontSize") private var fontSize: Double = 12

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                terminal
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
            .alert("Take Snapshot", isPresented: $showingSnapshotPrompt) {
                TextField("Name", text: $snapshotName)
                Button("Cancel", role: .cancel) {}
                Button("Take") {
                    let name = snapshotName.isEmpty ? "Snapshot" : snapshotName
                    Task { await model.takeSnapshot(of: session.id, named: name) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Pieces

    private var statusBar: some View {
        HStack {
            StateLabel(state: session.state)
            Spacer()
            if session.state == .running {
                Text(session.mipsDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.1))
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.terminalText.isEmpty ? " " : session.terminalText)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(Color(red: 0.75, green: 1.0, blue: 0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if case let .halted(reason) = session.state {
                        Text("\n*** Guest halted: \(reason)")
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(.red)
                    } else if session.state == .poweredOff {
                        Text("\n*** Machine powered off")
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: session.terminalText) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .contentShape(Rectangle())
            .onTapGesture { keyboardFocused = true }
            .background {
                TerminalInputView(
                    isFocused: $keyboardFocused,
                    onText: { handleTyped($0) },
                    onBytes: { session.send($0) })
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
        }
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc") { session.send([0x1b]) }
                key("tab") { session.send([0x09]) }
                Button {
                    controlLatched.toggle()
                } label: {
                    Text("ctrl")
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(controlLatched ? Color.accentColor : Color(white: 0.22),
                                    in: RoundedRectangle(cornerRadius: 6))
                }
                key("^C") { session.send([0x03]) }
                key("^D") { session.send([0x04]) }
                key("↑") { session.send(TerminalKeys.up) }
                key("↓") { session.send(TerminalKeys.down) }
                key("←") { session.send(TerminalKeys.left) }
                key("→") { session.send(TerminalKeys.right) }
                key("|") { session.send("|") }
                key("/") { session.send("/") }
                key("-") { session.send("-") }
                key("~") { session.send("~") }
                key(keyboardFocused ? "⌨︎↓" : "⌨︎") { keyboardFocused.toggle() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.12))
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(white: 0.22), in: RoundedRectangle(cornerRadius: 6))
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
                Button {
                    snapshotName = "Snapshot \((model.machine(session.id)?.snapshots.count ?? 0) + 1)"
                    showingSnapshotPrompt = true
                } label: { Label("Take Snapshot…", systemImage: "camera") }
                Button { session.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
                Button { session.requestShutdown() } label: { Label("Shut Down (poweroff)", systemImage: "power.dotted") }
                Button(role: .destructive) { session.powerOff() } label: { Label("Power Off", systemImage: "power") }
            } else {
                Button {
                    model.start(session.id)
                    dismiss()
                } label: { Label("Start Again", systemImage: "play.fill") }
            }
            Divider()
            Button { session.clearConsole() } label: { Label("Clear Console", systemImage: "eraser") }
            Button {
                UIPasteboard.general.string = session.terminalText
            } label: { Label("Copy Console Text", systemImage: "doc.on.doc") }
            Button {
                if let text = UIPasteboard.general.string { handleTyped(text) }
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Menu {
                Button("Smaller") { fontSize = max(8, fontSize - 1) }
                Button("Larger") { fontSize = min(24, fontSize + 1) }
            } label: { Label("Font Size", systemImage: "textformat.size") }
        } label: {
            Label("Machine", systemImage: "ellipsis.circle")
        }
    }

    private func handleTyped(_ text: String) {
        if controlLatched, let byte = TerminalKeys.control(text) {
            controlLatched = false
            session.send([byte])
            return
        }
        controlLatched = false
        session.send(TerminalKeys.bytes(for: text))
    }
}
