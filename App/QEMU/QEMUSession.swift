import Foundation
import Observation
import VMCore

/// A running QEMU machine: QEMU thread + QMP control + VNC screen/input.
@MainActor
@Observable
final class QEMUSession: Identifiable {
    let id: UUID
    private(set) var state: VMEngine.State = .stopped
    private(set) var statusMessage: String?
    private(set) var screenSize: CGSize = .zero
    private(set) var activeModifiers: Set<String> = []
    var warning: String?

    @ObservationIgnored private(set) var rfb: RFBClient?
    @ObservationIgnored private var qmp: QMPClient?
    @ObservationIgnored private var plan: QEMULaunchPlan?
    @ObservationIgnored private var buttons: UInt8 = 0
    @ObservationIgnored private var pointer: (x: Int, y: Int) = (0, 0)

    init(id: UUID) {
        self.id = id
    }

    // MARK: Power

    func start(plan: QEMULaunchPlan) throws {
        self.plan = plan
        statusMessage = "Starting QEMU…"
        try QEMURuntime.shared.launch(plan) { [weak self] status in
            Task { @MainActor in self?.qemuExited(status: status) }
        }
        state = .running
        Task { await connectChannels(plan) }
    }

    func pause() { qmp?.execute("stop") }
    func resume() { qmp?.execute("cont") }
    func reset() { qmp?.execute("system_reset") }

    /// ACPI power button: Windows/Linux shut down cleanly.
    func shutDown() {
        qmp?.execute("system_powerdown")
        warning = "Shutdown requested. The guest decides when to turn off."
    }

    /// Pulls the plug. Disk writes already handed to QEMU are kept.
    func powerOff() {
        if let qmp {
            qmp.execute("quit")
        } else {
            qemuExited(status: 0)
        }
    }

    // MARK: CD/DVD

    func changeCD(to url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        plan?.accessedURLs.append(url)
        qmp?.execute("blockdev-change-medium", arguments: ["id": "cddev", "filename": url.path, "format": "raw"]) { [weak self] result in
            if case let .failure(error) = result {
                Task { @MainActor in self?.warning = "Could not insert the image: \(error.localizedDescription)" }
            }
        }
    }

    func ejectCD() {
        qmp?.execute("eject", arguments: ["id": "cddev", "force": true])
    }

    // MARK: Keyboard

    func type(_ text: String) {
        guard let rfb else { return }
        for character in text {
            guard let entry = GuestKey.forCharacter(character) else { continue }
            let latched = takeLatchedModifiers()
            let shift = entry.shift && !latched.contains("ShiftLeft")
            let modifiers = latched + (shift ? ["ShiftLeft"] : [])
            press(entry.code, modifiers: modifiers, rfb: rfb)
        }
    }

    /// Presses named keys (see `GuestKey.named`) together, e.g. Ctrl+Alt+Del.
    func press(_ names: [String]) {
        guard let rfb else { return }
        let codes = names.compactMap { GuestKey.named[$0] }
        guard let last = codes.last else { return }
        let latched = takeLatchedModifiers().filter { !names.contains($0) }
        let modifierCodes = latched.compactMap { GuestKey.named[$0] } + codes.dropLast()
        modifierCodes.forEach { rfb.sendKey(keysym: $0.keysym, scancode: $0.scancode, down: true) }
        rfb.sendKey(keysym: last.keysym, scancode: last.scancode, down: true)
        rfb.sendKey(keysym: last.keysym, scancode: last.scancode, down: false)
        modifierCodes.reversed().forEach { rfb.sendKey(keysym: $0.keysym, scancode: $0.scancode, down: false) }
    }

    func sendCtrlAltDel() { press(["ControlLeft", "AltLeft", "Delete"]) }

    func toggleModifier(_ name: String) {
        if activeModifiers.contains(name) { activeModifiers.remove(name) } else { activeModifiers.insert(name) }
    }

    /// Bytes from the terminal-style key input (backspace, arrows, ctrl codes).
    func sendTerminalBytes(_ bytes: [UInt8]) {
        switch bytes {
        case [0x7f], [0x08]: press(["Backspace"])
        case [0x1b]: press(["Escape"])
        case [0x09]: press(["Tab"])
        case [0x1b, 0x5b, 0x41]: press(["ArrowUp"])
        case [0x1b, 0x5b, 0x42]: press(["ArrowDown"])
        case [0x1b, 0x5b, 0x43]: press(["ArrowRight"])
        case [0x1b, 0x5b, 0x44]: press(["ArrowLeft"])
        default:
            if bytes.count == 1, bytes[0] >= 1, bytes[0] <= 26 {
                // Ctrl+letter from a hardware keyboard.
                let letter = Character(Unicode.Scalar(bytes[0] + 0x60))
                if let entry = GuestKey.forCharacter(letter), let rfb {
                    press(entry.code, modifiers: ["ControlLeft"], rfb: rfb)
                }
            } else {
                type(String(decoding: bytes, as: UTF8.self))
            }
        }
    }

