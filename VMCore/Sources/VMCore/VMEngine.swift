import Foundation

/// Runs an `RV32Machine` on a dedicated background thread and exposes a
/// thread-safe control surface (start / pause / reset / power off, console
/// input and output) to the UI.
public final class VMEngine: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case running
        case paused
        case poweredOff
        case halted(String)

        public var isActive: Bool { self == .running || self == .paused }
    }

    /// Loads the boot image into a freshly reset machine.
    public typealias BootLoader = (RV32Machine) throws -> Void

    public let machine: RV32Machine
    private let bootLoader: BootLoader

    private let lock = NSLock()
    private var _state: State = .stopped
    private var pauseRequested = false
    private var stopRequested = false
    private var pendingInput: [UInt8] = []
    private var pendingOutput: [UInt8] = []
    private var commands: [(RV32Machine) -> Void] = []
    private var thread: Thread?
    private var _instructionsPerSecond: Double = 0

    /// Instructions executed per host slice.
    public var sliceSize = 250_000
    /// Upper bound for the console output kept while nobody drains it.
    public var maxPendingOutput = 1 << 20

    public init(machine: RV32Machine, bootLoader: @escaping BootLoader) {
        self.machine = machine
        self.bootLoader = bootLoader
    }

    public var state: State {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    /// Recent guest speed in instructions per second.
    public var instructionsPerSecond: Double {
        lock.lock(); defer { lock.unlock() }
        return _instructionsPerSecond
    }

    // MARK: Control

    /// Boots the machine from its boot image and starts running.
    public func powerOn() throws {
        try withStoppedMachine { try bootLoader($0) }
        startThread()
    }

    /// Restores a snapshot and starts running from it.
    public func powerOn(restoring snapshot: Data) throws {
        try withStoppedMachine { m in
            m.reset(clearMemory: false)
            try m.restore(from: snapshot)
        }
        startThread()
    }

    public func pause() {
        lock.lock()
        if _state == .running { pauseRequested = true; _state = .paused }
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        if _state == .paused { pauseRequested = false; _state = .running }
        lock.unlock()
    }

    /// Hard reset: reloads the boot image and keeps running.
    public func reset() {
        perform { [bootLoader] m in
            do { try bootLoader(m) } catch { m.reset() }
        }
    }

    /// Pulls the virtual power cord.
    public func powerOff() {
        lock.lock()
        stopRequested = true
        let t = thread
        lock.unlock()
        if t == nil { setState(.poweredOff) }
        waitForThreadExit()
    }

    /// Graceful shutdown for Linux guests: types `poweroff` + Return on the
    /// serial console (this board has no ACPI power button).
    public func requestGuestShutdown() {
        sendInput(Array("poweroff\r".utf8))
    }

    // MARK: Console

    public func sendInput(_ bytes: [UInt8]) {
        lock.lock()
        pendingInput.append(contentsOf: bytes)
        lock.unlock()
    }

    public func sendInput(_ string: String) {
        sendInput(Array(string.utf8))
    }

    /// Returns console output produced since the previous call.
    public func drainOutput() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        let out = pendingOutput
        pendingOutput.removeAll(keepingCapacity: true)
        return out
    }

    /// Runs `block` on the machine at a safe point between instruction slices
    /// (or immediately if the engine is not running).
    public func perform(_ block: @escaping (RV32Machine) -> Void) {
        lock.lock()
        if thread == nil {
            lock.unlock()
            block(machine)
            return
        }
        commands.append(block)
        lock.unlock()
    }

    /// Captures the machine state; the completion runs on the engine thread.
    public func snapshot(_ completion: @escaping (Data) -> Void) {
        perform { m in completion(m.makeSnapshot()) }
    }

    // MARK: Thread

    private func withStoppedMachine(_ body: (RV32Machine) throws -> Void) throws {
        lock.lock()
        let running = thread != nil
        lock.unlock()
        if running {
            lock.lock(); stopRequested = true; lock.unlock()
            waitForThreadExit()
        }
        try body(machine)
    }

    private func startThread() {
        lock.lock()
        stopRequested = false
        pauseRequested = false
        pendingOutput.removeAll()
        _state = .running
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "PocketVM guest CPU"
        t.qualityOfService = .userInitiated
        t.stackSize = 1 << 20
        thread = t
        lock.unlock()
        t.start()
    }

    private func waitForThreadExit() {
        while true {
            lock.lock()
            let alive = thread != nil
            lock.unlock()
            if !alive { return }
            usleep(1000)
        }
    }

    private func setState(_ s: State) {
        lock.lock(); _state = s; lock.unlock()
    }

    private static func nowMicroseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }

    private func runLoop() {
        var last = Self.nowMicroseconds()
        var statsStart = last
        var statsInstructions: UInt64 = 0
        var finalState: State = .stopped

        loop: while true {
            // Exchange I/O and run queued commands under the lock.
            lock.lock()
            if stopRequested {
                lock.unlock()
                finalState = .poweredOff
                break loop
            }
            let paused = pauseRequested
            if !pendingInput.isEmpty {
                machine.enqueueInput(pendingInput)
                pendingInput.removeAll(keepingCapacity: true)
            }
            let queued = commands
            commands.removeAll()
            lock.unlock()

            for command in queued { command(machine) }

            if paused {
                usleep(10_000)
                last = Self.nowMicroseconds()
                continue
            }

            let now = Self.nowMicroseconds()
            // Clamp so a long host stall doesn't fire a burst of timer ticks.
            let elapsed = min(now &- last, 50_000)
            last = now

            let cycleBefore = machine.cycle
            let result = machine.step(elapsedMicroseconds: elapsed, maxInstructions: sliceSize)
            statsInstructions &+= machine.cycle &- cycleBefore

            let output = machine.takeOutput()
            if !output.isEmpty {
                lock.lock()
                pendingOutput.append(contentsOf: output)
                if pendingOutput.count > maxPendingOutput {
                    pendingOutput.removeFirst(pendingOutput.count - maxPendingOutput)
                }
                lock.unlock()
            }

            if now &- statsStart >= 500_000 {
                let seconds = Double(now &- statsStart) / 1_000_000
                let ips = Double(statsInstructions) / seconds
                lock.lock(); _instructionsPerSecond = ips; lock.unlock()
                statsStart = now
                statsInstructions = 0
            }

            switch result {
            case .ok:
                continue
            case .waitingForInterrupt:
                lock.lock()
                let hasInput = !pendingInput.isEmpty
                lock.unlock()
                if !hasInput { usleep(1000) }
            case .powerOff:
                finalState = .poweredOff
                break loop
            case .reboot:
                do {
                    try bootLoader(machine)
                } catch {
                    finalState = .halted(error.localizedDescription)
                    break loop
                }
            case let .halted(reason):
                finalState = .halted(reason)
                break loop
            }
        }

        // Flush whatever the guest printed last.
        let output = machine.takeOutput()
        lock.lock()
        pendingOutput.append(contentsOf: output)
        _state = finalState
        _instructionsPerSecond = 0
        thread = nil
        lock.unlock()
    }
}
