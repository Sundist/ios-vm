import Foundation

/// File-system backed library of virtual machines.
///
/// Layout (inside the app's Documents folder, visible in the Files app):
///
///     Machines/<uuid>/machine.json
///     Machines/<uuid>/kernel.img
///     Machines/<uuid>/Snapshots/<uuid>.pvmstate
public final class VMStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    /// The default store in the user's Documents directory.
    public static func standard() throws -> VMStore {
        let documents = try FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try VMStore(rootURL: documents.appendingPathComponent("Machines", isDirectory: true))
    }

    public func directory(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func configURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("machine.json")
    }

    private func snapshotsDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("Snapshots", isDirectory: true)
    }

    // MARK: Machines

    public func loadAll() -> [VMConfiguration] {
        let entries = (try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { dir -> VMConfiguration? in
            let url = dir.appendingPathComponent("machine.json")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(VMConfiguration.self, from: data)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ config: VMConfiguration) throws {
        try fileManager.createDirectory(at: directory(for: config.id), withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: configURL(for: config.id), options: .atomic)
    }

    public func delete(_ id: UUID) throws {
        let dir = directory(for: id)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// Creates a copy of a machine (settings + kernel, without snapshots).
    public func clone(_ config: VMConfiguration, name: String) throws -> VMConfiguration {
        var copy = config
        copy.id = UUID()
        copy.name = name
        copy.createdAt = Date()
        copy.lastRunAt = nil
        copy.snapshots = []
        try fileManager.createDirectory(at: directory(for: copy.id), withIntermediateDirectories: true)
        if let kernel = kernelURL(for: config), let fileName = config.kernelFileName {
            try fileManager.copyItem(at: kernel, to: directory(for: copy.id).appendingPathComponent(fileName))
        }
        try save(copy)
        return copy
    }

    // MARK: Kernel image

    public static let kernelFileName = "kernel.img"

    public func kernelURL(for config: VMConfiguration) -> URL? {
        guard let name = config.kernelFileName else { return nil }
        return directory(for: config.id).appendingPathComponent(name)
    }

    /// Copies a kernel image into the machine folder and records it.
    public func importKernel(from source: URL, into config: inout VMConfiguration) throws {
        #if canImport(Darwin)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        #endif

        try fileManager.createDirectory(at: directory(for: config.id), withIntermediateDirectories: true)
        let destination = directory(for: config.id).appendingPathComponent(Self.kernelFileName)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: source, to: destination)
        let attributes = try fileManager.attributesOfItem(atPath: destination.path)
        config.kernelFileName = Self.kernelFileName
        config.kernelByteCount = (attributes[.size] as? NSNumber)?.int64Value
        try save(config)
    }

    public func removeKernel(from config: inout VMConfiguration) throws {
        if let url = kernelURL(for: config), fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        config.kernelFileName = nil
        config.kernelByteCount = nil
        try save(config)
    }

    // MARK: Snapshots

    public func addSnapshot(_ data: Data, named name: String, to config: inout VMConfiguration) throws -> SnapshotInfo {
        let dir = snapshotsDirectory(for: config.id)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "\(id.uuidString).pvmstate"
        try data.write(to: dir.appendingPathComponent(fileName), options: .atomic)
        let info = SnapshotInfo(id: id, name: name, fileName: fileName, byteCount: Int64(data.count))
        config.snapshots.append(info)
        try save(config)
        return info
    }

    public func snapshotData(_ info: SnapshotInfo, of config: VMConfiguration) throws -> Data {
        try Data(contentsOf: snapshotsDirectory(for: config.id).appendingPathComponent(info.fileName),
                 options: .mappedIfSafe)
    }

    public func deleteSnapshot(_ info: SnapshotInfo, from config: inout VMConfiguration) throws {
        let url = snapshotsDirectory(for: config.id).appendingPathComponent(info.fileName)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        config.snapshots.removeAll { $0.id == info.id }
        try save(config)
    }

    // MARK: Engine

    /// Builds an engine (not yet started) for a machine configuration.
    public func makeEngine(for config: VMConfiguration) throws -> VMEngine {
        if let problem = config.startProblem {
            throw VMError.invalidImage(problem)
        }
        let machine = RV32Machine(ramSize: config.ramBytes)
        let loader: VMEngine.BootLoader
        switch config.osType {
        case .builtInMonitor:
            let image = MonitorFirmware.image
            loader = { m in
                m.reset(clearMemory: true)
                try m.load(image)
            }
        case .linuxRV32:
            guard let url = kernelURL(for: config) else { throw VMError.missingKernel }
            let kernel = try Data(contentsOf: url, options: .mappedIfSafe)
            let args = config.bootArguments
            loader = { m in try m.bootLinux(kernel: kernel, bootArguments: args) }
        }
        return VMEngine(machine: machine, bootLoader: loader)
    }
}
