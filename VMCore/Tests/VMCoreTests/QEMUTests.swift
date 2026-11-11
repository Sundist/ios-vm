import XCTest
@testable import VMCore

final class QEMUArgumentTests: XCTestCase {
    private var root: URL!
    private var resources: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        resources = root.appendingPathComponent("qemu")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for name in ["edk2-aarch64-code.fd", "edk2-arm-vars.fd", "edk2-x86_64-code.fd", "edk2-i386-vars.fd"] {
            try Data(repeating: 0, count: 1024).write(to: resources.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func value(after flag: String, in args: [String]) -> [String] {
        args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { args[$0 + 1] }
    }

    func testWindows11ARMPlan() throws {
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "Win, 11", osType: .windows11ARM)
        XCTAssertEqual(config.platform, .qemu)
        XCTAssertEqual(config.memoryMB, 4096)
        XCTAssertTrue(config.bypassWindowsRequirements)
        try store.createHardDisk(sizeGB: 1, into: &config)
        let iso = root.appendingPathComponent("Win11_ARM64.iso")
        try Data(count: 4096).write(to: iso)
        try store.attachCDROM(from: iso, into: &config)

        let plan = try store.makeQEMULaunchPlan(for: &config, resourceDirectory: resources,
                                                socketDirectory: root.appendingPathComponent("s"))
        let args = plan.arguments
        XCTAssertEqual(plan.libraryName, "qemu-aarch64-softmmu")
        XCTAssertEqual(value(after: "-machine", in: args), ["virt"])
        XCTAssertEqual(value(after: "-cpu", in: args), ["max,pauth-impdef=on"])
        XCTAssertEqual(value(after: "-m", in: args), ["4096"])
        XCTAssertEqual(value(after: "-smp", in: args), ["2"])
        XCTAssertTrue(value(after: "-accel", in: args)[0].hasPrefix("tcg,tb-size="))
        let devices = value(after: "-device", in: args)
        XCTAssertTrue(devices.contains("ramfb"))
        XCTAssertTrue(devices.contains("usb-tablet,bus=xhci.0"))
        XCTAssertTrue(devices.contains { $0.hasPrefix("nvme,drive=hd0") })
        XCTAssertTrue(devices.contains("usb-bot,id=cdbot,bus=xhci.0"))
        XCTAssertTrue(devices.contains { $0.hasPrefix("scsi-cd,bus=cdbot.0,drive=cd0,id=cddev") })
        XCTAssertTrue(devices.contains { $0.hasPrefix("usb-storage,drive=ans0") }, "answer disk attached")
        let drives = value(after: "-drive", in: args)
        XCTAssertTrue(drives.contains { $0.contains("edk2-aarch64-code.fd") && $0.contains("readonly=on") })
        XCTAssertTrue(drives.contains { $0.contains("Win11_ARM64.iso") && $0.contains("media=cdrom") })
        XCTAssertEqual(value(after: "-name", in: args), ["Win, 11"])
        XCTAssertTrue(value(after: "-vnc", in: args)[0].hasPrefix("unix:"))
        XCTAssertTrue(value(after: "-qmp", in: args)[0].hasSuffix(",server=on,wait=off"))
        XCTAssertLessThan(plan.vncSocket.path.utf8.count, 104)

        // UEFI variables were created from the template; the answer disk exists.
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.efiVariablesURL(for: config.id).path))
        let answer = store.directory(for: config.id).appendingPathComponent(VMStore.answerDiskFileName)
        XCTAssertEqual(try Data(contentsOf: answer).count, FATImage.totalSectors * FATImage.sectorSize)
        plan.accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    func testWindows11x64Plan() throws {
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "W11", osType: .windows11x64)
        config.cpuCount = 1
        config.bypassWindowsRequirements = false
        try store.createHardDisk(sizeGB: 1, into: &config)
        let plan = try store.makeQEMULaunchPlan(for: &config, resourceDirectory: resources,
                                                socketDirectory: root.appendingPathComponent("s"), splitWX: true,
                                                relativeSocketPaths: true)
        let args = plan.arguments
        XCTAssertEqual(plan.libraryName, "qemu-x86_64-softmmu")
        XCTAssertEqual(value(after: "-machine", in: args), ["q35,vmport=off"])
        XCTAssertEqual(value(after: "-accel", in: args), ["tcg,tb-size=256,split-wx=on"])
        let devices = value(after: "-device", in: args)
        XCTAssertTrue(devices.contains("VGA,vgamem_mb=64"))
        XCTAssertTrue(devices.contains("e1000e,netdev=net0"))
        XCTAssertTrue(devices.contains { $0.hasPrefix("ide-cd,id=cddev") })
        XCTAssertFalse(devices.contains { $0.contains("ans0") })
        // Relative socket names keep long container paths under the 104-byte limit.
        XCTAssertEqual(value(after: "-vnc", in: args), ["unix:\(plan.vncSocket.lastPathComponent)"])
        XCTAssertTrue(value(after: "-qmp", in: args)[0].hasPrefix("unix:\(plan.qmpSocket.lastPathComponent),"))
        XCTAssertEqual(plan.socketDirectory.standardizedFileURL.path, root.appendingPathComponent("s").standardizedFileURL.path)
    }

    func testMissingFirmwareIsReported() throws {
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "L", osType: .linuxARM64)
        try store.createHardDisk(sizeGB: 1, into: &config)
        XCTAssertThrowsError(try store.makeQEMULaunchPlan(
            for: &config, resourceDirectory: root.appendingPathComponent("nothing"),
            socketDirectory: root.appendingPathComponent("s")))
    }

    func testQcow2VariableTemplatesAreDetected() throws {
        // UTM's iOS sysroot ships edk2 variable templates as qcow2.
        var qcow2 = Data([0x51, 0x46, 0x49, 0xfb, 0, 0, 0, 3])
        qcow2.append(Data(count: 1024))
        try qcow2.write(to: resources.appendingPathComponent("edk2-arm-vars.fd"))
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "L", osType: .linuxARM64)
        try store.createHardDisk(sizeGB: 1, into: &config)
        let plan = try store.makeQEMULaunchPlan(for: &config, resourceDirectory: resources,
                                                socketDirectory: root.appendingPathComponent("s"))
        let drives = value(after: "-drive", in: plan.arguments)
        XCTAssertTrue(drives.contains { $0.hasPrefix("if=pflash,format=qcow2,unit=1,") }, "\(drives)")
        XCTAssertTrue(drives.contains { $0.hasPrefix("if=pflash,format=raw,unit=0,") })
        XCTAssertEqual(QEMUArgumentBuilder.detectImageFormat(resources.appendingPathComponent("edk2-aarch64-code.fd")), "raw")
    }

    func testCommasInPathsAreEscaped() {
        XCTAssertEqual(QEMUArgumentBuilder.escape("/a,b/c.iso"), "/a,,b/c.iso")
    }
}

