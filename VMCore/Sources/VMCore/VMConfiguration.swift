import Foundation

/// Which emulator runs a machine.
public enum MachinePlatform: String, Codable, Sendable {
    /// Built-in RV32IMA interpreter (`RV32Machine`).
    case riscv
    /// 32-bit x86 PC (v86, running in a WebKit view).
    case pc
    /// QEMU system emulator (ARM64 / x86-64 guests, UEFI).
    case qemu
}

/// CPU architecture emulated by QEMU.
public enum QEMUArchitecture: String, Codable, Sendable {
    case aarch64, x86_64

    public var displayName: String { self == .aarch64 ? "ARM64" : "x86-64" }
}

/// Guest operating system families the app can run.
public enum GuestOSType: String, Codable, CaseIterable, Identifiable, Sendable {
    // x86 PC
    case windows9x
    case windowsNT
    case windowsModern
    case linuxX86
    case dosX86
    case otherX86
    // QEMU
    case windows11ARM
    case windows11x64
    case linuxARM64
    case linuxX64
    // RISC-V
    case linuxRV32
    case builtInMonitor

    public var id: String { rawValue }

    public var platform: MachinePlatform {
        switch self {
        case .builtInMonitor, .linuxRV32: return .riscv
        case .windows11ARM, .windows11x64, .linuxARM64, .linuxX64: return .qemu
        default: return .pc
        }
    }

    /// QEMU target for QEMU machines.
    public var qemuArchitecture: QEMUArchitecture {
        switch self {
        case .windows11x64, .linuxX64: return .x86_64
        default: return .aarch64
        }
    }

    public var isWindows11: Bool { self == .windows11ARM || self == .windows11x64 }

    public var displayName: String {
        switch self {
        case .windows9x: return "Windows 95 / 98 / ME"
        case .windowsNT: return "Windows 2000 / XP (32-bit)"
        case .windowsModern: return "Windows Vista / 7 (32-bit, experimental)"
        case .linuxX86: return "Linux / BSD (32-bit x86)"
        case .dosX86: return "DOS / FreeDOS / Windows 3.x"
        case .otherX86: return "Other x86 (ISO, disk or floppy)"
        case .windows11ARM: return "Windows 11 ARM64 (QEMU)"
        case .windows11x64: return "Windows 10 / 11 x64 (QEMU)"
        case .linuxARM64: return "Linux ARM64 (QEMU)"
        case .linuxX64: return "Linux x86-64 (QEMU)"
        case .linuxRV32: return "Linux (RISC-V 32-bit, no-MMU)"
        case .builtInMonitor: return "PocketVM Monitor (built-in)"
        }
    }

    public var shortName: String {
        switch self {
        case .windows9x: return "Windows 98"
        case .windowsNT: return "Windows XP"
        case .windowsModern: return "Windows 7"
        case .linuxX86: return "Linux"
        case .dosX86: return "DOS"
        case .otherX86: return "PC"
        case .windows11ARM: return "Windows 11 ARM"
        case .windows11x64: return "Windows 11"
        case .linuxARM64: return "Linux ARM64"
        case .linuxX64: return "Linux x64"
        case .linuxRV32: return "Linux RV32"
        case .builtInMonitor: return "Monitor"
        }
    }

    public var symbolName: String {
        switch self {
        case .windows9x, .windowsNT, .windowsModern: return "pc"
        case .linuxX86, .linuxRV32: return "terminal"
        case .dosX86: return "keyboard"
        case .otherX86: return "opticaldisc"
        case .windows11ARM, .windows11x64: return "macwindow"
        case .linuxARM64, .linuxX64: return "server.rack"
        case .builtInMonitor: return "cpu"
        }
    }

    /// Accent colour name used for the machine icon (see the app's palette).
    public var colorName: String {
        switch self {
        case .windows9x, .windowsNT, .windowsModern: return "blue"
        case .linuxX86, .linuxRV32: return "orange"
        case .dosX86: return "gray"
        case .otherX86: return "purple"
        case .windows11ARM, .windows11x64: return "indigo"
        case .linuxARM64, .linuxX64: return "green"
        case .builtInMonitor: return "teal"
        }
    }

    public var requiresKernel: Bool { self == .linuxRV32 }

    public var defaultMemoryMB: Int {
        switch self {
        case .builtInMonitor: return 8
        case .linuxRV32: return 64
        case .windows9x: return 128
        case .windowsNT: return 512
        case .windowsModern: return 1024
        case .linuxX86: return 256
        case .dosX86: return 32
        case .otherX86: return 128
        case .windows11ARM, .windows11x64: return 4096
        case .linuxARM64, .linuxX64: return 2048
        }
    }

