import Foundation
import Observation
import VMCore
import WidgetKit

/// Identifies the machine whose console is shown full screen.
struct ConsoleTarget: Identifiable, Hashable {
    let id: UUID
}

/// App-wide state: the machine library and the running sessions.
@MainActor
@Observable
final class AppModel {
    private(set) var machines: [VMConfiguration] = []
    private(set) var sessions: [UUID: VMSession] = [:]
    private(set) var pcSessions: [UUID: PCSession] = [:]
    private(set) var qemuSessions: [UUID: QEMUSession] = [:]
    var selection: UUID?
    var consoleTarget: ConsoleTarget?
    var errorMessage: String?
    /// Shown while a long operation (copying a disk image…) runs.
    private(set) var busyMessage: String?

    let store: VMStore

    init() {
        if let standard = try? VMStore.standard() {
            store = standard
        } else {
            // Fall back to a temporary library rather than refusing to launch.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Machines")
            store = try! VMStore(rootURL: tmp)
            errorMessage = "The machine library could not be opened; using temporary storage."
        }
        var loaded = store.loadAll()
        if loaded.isEmpty {
            let demo = VMConfiguration(
                name: "Demo Monitor",
                osType: .builtInMonitor,
                notes: "Built-in firmware. Create a PC machine and attach an ISO to install Windows or Linux.")
            try? store.save(demo)
            loaded = [demo]
        }
        machines = loaded
        publishCatalog()
    }

    func machine(_ id: UUID) -> VMConfiguration? {
        machines.first { $0.id == id }
    }

    func state(for id: UUID) -> VMEngine.State {
        if let pc = pcSessions[id] { return pc.state }
        if let qemu = qemuSessions[id] { return qemu.state }
        return sessions[id]?.state ?? .stopped
    }

    func isActive(_ id: UUID) -> Bool {
        state(for: id).isActive
    }

    // MARK: Library

    @discardableResult
    func create(_ config: VMConfiguration, kernel: URL? = nil, cdrom: URL? = nil, diskSizeGB: Int = 0) -> VMConfiguration? {
        var config = config
        do {
            try store.save(config)
            if let kernel {
                try store.importKernel(from: kernel, into: &config)
            }
            if let cdrom {
                try store.attachCDROM(from: cdrom, into: &config)
            }
            if diskSizeGB > 0 {
                try store.createHardDisk(sizeGB: diskSizeGB, into: &config)
            }
            machines.append(config)
            publishCatalog()
            selection = config.id
            return config
        } catch {
            try? store.delete(config.id)
            report(error)
            return nil
        }
    }

    func update(_ config: VMConfiguration) {
        do {
            try store.save(config)
            replace(config)
        } catch {
            report(error)
        }
    }

    func clone(_ id: UUID) {
        guard let config = machine(id) else { return }
        runBusy("Cloning “\(config.name)”…") { [store] in
            try store.clone(config, name: "\(config.name) Clone")
        } done: { copy in
            self.machines.append(copy)
            self.publishCatalog()
            self.selection = copy.id
        }
    }

    func delete(_ id: UUID) {
        sessions[id]?.powerOff()
        sessions[id] = nil
        pcSessions[id]?.terminate()
        pcSessions[id] = nil
        if let qemu = qemuSessions[id], qemu.state.isActive { qemu.powerOff() }
        qemuSessions[id] = nil
        if consoleTarget?.id == id { consoleTarget = nil }
        do {
            try store.delete(id)
            machines.removeAll { $0.id == id }
            publishCatalog()
            if selection == id { selection = nil }
        } catch {
            report(error)
        }
    }

    // MARK: Storage

    func importKernel(_ url: URL, into id: UUID) {
        mutate(id) { store, config in try store.importKernel(from: url, into: &config) }
    }

    func removeKernel(from id: UUID) {
        mutate(id) { store, config in try store.removeKernel(from: &config) }
    }

    func attachCDROM(_ url: URL, to id: UUID) {
        mutate(id) { store, config in try store.attachCDROM(from: url, into: &config) }
    }

    func detachCDROM(from id: UUID) {
        mutate(id) { store, config in try store.ejectCDROM(from: &config) }
    }

    func createHardDisk(sizeGB: Int, for id: UUID) {
        mutate(id) { store, config in try store.createHardDisk(sizeGB: sizeGB, into: &config) }
    }