final class FATImageTests: XCTestCase {
    func testAnswerDiskLayout() throws {
        let image = [UInt8](try WindowsAnswerFile.makeDiskImage())
        XCTAssertEqual(image.count, 1_474_560)
        XCTAssertEqual(image[510], 0x55)
        XCTAssertEqual(image[511], 0xaa)
        XCTAssertEqual(Array(image[54..<62]), Array("FAT12   ".utf8))

        // FAT: media descriptor, and the file's cluster chain ends with 0xFFF.
        let fat = Array(image[512..<(512 + 9 * 512)])
        XCTAssertEqual(FATImage.getFAT(fat, 0), 0xff0)
        XCTAssertEqual(FATImage.getFAT(fat, 1), 0xfff)
        let xml = Data(WindowsAnswerFile.xml.utf8)
        let clusters = (xml.count + 511) / 512
        for c in 0..<(clusters - 1) { XCTAssertEqual(FATImage.getFAT(fat, 2 + c), 3 + c) }
        XCTAssertEqual(FATImage.getFAT(fat, 1 + clusters), 0xfff)
        XCTAssertEqual(Array(image[512..<(512 + 9 * 512)]), Array(image[(10 * 512)..<(19 * 512)]), "both FATs match")

        // Root directory: label, two LFN entries, then the 8.3 entry.
        let root = 19 * 512
        XCTAssertEqual(image[root + 11], 0x08)
        XCTAssertEqual(image[root + 32], 0x42)                   // last LFN entry, sequence 2
        XCTAssertEqual(image[root + 32 + 11], 0x0f)
        XCTAssertEqual(image[root + 64], 0x01)
        let short = Array(image[(root + 96)..<(root + 107)])
        XCTAssertEqual(String(decoding: short, as: UTF8.self), "AUTOUN~1XML")
        XCTAssertEqual(image[root + 32 + 13], FATImage.shortNameChecksum(short))
        let size = Int(image[root + 96 + 28]) | Int(image[root + 96 + 29]) << 8
        XCTAssertEqual(size, xml.count)

        // File contents start at the first data sector.
        let data = 33 * 512
        XCTAssertEqual(Data(image[data..<(data + xml.count)]), xml)
    }

