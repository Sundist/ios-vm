import Foundation
import Observation
import VMCore

/// UI-facing wrapper around a running `VMEngine`: polls console output into a
/// terminal model and mirrors the engine state for SwiftUI.
@MainActor
@Observable
final class VMSession: Identifiable {
    let id: UUID
    private(set) var terminalText = ""
    private(set) var state: VMEngine.State = .stopped
    private(set) var instructionsPerSecond: Double = 0

    @ObservationIgnored let engine: VMEngine
    @ObservationIgnored private var terminal = TerminalBuffer(maxLines: 1000)
    @ObservationIgnored private var timer: Timer?

    init(id: UUID, engine: VMEngine) {
        self.id = id
        self.engine = engine
    }

    var mipsDescription: String {
        String(format: "%.1f MIPS", instructionsPerSecond / 1_000_000)
    }

    // MARK: Power

    func powerOn(snapshot: Data? = nil) throws {
        terminal.clear()
        terminalText = ""
        if let snapshot {
            try engine.powerOn(restoring: snapshot)
        } else {
            try engine.powerOn()
        }
        state = engine.state
        startPolling()
    }

    func pause() { engine.pause(); poll() }
    func resume() { engine.resume(); poll() }

    func reset() {
        engine.reset()
        terminal.clear()
        terminalText = ""
    }

    /// Graceful shutdown request (types `poweroff` into the guest shell).
    func requestShutdown() { engine.requestGuestShutdown() }

    /// Hard power off.
    func powerOff() {
        engine.powerOff()
        poll()
    }

    // MARK: Console

    func send(_ text: String) { engine.sendInput(text) }
    func send(_ bytes: [UInt8]) { engine.sendInput(bytes) }

    func clearConsole() {
        terminal.clear()
        terminalText = ""
    }

    func snapshot() async -> Data {
        await withCheckedContinuation { continuation in
            engine.snapshot { data in continuation.resume(returning: data) }
        }
    }

    // MARK: Polling

    private func startPolling() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let bytes = engine.drainOutput()
        if !bytes.isEmpty {
            terminal.feed(bytes)
            terminalText = terminal.text
        }
        let newState = engine.state
        if newState != state { state = newState }
        let ips = engine.instructionsPerSecond
        if abs(ips - instructionsPerSecond) > 50_000 || (ips == 0) != (instructionsPerSecond == 0) {
            instructionsPerSecond = ips
        }
        if !newState.isActive {
            timer?.invalidate()
            timer = nil
        }
    }
}
