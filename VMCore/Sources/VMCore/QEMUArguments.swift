import Foundation

/// Everything needed to launch QEMU for one machine.
public struct QEMULaunchPlan: Sendable {
    public var architecture: QEMUArchitecture
    /// Name of the QEMU framework/dylib (e.g. `qemu-aarch64-softmmu`).
    public var libraryName: String
    public var arguments: [String]
    public var vncSocket: URL
    public var qmpSocket: URL
    /// Security-scoped files (ISO) that must stay accessible while running.
    public var accessedURLs: [URL]
}

/// Builds QEMU command lines. Device choices follow what Windows 11 and
/// common Linux distributions support without extra drivers:
///
/// * ARM64: `virt`, `-cpu max`, UEFI (edk2) in pflash, `ramfb` display,
///   NVMe system disk, CD/DVD and answer disk on USB storage, xHCI keyboard
///   and tablet (absolute pointer for touch).
/// * x86-64: `q35`, `-cpu max`, UEFI, std VGA, NVMe disk, AHCI CD/DVD,
///   e1000e network, xHCI keyboard and tablet.
public struct QEMUArgumentBuilder {
    public var config: VMConfiguration
    /// QEMU data directory (`share/qemu`) containing the edk2 firmware.
    public var resourceDirectory: URL
    public var hardDisk: URL?
    public var cdrom: URL?
    public var answerDisk: URL?
    public var efiVariables: URL
    public var vncSocket: URL
    public var qmpSocket: URL
    /// Translation cache size; TCI/TCTI and JIT builds both use TCG.
    public var translationBlockCacheMB = 256
    /// Use mirrored RW/RX mappings (JIT enabled by a debugger, no entitlement).
    public var splitWX = false

    public init(config: VMConfiguration, resourceDirectory: URL, hardDisk: URL?, cdrom: URL?, answerDisk: URL?,
                efiVariables: URL, vncSocket: URL, qmpSocket: URL) {
        self.config = config
        self.resourceDirectory = resourceDirectory
        self.hardDisk = hardDisk
        self.cdrom = cdrom
        self.answerDisk = answerDisk
        self.efiVariables = efiVariables
        self.vncSocket = vncSocket
        self.qmpSocket = qmpSocket
    }

    public static func libraryName(for architecture: QEMUArchitecture) -> String {
        "qemu-\(architecture.rawValue)-softmmu"
    }

    /// edk2 firmware file names shipped in QEMU's data directory.
    public static func firmwareFiles(for architecture: QEMUArchitecture) -> (code: String, varsTemplate: String) {
        switch architecture {
        case .aarch64: return ("edk2-aarch64-code.fd", "edk2-arm-vars.fd")
        case .x86_64: return ("edk2-x86_64-code.fd", "edk2-i386-vars.fd")
        }
    }

    /// Escapes a value for QEMU's comma-separated option syntax.
    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: ",", with: ",,")
    }

    public func build() -> [String] {
        let arch = config.osType.qemuArchitecture
        let firmware = Self.firmwareFiles(for: arch)
        let code = resourceDirectory.appendingPathComponent(firmware.code).path
        let memory = min(max(config.memoryMB, VMConfiguration.qemuMemoryRangeMB.lowerBound),
                         VMConfiguration.qemuMemoryRangeMB.upperBound)
        let cpus = min(max(config.cpuCount, 1), 8)

        var tcg = "tcg,tb-size=\(translationBlockCacheMB)"
        if cpus > 1 { tcg += ",thread=multi" }
        if splitWX { tcg += ",split-wx=on" }

        var args: [String] = [
            "-L", resourceDirectory.path,
            "-nodefaults",
            "-name", config.name,
            "-accel", tcg,
            // impdef pointer authentication is much cheaper to emulate.
            "-cpu", arch == .aarch64 ? "max,pauth-impdef=on" : "max",
            "-smp", "\(cpus)",
            "-m", "\(memory)",
            "-rtc", config.osType.isWindows11 ? "base=localtime" : "base=utc",
            "-boot", "menu=off",
        ]

        switch arch {
        case .aarch64:
            args += ["-machine", "virt"]
        case .x86_64:
            args += ["-machine", "q35,vmport=off", "-global", "ICH9-LPC.disable_s3=1"]
        }

        // UEFI firmware + per-machine variable store.
        args += [
            "-drive", "if=pflash,format=raw,unit=0,file.filename=\(Self.escape(code)),file.locking=off,readonly=on",
            "-drive", "if=pflash,format=raw,unit=1,file.filename=\(Self.escape(efiVariables.path)),file.locking=off",
        ]

        // Display, USB input (tablet = absolute pointer, ideal for touch).
        args += ["-device", arch == .aarch64 ? "ramfb" : "VGA,vgamem_mb=64"]
        args += ["-device", "qemu-xhci,id=xhci", "-device", "usb-kbd,bus=xhci.0", "-device", "usb-tablet,bus=xhci.0"]

        // Storage.
        if let hardDisk {
            args += [
                "-drive", "if=none,id=hd0,format=raw,file=\(Self.escape(hardDisk.path)),cache=writeback,discard=unmap",
                "-device", "nvme,drive=hd0,serial=POCKETVM0,bootindex=1",
            ]
        }
        // The CD drive always exists so an image can be inserted later.
        let cdFile = cdrom.map { ",file=\(Self.escape($0.path))" } ?? ""
        args += ["-drive", "if=none,id=cd0,media=cdrom,readonly=on\(cdFile)"]
        switch arch {
        case .aarch64:
            args += ["-device", "usb-storage,id=cddev,drive=cd0,removable=on,bus=xhci.0,bootindex=0"]
        case .x86_64:
            args += ["-device", "ide-cd,id=cddev,drive=cd0,bus=ide.1,bootindex=0"]
        }
        if let answerDisk {
            args += [
                "-drive", "if=none,id=ans0,format=raw,readonly=on,file=\(Self.escape(answerDisk.path))",
                "-device", "usb-storage,drive=ans0,removable=on,bus=xhci.0",
            ]
        }

        // Network (user mode NAT).
        args += ["-netdev", "user,id=net0"]
        args += ["-device", arch == .aarch64 ? "virtio-net-pci,netdev=net0" : "e1000e,netdev=net0"]

        // Control channels used by the app.
        args += [
            "-vnc", "unix:\(vncSocket.path)",
            "-qmp", "unix:\(qmpSocket.path),server=on,wait=off",
        ]
        return args
    }
}