    func importHardDisk(_ url: URL, into id: UUID) {
        guard let config = machine(id) else { return }
        runBusy("Copying hard disk image…") { [store] in
            var copy = config
            try store.importHardDisk(from: url, into: &copy)
            return copy
        } done: { self.replace($0) }
    }

    func removeHardDisk(from id: UUID) {
        mutate(id) { store, config in try store.removeHardDisk(from: &config) }
    }

    func importFloppy(_ url: URL, into id: UUID) {
        mutate(id) { store, config in try store.importFloppy(from: url, into: &config) }
    }

    func removeFloppy(from id: UUID) {
        mutate(id) { store, config in try store.removeFloppy(from: &config) }
    }

    func discardSavedState(of id: UUID) {
        mutate(id) { store, config in try store.discardSavedState(of: &config) }
    }

    // MARK: Running

    /// Opens the machine's window, starting it if needed (Home Screen
    /// widgets, shortcuts and the Start button all end up here).
    func launch(_ id: UUID) {
        guard machine(id) != nil else {
            errorMessage = "This virtual machine no longer exists."
            return
        }
        selection = id
        if isActive(id) {
            consoleTarget = ConsoleTarget(id: id)
        } else {
            start(id)
        }
    }

    /// Starts a machine and shows its window.
    func start(_ id: UUID, from snapshot: SnapshotInfo? = nil) {
        guard let config = machine(id) else { return }
        switch config.platform {
        case .riscv:
            if startRISCV(config, snapshot: snapshot) != nil {
                consoleTarget = ConsoleTarget(id: id)
            }
        case .pc:
            if startPC(config) != nil {
                consoleTarget = ConsoleTarget(id: id)
            }
        case .qemu:
            if startQEMU(config) != nil {
                consoleTarget = ConsoleTarget(id: id)
            }
        }
    }

    @discardableResult
    private func startRISCV(_ config: VMConfiguration, snapshot: SnapshotInfo?) -> VMSession? {
        let id = config.id
        if let existing = sessions[id], existing.state.isActive, snapshot == nil {
            return existing
        }
        sessions[id]?.powerOff()
        do {
            let engine = try store.makeEngine(for: config)
            let session = VMSession(id: id, engine: engine)
            let data = try snapshot.map { try store.snapshotData($0, of: config) }
            try session.powerOn(snapshot: data)
            sessions[id] = session
            markStarted(config)
            return session
        } catch {
            report(error)
            return nil
        }
    }

    @discardableResult
    private func startPC(_ config: VMConfiguration) -> PCSession? {
        let id = config.id
        if let existing = pcSessions[id], existing.state.isActive {
            return existing
        }
        var config = config
        var accessed: [URL] = []
        do {
            let cdrom = try store.resolveCDROM(for: &config)
            if let cdrom {
                if cdrom.startAccessingSecurityScopedResource() { accessed.append(cdrom) }
            }
            let plan = try store.makePCBootPlan(for: config, cdromURL: cdrom, restoreState: true)
            let session = PCSession(id: id)
            session.onStateRestored = { [weak self] in
                // The saved state is consumed once the machine runs again.
                self?.mutate(id) { store, config in try store.discardSavedState(of: &config) }
            }
            session.onRestoreFailed = { [weak self] message in
                self?.errorMessage = "The saved state could not be restored (\(message)). Discard it in the machine details to start fresh."
            }
            try session.start(plan: plan, accessing: accessed)
            pcSessions[id] = session
            markStarted(config)
            return session
        } catch {
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            report(error)
            return nil
        }
    }

    @discardableResult
    private func startQEMU(_ config: VMConfiguration) -> QEMUSession? {
        let id = config.id
        if let existing = qemuSessions[id], existing.state.isActive {
            return existing
        }
        var config = config
        let runtime = QEMURuntime.shared
        do {
            if let problem = runtime.startProblem(for: config.osType.qemuArchitecture) {
                throw VMError.invalidImage(problem)
            }
            let plan = try store.makeQEMULaunchPlan(
                for: &config,
                resourceDirectory: runtime.resourceDirectory,
                socketDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("q", isDirectory: true),
                splitWX: runtime.flavor == .jit)
            let session = QEMUSession(id: id)
            do {
                try session.start(plan: plan)
            } catch {
                plan.accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                throw error
            }
            qemuSessions[id] = session
            markStarted(config)
            return session
        } catch {
            report(error)
            return nil
        }
    }