    private func takeLatchedModifiers() -> [String] {
        let order = ["ControlLeft", "AltLeft", "ShiftLeft", "MetaLeft"]
        let latched = order.filter { activeModifiers.contains($0) }
        if !latched.isEmpty { activeModifiers.removeAll() }
        return latched
    }

    private func press(_ code: GuestKey.Code, modifiers: [String], rfb: RFBClient) {
        let mods = modifiers.compactMap { GuestKey.named[$0] }
        mods.forEach { rfb.sendKey(keysym: $0.keysym, scancode: $0.scancode, down: true) }
        rfb.sendKey(keysym: code.keysym, scancode: code.scancode, down: true)
        rfb.sendKey(keysym: code.keysym, scancode: code.scancode, down: false)
        mods.reversed().forEach { rfb.sendKey(keysym: $0.keysym, scancode: $0.scancode, down: false) }
    }

    // MARK: Pointer (absolute, USB tablet)

    func pointerMove(to x: Int, _ y: Int) {
        pointer = (x, y)
        rfb?.sendPointer(x: x, y: y, buttons: buttons)
    }

    func pointerButton(_ mask: UInt8, down: Bool) {
        if down { buttons |= mask } else { buttons &= ~mask }
        rfb?.sendPointer(x: pointer.x, y: pointer.y, buttons: buttons)
    }

    func click(at x: Int, _ y: Int, button: UInt8 = 1) {
        pointerMove(to: x, y)
        pointerButton(button, down: true)
        pointerButton(button, down: false)
    }

    /// Positive = scroll up.
    func scroll(steps: Int) {
        let mask: UInt8 = steps > 0 ? 8 : 16
        for _ in 0..<abs(steps) {
            rfb?.sendPointer(x: pointer.x, y: pointer.y, buttons: buttons | mask)
            rfb?.sendPointer(x: pointer.x, y: pointer.y, buttons: buttons)
        }
    }

    // MARK: Channels

    private func connectChannels(_ plan: QEMULaunchPlan) async {
        // QEMU creates the sockets during qemu_init(), which can take a few
        // seconds with the interpreter.
        guard let qmpSocket = await waitForSocket(plan.qmpSocket),
              let vncSocket = await waitForSocket(plan.vncSocket) else {
            if state.isActive {
                warning = "Could not connect to QEMU's control channels."
            }
            return
        }
        let qmp = QMPClient(socket: qmpSocket)
        qmp.onEvent = { [weak self] event, _ in
            Task { @MainActor in self?.handle(event: event) }
        }
        qmp.start()
        self.qmp = qmp

        let rfb = RFBClient(socket: vncSocket)
        let delegate = RFBDelegate(session: self)
        rfb.delegate = delegate
        rfbDelegate = delegate
        rfb.start()
        self.rfb = rfb
    }

    @ObservationIgnored private var rfbDelegate: RFBDelegate?

    private func waitForSocket(_ url: URL) async -> UnixSocket? {
        for _ in 0..<600 {   // up to 60 s
            if !state.isActive { return nil }
            // Connect by file name: QEMURuntime made the socket directory the
            // working directory, which keeps the path under 104 bytes.
            if FileManager.default.fileExists(atPath: url.path),
               let socket = try? UnixSocket.connect(path: url.lastPathComponent) {
                return socket
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    fileprivate func screenDidConnect() {
        statusMessage = nil
    }

    fileprivate func screenDidResize(_ size: CGSize) {
        screenSize = size
    }

    private func handle(event: String) {
        switch event {
        case "STOP": if state.isActive { state = .paused }
        case "RESUME": if state.isActive { state = .running }
        case "RESET": warning = nil
        default: break
        }
    }

    private func qemuExited(status: Int32) {
        guard state.isActive || state == .stopped else { return }
        rfb?.disconnect()
        qmp?.close()
        rfb = nil
        qmp = nil
        plan?.accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        statusMessage = nil
        state = status == 0 ? .poweredOff : .halted("QEMU stopped with an error (status \(status)). Check the machine settings and the ISO.")
    }
}

/// Forwards VNC client callbacks (background thread) to the main actor.
private final class RFBDelegate: RFBClientDelegate, @unchecked Sendable {
    weak var session: QEMUSession?

    init(session: QEMUSession) { self.session = session }

    func rfbClientDidConnect(_ client: RFBClient) {
        Task { @MainActor [weak self] in self?.session?.screenDidConnect() }
    }

    func rfbClient(_ client: RFBClient, didResizeTo width: Int, height: Int) {
        Task { @MainActor [weak self] in self?.session?.screenDidResize(CGSize(width: width, height: height)) }
    }

    func rfbClientDidUpdate(_ client: RFBClient) {}

    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?) {}
}
