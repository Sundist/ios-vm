import Foundation

/// A drive of a PC machine.
public enum PCDrive: String, CaseIterable, Sendable {
    case cdrom, hda, fda
}

/// Everything the PC engine needs to boot a machine: the v86 options sent to
/// the web page and the files the app serves for each drive.
public struct PCBootPlan: Sendable {
    public var memoryMB: Int
    public var vgaMemoryMB: Int
    public var acpi: Bool
    public var bootOrder: Int
    public var restoreState: Bool
    /// Drive -> (file, size). The CD-ROM URL may be security scoped.
    public var drives: [PCDrive: (url: URL, size: Int64)]
    public var stateURL: URL?

    /// JSON object passed to `pvm.boot()` in the page.
    public func pageConfiguration() -> [String: Any] {
        var config: [String: Any] = [
            "memoryMB": memoryMB,
            "vgaMemoryMB": vgaMemoryMB,
            "acpi": acpi,
            "bootOrder": bootOrder,
            "restoreState": restoreState,
        ]
        for (drive, info) in drives {
            config[drive.rawValue] = ["size": info.size]
        }
        return config
    }

    public func pageConfigurationJSON() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: pageConfiguration(), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

extension VMStore {
    public static let hardDiskFileName = "harddisk.img"
    public static let floppyFileName = "floppy.img"
    public static let savedStateFileName = "saved.state"

    private var files: FileManager { FileManager.default }

    private func size(of url: URL) throws -> Int64 {
        let attributes = try files.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Hard disk

    public func hardDiskURL(for config: VMConfiguration) -> URL? {
        config.hardDiskFileName.map { directory(for: config.id).appendingPathComponent($0) }
    }

    /// Creates an empty (sparse) raw hard disk image.
    public func createHardDisk(sizeGB: Int, into config: inout VMConfiguration) throws {
        precondition(sizeGB > 0)
        try files.createDirectory(at: directory(for: config.id), withIntermediateDirectories: true)
        let url = directory(for: config.id).appendingPathComponent(Self.hardDiskFileName)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        guard files.createFile(atPath: url.path, contents: nil) else {
            throw VMError.invalidImage("could not create the hard disk file")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let bytes = UInt64(sizeGB) * 1024 * 1024 * 1024
        try handle.truncate(atOffset: bytes)
        config.hardDiskFileName = Self.hardDiskFileName
        config.hardDiskByteCount = Int64(bytes)
        config.hasSavedState = false
        try save(config)
    }

    /// Copies an existing raw disk image (.img / .raw) into the machine.
    public func importHardDisk(from source: URL, into config: inout VMConfiguration) throws {
        let size = try copyIntoMachine(source, fileName: Self.hardDiskFileName, config: config)
        guard size % 512 == 0 else {
            throw VMError.invalidImage("a raw disk image must be a multiple of 512 bytes (qcow2/vdi/vmdk need converting to raw)")
        }
        config.hardDiskFileName = Self.hardDiskFileName
        config.hardDiskByteCount = size
        config.hasSavedState = false
        try save(config)
    }

    public func removeHardDisk(from config: inout VMConfiguration) throws {
        if let url = hardDiskURL(for: config), files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
        config.hardDiskFileName = nil
        config.hardDiskByteCount = nil
        config.hasSavedState = false
        try save(config)
    }

    // MARK: Floppy

    public func floppyURL(for config: VMConfiguration) -> URL? {
        config.floppyFileName.map { directory(for: config.id).appendingPathComponent($0) }
    }

    public func importFloppy(from source: URL, into config: inout VMConfiguration) throws {
        let size = try copyIntoMachine(source, fileName: Self.floppyFileName, config: config)
        guard size <= 4 * 1024 * 1024 else {
            throw VMError.invalidImage("floppy images must be at most 2.88 MB")
        }
        config.floppyFileName = Self.floppyFileName
        config.floppyByteCount = size
        try save(config)
    }

    public func removeFloppy(from config: inout VMConfiguration) throws {
        if let url = floppyURL(for: config), files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
        config.floppyFileName = nil
        config.floppyByteCount = nil
        try save(config)
    }

    // MARK: CD/DVD (referenced in place, ISOs are often several GB)

    public func attachCDROM(from source: URL, into config: inout VMConfiguration) throws {
        #if canImport(Darwin)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        #endif
        let size = try self.size(of: source)
        guard size > 0 else { throw VMError.invalidImage("the CD/DVD image is empty") }
        config.cdromBookmark = try source.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        config.cdromName = source.lastPathComponent
        config.cdromByteCount = size
        try save(config)
    }

    public func ejectCDROM(from config: inout VMConfiguration) throws {
        config.cdromBookmark = nil
        config.cdromName = nil
        config.cdromByteCount = nil
        try save(config)
    }

    /// Resolves the CD-ROM bookmark. The caller must balance
    /// `startAccessingSecurityScopedResource()` on the returned URL.
    public func resolveCDROM(for config: inout VMConfiguration) throws -> URL? {
        guard let bookmark = config.cdromBookmark else { return nil }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw VMError.invalidImage("the CD/DVD image “\(config.cdromName ?? "ISO")” can no longer be found. Attach it again.")
        }
        if stale {
            #if canImport(Darwin)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            #endif
            if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                config.cdromBookmark = refreshed
                try? save(config)
            }
        }
        return url
    }