    func testAnswerFileContainsBypasses() {
        let xml = WindowsAnswerFile.xml
        for key in ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck", "BypassNRO"] {
            XCTAssertTrue(xml.contains(key), key)
        }
        XCTAssertTrue(xml.contains("processorArchitecture=\"arm64\""))
        XCTAssertTrue(xml.contains("processorArchitecture=\"amd64\""))
    }
}

final class RFBClientTests: XCTestCase, RFBClientDelegate {
    private var connected: XCTestExpectation?
    private var updated: XCTestExpectation?
    private var resized: [(Int, Int)] = []

    func rfbClientDidConnect(_ client: RFBClient) { connected?.fulfill() }
    func rfbClient(_ client: RFBClient, didResizeTo width: Int, height: Int) { resized.append((width, height)) }
    func rfbClientDidUpdate(_ client: RFBClient) { updated?.fulfill() }
    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?) {}

    func testHandshakeUpdatesAndInput() throws {
        let (clientSide, server) = try UnixSocket.pair()
        let client = RFBClient(socket: clientSide)
        client.delegate = self
        connected = expectation(description: "connected")
        updated = expectation(description: "updated")

        try server.write(Array("RFB 003.008\n".utf8))
        client.start()
        XCTAssertEqual(String(decoding: try server.read(12), as: UTF8.self), "RFB 003.008\n")
        try server.write([1, 1])                          // one security type: None
        XCTAssertEqual(try server.read(1), [1])
        try server.write([0, 0, 0, 0])                    // SecurityResult OK
        XCTAssertEqual(try server.read(1), [1])           // ClientInit shared
        var initMessage: [UInt8] = [0, 4, 0, 2]           // 4 x 2
        initMessage += [UInt8](repeating: 0, count: 16)
        initMessage += [0, 0, 0, 4] + Array("QEMU".utf8)
        try server.write(initMessage)
        wait(for: [connected!], timeout: 5)
        XCTAssertEqual(client.serverName, "QEMU")

        let pixelFormat = try server.read(20)
        XCTAssertEqual(pixelFormat[0], 0)
        XCTAssertEqual(pixelFormat[4], 32)
        let encodingsHeader = try server.read(4)
        XCTAssertEqual(encodingsHeader[0], 2)
        let count = Int(encodingsHeader[3])
        let encodings = try server.read(count * 4)
        XCTAssertTrue(encodings.contains(0xfe))           // -258 (0xfffffefe)
        XCTAssertEqual(try server.read(10)[0], 3)         // full update request

        // Update: ext-key ack + a 2x1 raw rect at (1,1).
        var update: [UInt8] = [0, 0, 0, 2]
        update += [0, 0, 0, 0, 0, 0, 0, 0] + be32(UInt32(bitPattern: -258))
        update += [0, 1, 0, 1, 0, 2, 0, 1] + be32(0)
        update += [0x11, 0x22, 0x33, 0x00, 0x44, 0x55, 0x66, 0x00]
        try server.write(update)
        wait(for: [updated!], timeout: 5)
        XCTAssertTrue(client.supportsExtendedKeys)
        XCTAssertEqual(client.framebuffer.pixel(x: 1, y: 1), 0x0033_2211)
        XCTAssertEqual(client.framebuffer.pixel(x: 2, y: 1), 0x0066_5544)
        XCTAssertEqual(try server.read(10)[0..<2], [3, 1]) // incremental request follows

        client.sendKey(keysym: 0x61, scancode: 0x1e, down: true)
        XCTAssertEqual(try server.read(12), [255, 0, 0, 1, 0, 0, 0, 0x61, 0, 0, 0, 0x1e])
        client.sendPointer(x: 3, y: 9, buttons: 1)       // y is clamped to height - 1
        XCTAssertEqual(try server.read(6), [5, 1, 0, 3, 0, 1])

        // DesktopSize change.
        updated = expectation(description: "resized")
        try server.write([0, 0, 0, 1, 0, 0, 0, 0, 0, 8, 0, 6] + be32(UInt32(bitPattern: -223)))
        wait(for: [updated!], timeout: 5)
        XCTAssertEqual(client.framebuffer.width, 8)
        XCTAssertEqual(client.framebuffer.height, 6)
        XCTAssertEqual(resized.last?.0, 8)
        client.disconnect()
        server.close()
    }
}

