import Foundation

/// Guest operating system families the app can run.
public enum GuestOSType: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The built-in monitor firmware; needs no files.
    case builtInMonitor
    /// No-MMU 32-bit RISC-V Linux (e.g. images built for mini-rv32ima).
    case linuxRV32

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtInMonitor: return "PocketVM Monitor (built-in)"
        case .linuxRV32: return "Linux (RISC-V 32-bit, no-MMU)"
        }
    }

    public var shortName: String {
        switch self {
        case .builtInMonitor: return "Monitor"
        case .linuxRV32: return "Linux RV32"
        }
    }

    public var symbolName: String {
        switch self {
        case .builtInMonitor: return "cpu"
        case .linuxRV32: return "terminal"
        }
    }

    public var requiresKernel: Bool { self == .linuxRV32 }

    public var defaultMemoryMB: Int {
        switch self {
        case .builtInMonitor: return 8
        case .linuxRV32: return 64
        }
    }

    public var defaultBootArguments: String {
        switch self {
        case .builtInMonitor: return ""
        case .linuxRV32: return DeviceTree.defaultBootArguments
        }
    }
}

public struct SnapshotInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var fileName: String
    public var byteCount: Int64

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), fileName: String, byteCount: Int64) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.fileName = fileName
        self.byteCount = byteCount
    }
}

/// Persistent settings for one virtual machine (the `.vbox` equivalent).
public struct VMConfiguration: Codable, Identifiable, Hashable, Sendable {
    public static let memoryRangeMB = 1...512

    public var id: UUID
    public var name: String
    public var osType: GuestOSType
    public var memoryMB: Int
    public var kernelFileName: String?
    public var kernelByteCount: Int64?
    public var bootArguments: String
    public var notes: String
    public var createdAt: Date
    public var lastRunAt: Date?
    public var snapshots: [SnapshotInfo]

    public init(
        id: UUID = UUID(),
        name: String,
        osType: GuestOSType,
        memoryMB: Int? = nil,
        bootArguments: String? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.osType = osType
        self.memoryMB = memoryMB ?? osType.defaultMemoryMB
        self.kernelFileName = nil
        self.kernelByteCount = nil
        self.bootArguments = bootArguments ?? osType.defaultBootArguments
        self.notes = notes
        self.createdAt = Date()
        self.lastRunAt = nil
        self.snapshots = []
    }

    public var ramBytes: UInt32 {
        let clamped = min(max(memoryMB, Self.memoryRangeMB.lowerBound), Self.memoryRangeMB.upperBound)
        return UInt32(clamped) * 1024 * 1024
    }

    /// Returns a human readable reason the machine cannot start, if any.
    public var startProblem: String? {
        if osType.requiresKernel && kernelFileName == nil {
            return VMError.missingKernel.errorDescription
        }
        if let size = kernelByteCount, size > Int64(ramBytes) - Int64(RV32Machine.deviceTreeReserve) {
            return "The kernel image is larger than the base memory. Increase the memory size."
        }
        return nil
    }
}