    /// Problem that prevents QEMU machines from starting in this app run.
    func qemuEngineProblem(for config: VMConfiguration) -> String? {
        guard config.platform == .qemu else { return nil }
        if let session = qemuSessions[config.id], session.state.isActive { return nil }
        return QEMURuntime.shared.startProblem(for: config.osType.qemuArchitecture)
    }

    func resetEFIVariables(of id: UUID) {
        do {
            try store.resetEFIVariables(for: id)
        } catch {
            report(error)
        }
    }

    func saveState(of id: UUID) async {
        guard let session = pcSessions[id], session.state.isActive else { return }
        do {
            let temporary = try await session.saveStateAndPowerOff()
            guard var config = machine(id) else { return }
            try store.commitSavedState(from: temporary, into: &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    func powerOffPC(_ id: UUID) async {
        await pcSessions[id]?.powerOff()
    }

    // Engine-independent controls used by the details pane.

    func pause(_ id: UUID) {
        if let pc = pcSessions[id] { pc.pause() } else if let q = qemuSessions[id] { q.pause() } else { sessions[id]?.pause() }
    }

    func resume(_ id: UUID) {
        if let pc = pcSessions[id] { pc.resume() } else if let q = qemuSessions[id] { q.resume() } else { sessions[id]?.resume() }
    }

    func reset(_ id: UUID) {
        if let pc = pcSessions[id] { pc.reset() } else if let q = qemuSessions[id] { q.reset() } else { sessions[id]?.reset() }
    }

    func powerOff(_ id: UUID) {
        if let q = qemuSessions[id] {
            q.powerOff()
        } else if pcSessions[id] != nil {
            Task { await powerOffPC(id) }
        } else {
            sessions[id]?.powerOff()
        }
    }

    func speedDescription(for id: UUID) -> String? {
        if let pc = pcSessions[id], pc.instructionsPerSecond > 0 { return pc.speedDescription }
        if let session = sessions[id], session.instructionsPerSecond > 0 { return session.mipsDescription }
        return nil
    }

    func insertCD(_ url: URL, into id: UUID) {
        guard let session = pcSessions[id] else { return }
        attachCDROM(url, to: id)
        guard var config = machine(id), let resolved = try? store.resolveCDROM(for: &config) else { return }
        _ = resolved.startAccessingSecurityScopedResource()
        session.insertCD(url: resolved, size: config.cdromByteCount ?? 0)
    }

    func ejectCD(from id: UUID) {
        pcSessions[id]?.ejectCD()
        detachCDROM(from: id)
    }

    func takeSnapshot(of id: UUID, named name: String) async {
        guard let session = sessions[id], session.state.isActive else { return }
        let wasRunning = session.state == .running
        session.pause()
        let data = await session.snapshot()
        if wasRunning { session.resume() }
        guard var config = machine(id) else { return }
        do {
            _ = try store.addSnapshot(data, named: name, to: &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    func deleteSnapshot(_ info: SnapshotInfo, of id: UUID) {
        mutate(id) { store, config in try store.deleteSnapshot(info, from: &config) }
    }

    // MARK: Helpers

    private func markStarted(_ config: VMConfiguration) {
        var config = config
        config.lastRunAt = Date()
        update(config)
    }

    private func mutate(_ id: UUID, _ body: (VMStore, inout VMConfiguration) throws -> Void) {
        guard var config = machine(id) else { return }
        do {
            try body(store, &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    /// Runs slow file work off the main thread while showing a message.
    private func runBusy<T: Sendable>(
        _ message: String,
        work: @escaping @Sendable () throws -> T,
        done: @escaping (T) -> Void
    ) {
        busyMessage = message
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            busyMessage = nil
            switch result {
            case let .success(value): done(value)
            case let .failure(error): report(error)
            }
        }
    }

    private func replace(_ config: VMConfiguration) {
        if let index = machines.firstIndex(where: { $0.id == config.id }) {
            machines[index] = config
        }
        publishCatalog()
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Keeps the Home Screen widget and Shortcuts in sync with the library.
    private func publishCatalog() {
        let entries = machines.map(MachineCatalog.Entry.init)
        guard entries != MachineCatalog.read() else { return }
        MachineCatalog.write(entries)
        WidgetCenter.shared.reloadAllTimelines()
        PocketVMShortcuts.updateAppShortcutParameters()
    }
}