final class QMPClientTests: XCTestCase {
    func testCapabilitiesCommandsAndEvents() throws {
        let (clientSide, server) = try UnixSocket.pair()
        let qmp = QMPClient(socket: clientSide)
        let event = expectation(description: "event")
        qmp.onEvent = { name, _ in if name == "SHUTDOWN" { event.fulfill() } }

        try server.write(Array(#"{"QMP": {"version": {}, "capabilities": []}}"#.utf8) + [0x0a])
        qmp.start()
        let answered = expectation(description: "answer")
        qmp.execute("query-status") { result in
            if case let .success(value) = result, let dict = value as? [String: Any], dict["status"] as? String == "running" {
                answered.fulfill()
            }
        }

        let capabilities = try JSONSerialization.jsonObject(with: Data(try server.readLine())) as! [String: Any]
        XCTAssertEqual(capabilities["execute"] as? String, "qmp_capabilities")
        try server.write(Array(#"{"return": {}, "id": 0}"#.utf8) + [0x0a])

        let command = try JSONSerialization.jsonObject(with: Data(try server.readLine())) as! [String: Any]
        XCTAssertEqual(command["execute"] as? String, "query-status")
        let id = (command["id"] as! NSNumber).intValue
        try server.write(Array(#"{"event": "SHUTDOWN", "data": {"guest": true}}"#.utf8) + [0x0a])
        try server.write(Array("{\"return\": {\"status\": \"running\"}, \"id\": \(id)}".utf8) + [0x0a])
        wait(for: [event, answered], timeout: 5)
        qmp.close()
        server.close()
    }
}

final class GuestKeyTests: XCTestCase {
    func testUSLayoutMapping() {
        XCTAssertEqual(GuestKey.forCharacter("a")?.code.scancode, 0x1e)
        XCTAssertEqual(GuestKey.forCharacter("A")?.shift, true)
        XCTAssertEqual(GuestKey.forCharacter("@")?.code.scancode, 0x03)
        XCTAssertEqual(GuestKey.forCharacter("\n")?.code.keysym, 0xff0d)
        XCTAssertEqual(GuestKey.named["ArrowRight"]?.scancode, 0xcd)
        XCTAssertEqual(GuestKey.forCharacter("é")?.code.scancode, 0)   // keysym only
        XCTAssertNil(GuestKey.forCharacter("ğ"))
    }
}
