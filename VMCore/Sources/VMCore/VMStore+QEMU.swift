import Foundation

extension VMStore {
    public static let efiVariablesFileName = "efi_vars.fd"
    public static let answerDiskFileName = "windows-answer.img"

    public func efiVariablesURL(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent(Self.efiVariablesFileName)
    }

    /// Resets the UEFI variable store (boot entries) to the firmware default.
    public func resetEFIVariables(for id: UUID) throws {
        let url = efiVariablesURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Prepares everything QEMU needs and returns the launch plan.
    /// - Parameters:
    ///   - resourceDirectory: QEMU's data directory (edk2 firmware).
    ///   - socketDirectory: short directory for the VNC/QMP sockets
    ///     (Unix socket paths are limited to 104 bytes).
    public func makeQEMULaunchPlan(
        for config: inout VMConfiguration,
        resourceDirectory: URL,
        socketDirectory: URL,
        splitWX: Bool = false,
        relativeSocketPaths: Bool = false
    ) throws -> QEMULaunchPlan {
        guard config.platform == .qemu else { throw VMError.invalidImage("not a QEMU machine") }
        if let problem = config.startProblem { throw VMError.invalidImage(problem) }
        let fm = FileManager.default
        let arch = config.osType.qemuArchitecture
        let firmware = QEMUArgumentBuilder.firmwareFiles(for: arch)
        guard fm.fileExists(atPath: resourceDirectory.appendingPathComponent(firmware.code).path) else {
            throw VMError.invalidImage("The QEMU engine is not part of this build (UEFI firmware \(firmware.code) is missing). See README › QEMU.")
        }

        // Per-machine UEFI variables, created from the firmware template.
        let vars = efiVariablesURL(for: config.id)
        if !fm.fileExists(atPath: vars.path) {
            let template = resourceDirectory.appendingPathComponent(firmware.varsTemplate)
            if fm.fileExists(atPath: template.path) {
                try fm.copyItem(at: template, to: vars)
            } else {
                guard fm.createFile(atPath: vars.path, contents: nil) else {
                    throw VMError.invalidImage("could not create the UEFI variable store")
                }
                let handle = try FileHandle(forWritingTo: vars)
                try handle.truncate(atOffset: 64 * 1024 * 1024)
                try handle.close()
            }
        }

        var accessed: [URL] = []
        let cdrom = try resolveCDROM(for: &config)
        #if canImport(Darwin)
        if let cdrom, cdrom.startAccessingSecurityScopedResource() {
            accessed.append(cdrom)
        }
        #endif

        let hardDisk = hardDiskURL(for: config)
        if let hardDisk, !fm.fileExists(atPath: hardDisk.path) {
            #if canImport(Darwin)
            accessed.forEach { $0.stopAccessingSecurityScopedResource() }
            #endif
            throw VMError.invalidImage("the hard disk image is missing")
        }

        var answerDisk: URL?
        if config.osType.isWindows11 && config.bypassWindowsRequirements {
            let url = directory(for: config.id).appendingPathComponent(Self.answerDiskFileName)
            try WindowsAnswerFile.makeDiskImage().write(to: url, options: .atomic)
            answerDisk = url
        }

        try fm.createDirectory(at: socketDirectory, withIntermediateDirectories: true)
        let tag = String(config.id.uuidString.prefix(8)).lowercased()
        let vnc = socketDirectory.appendingPathComponent("\(tag).v")
        let qmp = socketDirectory.appendingPathComponent("\(tag).q")
        for socket in [vnc, qmp] where fm.fileExists(atPath: socket.path) {
            try? fm.removeItem(at: socket)
        }

        var builder = QEMUArgumentBuilder(
            config: config, resourceDirectory: resourceDirectory, hardDisk: hardDisk, cdrom: cdrom,
            answerDisk: answerDisk, efiVariables: vars, vncSocket: vnc, qmpSocket: qmp)
        builder.splitWX = splitWX
        builder.relativeSocketPaths = relativeSocketPaths
        builder.translationBlockCacheMB = config.memoryMB >= 4096 ? 256 : 128

        return QEMULaunchPlan(
            architecture: arch,
            libraryName: QEMUArgumentBuilder.libraryName(for: arch),
            arguments: builder.build(),
            vncSocket: vnc,
            qmpSocket: qmp,
            socketDirectory: socketDirectory,
            accessedURLs: accessed)
    }
}