    // MARK: Saved state

    public func savedStateURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent(Self.savedStateFileName)
    }

    public func savedStateSize(for id: UUID) -> Int64? {
        try? size(of: savedStateURL(for: id))
    }

    public func discardSavedState(of config: inout VMConfiguration) throws {
        let url = savedStateURL(for: config.id)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        config.hasSavedState = false
        try save(config)
    }

    /// Moves a freshly written state file into place.
    public func commitSavedState(from temporary: URL, into config: inout VMConfiguration) throws {
        let url = savedStateURL(for: config.id)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
        try files.moveItem(at: temporary, to: url)
        config.hasSavedState = true
        try save(config)
    }

    // MARK: Boot plan

    /// Builds the PC boot plan. `cdromURL` is the resolved (and accessed) ISO.
    public func makePCBootPlan(for config: VMConfiguration, cdromURL: URL?, restoreState: Bool) throws -> PCBootPlan {
        guard config.platform == .pc else { throw VMError.invalidImage("not a PC machine") }
        if let problem = config.startProblem { throw VMError.invalidImage(problem) }

        var drives: [PCDrive: (url: URL, size: Int64)] = [:]
        if let url = cdromURL {
            drives[.cdrom] = (url, try size(of: url))
        }
        if let url = hardDiskURL(for: config) {
            guard files.fileExists(atPath: url.path) else { throw VMError.invalidImage("the hard disk image is missing") }
            drives[.hda] = (url, try size(of: url))
        }
        if let url = floppyURL(for: config), files.fileExists(atPath: url.path) {
            drives[.fda] = (url, try size(of: url))
        }

        let stateURL = savedStateURL(for: config.id)
        let restore = restoreState && config.hasSavedState && files.fileExists(atPath: stateURL.path)
        let memory = min(max(config.memoryMB, VMConfiguration.pcMemoryRangeMB.lowerBound),
                         VMConfiguration.pcMemoryRangeMB.upperBound)
        return PCBootPlan(
            memoryMB: memory,
            vgaMemoryMB: min(max(config.vgaMemoryMB, 2), 128),
            acpi: config.acpiEnabled,
            bootOrder: config.bootDevice.v86BootOrder,
            restoreState: restore,
            drives: drives,
            stateURL: restore ? stateURL : nil)
    }

    // MARK: Helpers

    private func copyIntoMachine(_ source: URL, fileName: String, config: VMConfiguration) throws -> Int64 {
        #if canImport(Darwin)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        #endif
        let dir = directory(for: config.id)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(fileName)
        let temporary = dir.appendingPathComponent(fileName + ".importing")
        if files.fileExists(atPath: temporary.path) { try files.removeItem(at: temporary) }
        try files.copyItem(at: source, to: temporary)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: temporary, to: destination)
        return try size(of: destination)
    }
}
