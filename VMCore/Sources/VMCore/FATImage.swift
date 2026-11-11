import Foundation

/// Writes a 1.44 MB FAT12 image ("superfloppy", no partition table) with
/// files in the root directory, including VFAT long file names.
public enum FATImage {
    public static let sectorSize = 512
    public static let totalSectors = 2880
    static let sectorsPerFAT = 9
    static let rootEntries = 224
    static let reservedSectors = 1
    static let fatCount = 2

    static var rootDirSectors: Int { rootEntries * 32 / sectorSize }               // 14
    static var firstRootSector: Int { reservedSectors + fatCount * sectorsPerFAT } // 19
    static var firstDataSector: Int { firstRootSector + rootDirSectors }           // 33
    static var dataClusters: Int { totalSectors - firstDataSector }

    public enum FATError: Error, Equatable {
        case tooLarge
        case tooManyFiles
        case invalidName(String)
    }

    public static func make(files: [(name: String, data: Data)], volumeLabel: String = "PVMANSWER") throws -> Data {
        var image = [UInt8](repeating: 0, count: totalSectors * sectorSize)
        writeBootSector(&image, label: volumeLabel)

        var fat = [UInt8](repeating: 0, count: sectorsPerFAT * sectorSize)
        setFAT(&fat, 0, 0xFF0)
        setFAT(&fat, 1, 0xFFF)

        var directory: [[UInt8]] = [volumeLabelEntry(volumeLabel)]
        var nextCluster = 2
        for (index, file) in files.enumerated() {
            let clusters = max(1, (file.data.count + sectorSize - 1) / sectorSize)
            guard nextCluster - 2 + clusters <= dataClusters else { throw FATError.tooLarge }
            let first = file.data.isEmpty ? 0 : nextCluster
            if !file.data.isEmpty {
                for c in 0..<clusters {
                    let cluster = nextCluster + c
                    setFAT(&fat, cluster, c == clusters - 1 ? 0xFFF : cluster + 1)
                }
                let offset = (firstDataSector + nextCluster - 2) * sectorSize
                image.replaceSubrange(offset..<(offset + file.data.count), with: file.data)
                nextCluster += clusters
            }
            directory += try entries(for: file.name, index: index, firstCluster: first, size: file.data.count)
        }
        guard directory.count <= rootEntries else { throw FATError.tooManyFiles }

        for copy in 0..<fatCount {
            let offset = (reservedSectors + copy * sectorsPerFAT) * sectorSize
            image.replaceSubrange(offset..<(offset + fat.count), with: fat)
        }
        var offset = firstRootSector * sectorSize
        for entry in directory {
            image.replaceSubrange(offset..<(offset + 32), with: entry)
            offset += 32
        }
        return Data(image)
    }

    // MARK: Pieces

    static func setFAT(_ fat: inout [UInt8], _ cluster: Int, _ value: Int) {
        let offset = cluster * 3 / 2
        if cluster % 2 == 0 {
            fat[offset] = UInt8(value & 0xff)
            fat[offset + 1] = (fat[offset + 1] & 0xf0) | UInt8((value >> 8) & 0x0f)
        } else {
            fat[offset] = (fat[offset] & 0x0f) | UInt8((value & 0x0f) << 4)
            fat[offset + 1] = UInt8((value >> 4) & 0xff)
        }
    }

    static func getFAT(_ fat: [UInt8], _ cluster: Int) -> Int {
        let offset = cluster * 3 / 2
        let pair = Int(fat[offset]) | (Int(fat[offset + 1]) << 8)
        return cluster % 2 == 0 ? pair & 0xfff : pair >> 4
    }

    private static func put16(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        buffer[offset] = UInt8(value & 0xff)
        buffer[offset + 1] = UInt8((value >> 8) & 0xff)
    }

    private static func put32(_ buffer: inout [UInt8], _ offset: Int, _ value: Int) {
        put16(&buffer, offset, value & 0xffff)
        put16(&buffer, offset + 2, (value >> 16) & 0xffff)
    }

    private static func padded(_ text: String, _ length: Int) -> [UInt8] {
        let bytes = Array(text.uppercased().utf8.prefix(length))
        return bytes + [UInt8](repeating: 0x20, count: length - bytes.count)
    }