    /// Size of the blank hard disk offered when creating a machine (GB, 0 = none).
    public var defaultDiskGB: Int {
        switch self {
        case .windows9x: return 2
        case .windowsNT: return 4
        case .windowsModern: return 16
        case .linuxX86: return 4
        case .dosX86: return 1
        case .otherX86: return 0
        case .windows11ARM, .windows11x64: return 64
        case .linuxARM64, .linuxX64: return 20
        case .linuxRV32, .builtInMonitor: return 0
        }
    }

    public var defaultACPI: Bool {
        switch self {
        case .windowsModern, .linuxX86: return true
        default: return false
        }
    }

    public var defaultBootArguments: String {
        self == .linuxRV32 ? DeviceTree.defaultBootArguments : ""
    }

    /// Short setup hint shown when creating a machine.
    public var setupHint: String {
        switch self {
        case .windows9x:
            return "Attach the installation CD (ISO) and a blank hard disk. ACPI stays off."
        case .windowsNT:
            return "During setup press F5 and choose “Standard PC”. 512 MB RAM and a 2–4 GB disk work well."
        case .windowsModern:
            return "Very slow: an emulated 32-bit CPU without hardware acceleration. 64-bit Windows (10/11) cannot run."
        case .linuxX86:
            return "Use a 32-bit (i386/i686) ISO. Live ISOs run without a hard disk."
        case .dosX86:
            return "Boots from a floppy image, a CD or a hard disk image."
        case .otherX86:
            return "Any 32-bit x86 operating system: KolibriOS, ReactOS, Haiku, BSD…"
        case .windows11ARM:
            return "Use a Windows 11 ARM64 ISO. Faster than x64 on iPhone, but still emulated: expect a very slow install without JIT. TPM, Secure Boot and RAM checks are bypassed automatically."
        case .windows11x64:
            return "Use a Windows 10/11 x64 ISO. x86-64 is fully emulated and extremely slow without JIT. TPM, Secure Boot and RAM checks are bypassed automatically."
        case .linuxARM64:
            return "Use an ARM64 (aarch64) ISO with UEFI support, e.g. Ubuntu Server or Debian arm64."
        case .linuxX64:
            return "Use an x86-64 ISO with UEFI support."
        case .linuxRV32:
            return "Boots a 32-bit RISC-V Linux kernel on an emulated CPU with a 16550 serial console."
        case .builtInMonitor:
            return "A tiny built-in firmware with an echo console. Useful to try the app without any files."
        }
    }

    public static var pcTypes: [GuestOSType] { allCases.filter { $0.platform == .pc } }
    public static var qemuTypes: [GuestOSType] { allCases.filter { $0.platform == .qemu } }
    public static var riscvTypes: [GuestOSType] { allCases.filter { $0.platform == .riscv } }
}

