import Foundation
import Observation
import VMCore

/// App-wide state: the machine library and the running sessions.
@MainActor
@Observable
final class AppModel {
    private(set) var machines: [VMConfiguration] = []
    private(set) var sessions: [UUID: VMSession] = [:]
    var selection: UUID?
    var errorMessage: String?

    @ObservationIgnored let store: VMStore

    init() {
        if let standard = try? VMStore.standard() {
            store = standard
        } else {
            // Fall back to a temporary library rather than refusing to launch.
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Machines")
            store = try! VMStore(rootURL: tmp)
            errorMessage = "The machine library could not be opened; using temporary storage."
        }
        machines = store.loadAll()
        if machines.isEmpty {
            let demo = VMConfiguration(
                name: "Demo Monitor",
                osType: .builtInMonitor,
                notes: "Built-in firmware. Create a Linux machine and attach a kernel image to boot Linux.")
            try? store.save(demo)
            machines = [demo]
        }
    }

    func machine(_ id: UUID) -> VMConfiguration? {
        machines.first { $0.id == id }
    }

    func state(for id: UUID) -> VMEngine.State {
        sessions[id]?.state ?? .stopped
    }

    func isActive(_ id: UUID) -> Bool {
        state(for: id).isActive
    }

    // MARK: Library

    @discardableResult
    func create(_ config: VMConfiguration, kernel: URL?) -> VMConfiguration? {
        var config = config
        do {
            try store.save(config)
            if let kernel {
                try store.importKernel(from: kernel, into: &config)
            }
            machines.append(config)
            selection = config.id
            return config
        } catch {
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

    func importKernel(_ url: URL, into id: UUID) {
        guard var config = machine(id) else { return }
        do {
            try store.importKernel(from: url, into: &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    func removeKernel(from id: UUID) {
        guard var config = machine(id) else { return }
        do {
            try store.removeKernel(from: &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    func clone(_ id: UUID) {
        guard let config = machine(id) else { return }
        do {
            let copy = try store.clone(config, name: "\(config.name) Clone")
            machines.append(copy)
            selection = copy.id
        } catch {
            report(error)
        }
    }

    func delete(_ id: UUID) {
        sessions[id]?.powerOff()
        sessions[id] = nil
        do {
            try store.delete(id)
            machines.removeAll { $0.id == id }
            if selection == id { selection = nil }
        } catch {
            report(error)
        }
    }

    // MARK: Running

    /// Starts (or returns the already running) session for a machine.
    @discardableResult
    func start(_ id: UUID, from snapshot: SnapshotInfo? = nil) -> VMSession? {
        guard var config = machine(id) else { return nil }
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
            config.lastRunAt = Date()
            update(config)
            return session
        } catch {
            report(error)
            return nil
        }
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
        guard var config = machine(id) else { return }
        do {
            try store.deleteSnapshot(info, from: &config)
            replace(config)
        } catch {
            report(error)
        }
    }

    // MARK: Helpers

    private func replace(_ config: VMConfiguration) {
        if let index = machines.firstIndex(where: { $0.id == config.id }) {
            machines[index] = config
        }
    }

    private func report(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