    private static func writeBootSector(_ image: inout [UInt8], label: String) {
        image[0] = 0xeb; image[1] = 0x3c; image[2] = 0x90
        image.replaceSubrange(3..<11, with: Array("POCKETVM".utf8))
        put16(&image, 11, sectorSize)
        image[13] = 1                                  // sectors per cluster
        put16(&image, 14, reservedSectors)
        image[16] = UInt8(fatCount)
        put16(&image, 17, rootEntries)
        put16(&image, 19, totalSectors)
        image[21] = 0xf0                               // media descriptor
        put16(&image, 22, sectorsPerFAT)
        put16(&image, 24, 18)                          // sectors per track
        put16(&image, 26, 2)                           // heads
        image[36] = 0x00                               // drive number
        image[38] = 0x29                               // extended boot signature
        put32(&image, 39, 0x5056_4d31)                 // volume serial
        image.replaceSubrange(43..<54, with: padded(label, 11))
        image.replaceSubrange(54..<62, with: Array("FAT12   ".utf8))
        image[510] = 0x55; image[511] = 0xaa
    }

    private static func volumeLabelEntry(_ label: String) -> [UInt8] {
        var entry = [UInt8](repeating: 0, count: 32)
        entry.replaceSubrange(0..<11, with: padded(label, 11))
        entry[11] = 0x08
        return entry
    }

    static func shortNameChecksum(_ name: [UInt8]) -> UInt8 {
        var sum: UInt8 = 0
        for byte in name {
            sum = ((sum & 1) << 7) &+ (sum >> 1) &+ byte
        }
        return sum
    }

    /// Long-name entries (in on-disk order) followed by the 8.3 entry.
    static func entries(for name: String, index: Int, firstCluster: Int, size: Int) throws -> [[UInt8]] {
        guard !name.isEmpty, name.count <= 255, !name.contains("/") else { throw FATError.invalidName(name) }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let ext = parts.count > 1 ? String(parts.last!) : ""
        let base = parts.count > 1 ? parts.dropLast().joined(separator: ".") : name
        let cleanBase = base.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let short = padded(String(cleanBase.prefix(6)) + "~\(index + 1)", 8) + padded(ext, 3)

        var entries: [[UInt8]] = []
        let units = Array(name.utf16)
        let count = (units.count + 12) / 13
        let checksum = shortNameChecksum(short)
        for seq in stride(from: count, through: 1, by: -1) {
            var entry = [UInt8](repeating: 0, count: 32)
            entry[0] = UInt8(seq) | (seq == count ? 0x40 : 0)
            entry[11] = 0x0f
            entry[13] = checksum
            let positions = [1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30]
            for (i, position) in positions.enumerated() {
                let charIndex = (seq - 1) * 13 + i
                let unit: Int
                if charIndex < units.count {
                    unit = Int(units[charIndex])
                } else if charIndex == units.count {
                    unit = 0x0000
                } else {
                    unit = 0xffff
                }
                put16(&entry, position, unit)
            }
            entries.append(entry)
        }

        var entry = [UInt8](repeating: 0, count: 32)
        entry.replaceSubrange(0..<11, with: short)
        entry[11] = 0x20                               // archive
        put16(&entry, 16, 0x5b6b)                      // date: 2025-11-11
        put16(&entry, 18, 0x5b6b)
        put16(&entry, 24, 0x5b6b)
        put16(&entry, 26, firstCluster)
        put32(&entry, 28, size)
        entries.append(entry)
        return entries
    }
}

/// Windows Setup answer file that removes Windows 11's hardware gates
/// (TPM 2.0, Secure Boot, 4 GB RAM, CPU list, storage) and allows creating
/// a local account without network (OOBE\BypassNRO). Setup stays interactive.
public enum WindowsAnswerFile {
    public static let fileName = "autounattend.xml"

    public static var xml: String {
        let labConfig = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassCPUCheck", "BypassStorageCheck"]
        func setupComponent(_ architecture: String) -> String {
            let commands = labConfig.enumerated().map { index, value in
                """
                        <RunSynchronousCommand wcm:action="add">
                          <Order>\(index + 1)</Order>
                          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(value) /t REG_DWORD /d 1 /f</Path>
                        </RunSynchronousCommand>
                """
            }.joined(separator: "\n")
            return """
                <component name="Microsoft-Windows-Setup" processorArchitecture="\(architecture)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <RunSynchronous>
            \(commands)
                  </RunSynchronous>
                </component>
            """
        }
        func deploymentComponent(_ architecture: String) -> String {
            """
                <component name="Microsoft-Windows-Deployment" processorArchitecture="\(architecture)" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
                  <RunSynchronous>
                    <RunSynchronousCommand wcm:action="add">
                      <Order>1</Order>
                      <Path>reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                    </RunSynchronousCommand>
                  </RunSynchronous>
                </component>
            """
        }
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="windowsPE">
        \(setupComponent("arm64"))
        \(setupComponent("amd64"))
          </settings>
          <settings pass="specialize">
        \(deploymentComponent("arm64"))
        \(deploymentComponent("amd64"))
          </settings>
        </unattend>

        """
    }

    public static func makeDiskImage() throws -> Data {
        try FATImage.make(files: [(fileName, Data(xml.utf8))])
    }
}