/// Boot device order for PC machines (values are v86's `boot_order`).
public enum BootDevice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, cdrom, hardDisk, floppy

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .cdrom: return "CD/DVD first"
        case .hardDisk: return "Hard disk first"
        case .floppy: return "Floppy first"
        }
    }

    public var v86BootOrder: Int {
        switch self {
        case .automatic: return 0
        case .cdrom: return 0x123
        case .hardDisk: return 0x132
        case .floppy: return 0x321
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
    public static let riscvMemoryRangeMB = 1...512
    public static let pcMemoryRangeMB = 16...2048
    public static let qemuMemoryRangeMB = 512...16384

    public var id: UUID
    public var name: String
    public var osType: GuestOSType
    public var memoryMB: Int
    public var notes: String
    public var createdAt: Date
    public var lastRunAt: Date?

    // RISC-V
    public var kernelFileName: String?
    public var kernelByteCount: Int64?
    public var bootArguments: String
    public var snapshots: [SnapshotInfo]

    // PC
    public var vgaMemoryMB: Int
    public var acpiEnabled: Bool
    public var bootDevice: BootDevice
    /// CD/DVD image: referenced in place (not copied) through a bookmark.
    public var cdromName: String?
    public var cdromBookmark: Data?
    public var cdromByteCount: Int64?
    /// Hard disk image stored inside the machine folder.
    public var hardDiskFileName: String?
    public var hardDiskByteCount: Int64?
    public var floppyFileName: String?
    public var floppyByteCount: Int64?
    /// True while a "Save State" image exists (VirtualBox: *Saved*).
    public var hasSavedState: Bool

    // QEMU
    public var cpuCount: Int
    /// Attach an answer file that skips Windows 11's TPM / Secure Boot / RAM / CPU checks.
    public var bypassWindowsRequirements: Bool

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
        self.notes = notes
        self.createdAt = Date()
        self.lastRunAt = nil
        self.kernelFileName = nil
        self.kernelByteCount = nil
        self.bootArguments = bootArguments ?? osType.defaultBootArguments
        self.snapshots = []
        self.vgaMemoryMB = osType == .windowsModern ? 16 : 8
        self.acpiEnabled = osType.defaultACPI
        self.bootDevice = .automatic
        self.cdromName = nil
        self.cdromBookmark = nil
        self.cdromByteCount = nil
        self.hardDiskFileName = nil
        self.hardDiskByteCount = nil
        self.floppyFileName = nil
        self.floppyByteCount = nil
        self.hasSavedState = false
        self.cpuCount = osType.platform == .qemu ? 2 : 1
        self.bypassWindowsRequirements = osType.isWindows11
    }

    // Decoding tolerates files written by older versions of the app.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        osType = (try? c.decode(GuestOSType.self, forKey: .osType)) ?? .otherX86
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB) ?? osType.defaultMemoryMB
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
        kernelFileName = try c.decodeIfPresent(String.self, forKey: .kernelFileName)
        kernelByteCount = try c.decodeIfPresent(Int64.self, forKey: .kernelByteCount)
        bootArguments = try c.decodeIfPresent(String.self, forKey: .bootArguments) ?? osType.defaultBootArguments
        snapshots = try c.decodeIfPresent([SnapshotInfo].self, forKey: .snapshots) ?? []
        vgaMemoryMB = try c.decodeIfPresent(Int.self, forKey: .vgaMemoryMB) ?? 8
        acpiEnabled = try c.decodeIfPresent(Bool.self, forKey: .acpiEnabled) ?? osType.defaultACPI
        bootDevice = try c.decodeIfPresent(BootDevice.self, forKey: .bootDevice) ?? .automatic
        cdromName = try c.decodeIfPresent(String.self, forKey: .cdromName)
        cdromBookmark = try c.decodeIfPresent(Data.self, forKey: .cdromBookmark)
        cdromByteCount = try c.decodeIfPresent(Int64.self, forKey: .cdromByteCount)
        hardDiskFileName = try c.decodeIfPresent(String.self, forKey: .hardDiskFileName)
        hardDiskByteCount = try c.decodeIfPresent(Int64.self, forKey: .hardDiskByteCount)
        floppyFileName = try c.decodeIfPresent(String.self, forKey: .floppyFileName)
        floppyByteCount = try c.decodeIfPresent(Int64.self, forKey: .floppyByteCount)
        hasSavedState = try c.decodeIfPresent(Bool.self, forKey: .hasSavedState) ?? false
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? (osType.platform == .qemu ? 2 : 1)
        bypassWindowsRequirements = try c.decodeIfPresent(Bool.self, forKey: .bypassWindowsRequirements) ?? osType.isWindows11
    }

    public var platform: MachinePlatform { osType.platform }

    public var memoryRangeMB: ClosedRange<Int> {
        switch platform {
        case .pc: return Self.pcMemoryRangeMB
        case .qemu: return Self.qemuMemoryRangeMB
        case .riscv: return Self.riscvMemoryRangeMB
        }
    }

    /// Guest RAM for the RISC-V machine.
    public var ramBytes: UInt32 {
        let range = Self.riscvMemoryRangeMB
        let clamped = min(max(memoryMB, range.lowerBound), range.upperBound)
        return UInt32(clamped) * 1024 * 1024
    }

    public var hasBootMedia: Bool {
        cdromBookmark != nil || hardDiskFileName != nil || floppyFileName != nil
    }

    /// Returns a human readable reason the machine cannot start, if any.
    public var startProblem: String? {
        switch platform {
        case .riscv:
            if osType.requiresKernel && kernelFileName == nil {
                return VMError.missingKernel.errorDescription
            }
            if let size = kernelByteCount, size > Int64(ramBytes) - Int64(RV32Machine.deviceTreeReserve) {
                return "The kernel image is larger than the base memory. Increase the memory size."
            }
        case .pc, .qemu:
            if !hasBootMedia {
                return "Attach a CD/DVD image (ISO), a hard disk or a floppy image in Settings › Storage."
            }
        }
        return nil
    }
}
