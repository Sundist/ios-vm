import XCTest
@testable import VMCore

final class TerminalBufferTests: XCTestCase {
    func testPlainTextAndNewlines() {
        var t = TerminalBuffer()
        t.feed(Array("hello\r\nworld".utf8))
        XCTAssertEqual(t.text, "hello\nworld")
    }

    func testCarriageReturnOverwritesAndEraseLine() {
        var t = TerminalBuffer()
        t.feed(Array("progress 10%\rprogress 99%".utf8))
        XCTAssertEqual(t.text, "progress 99%")
        t.feed(Array("\r\u{1b}[Kdone".utf8))
        XCTAssertEqual(t.text, "done")
    }

    func testBackspaceAndColorsAreHandled() {
        var t = TerminalBuffer()
        t.feed(Array("ab\u{8} \u{8}c \u{1b}[1;32mgreen\u{1b}[0m".utf8))
        XCTAssertEqual(t.text, "ac green")
    }

    func testClearScreen() {
        var t = TerminalBuffer()
        t.feed(Array("junk\r\nmore".utf8))
        t.feed(Array("\u{1b}[H\u{1b}[2Jfresh".utf8))
        XCTAssertEqual(t.text, "fresh")
    }

    func testUTF8Decoding() {
        var t = TerminalBuffer()
        t.feed(Array("Merhaba dünya — ğüşiöç".utf8))
        XCTAssertEqual(t.text, "Merhaba dünya — ğüşiöç")
    }

    func testScrollbackIsBounded() {
        var t = TerminalBuffer(maxLines: 10)
        for i in 0..<100 { t.feed(Array("line \(i)\n".utf8)) }
        XCTAssertEqual(t.lines.count, 10)
        XCTAssertTrue(t.text.contains("line 99"))
        XCTAssertFalse(t.text.contains("line 50"))
    }
}

final class DeviceTreeTests: XCTestCase {
    private func be32(_ data: Data, _ offset: Int) -> UInt32 {
        data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func testHeaderIsConsistent() {
        let dtb = DeviceTree.makeBoardTree(memorySize: 0x3ff_c000, bootArguments: "console=ttyS0")
        XCTAssertEqual(be32(dtb, 0), 0xd00d_feed)
        XCTAssertEqual(Int(be32(dtb, 4)), dtb.count)
        let structOffset = Int(be32(dtb, 8))
        let stringsOffset = Int(be32(dtb, 12))
        XCTAssertEqual(be32(dtb, 20), 17)
        XCTAssertEqual(structOffset + Int(be32(dtb, 36)), stringsOffset)
        XCTAssertEqual(stringsOffset + Int(be32(dtb, 32)), dtb.count)
        XCTAssertEqual(be32(dtb, structOffset), 1)            // FDT_BEGIN_NODE
        XCTAssertEqual(be32(dtb, stringsOffset - 4), 9)       // FDT_END
        XCTAssertLessThan(dtb.count, Int(RV32Machine.deviceTreeReserve))
        let blob = String(decoding: dtb, as: UTF8.self)
        XCTAssertTrue(blob.contains("console=ttyS0"))
        XCTAssertTrue(blob.contains("riscv,clint0"))
        XCTAssertTrue(blob.contains("ns16550a"))
    }
}

final class VMStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSaveLoadCloneDelete() throws {
        let store = try VMStore(rootURL: root)
        var config = VMConfiguration(name: "Test", osType: .linuxRV32)
        try store.save(config)
        XCTAssertNotNil(config.startProblem)                  // no kernel yet

        let kernelSource = root.appendingPathComponent("Image")
        try Data([0x13, 0, 0, 0]).write(to: kernelSource)
        try store.importKernel(from: kernelSource, into: &config)
        XCTAssertEqual(config.kernelByteCount, 4)
        XCTAssertNil(config.startProblem)

        let loaded = store.loadAll()
        XCTAssertEqual(loaded.map(\.id), [config.id])
        XCTAssertEqual(loaded.first?.kernelFileName, VMStore.kernelFileName)

        let copy = try store.clone(config, name: "Copy")
        XCTAssertEqual(store.loadAll().count, 2)
        XCTAssertNotNil(store.kernelURL(for: copy))

        try store.delete(config.id)
        XCTAssertEqual(store.loadAll().map(\.id), [copy.id])
    }

    func testSnapshotsAndEngine() throws {
        let store = try VMStore(rootURL: root)
        var config = VMConfiguration(name: "Monitor", osType: .builtInMonitor, memoryMB: 2)
        try store.save(config)

        let engine = try store.makeEngine(for: config)
        try engine.powerOn()
        let deadline = Date().addingTimeInterval(5)
        var output = ""
        while !output.contains("monitor> ") && Date() < deadline {
            usleep(10_000)
            output += String(decoding: engine.drainOutput(), as: UTF8.self)
        }
        XCTAssertTrue(output.contains("monitor> "))
        XCTAssertEqual(engine.state, .running)

        let done = expectation(description: "snapshot")
        var captured = Data()
        engine.snapshot { data in
            captured = data
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        let info = try store.addSnapshot(captured, named: "Booted", to: &config)
        XCTAssertEqual(config.snapshots.count, 1)
        XCTAssertEqual(try store.snapshotData(info, of: config), captured)

        engine.sendInput([4]) // Ctrl-D
        let offDeadline = Date().addingTimeInterval(5)
        while engine.state == .running && Date() < offDeadline { usleep(10_000) }
        XCTAssertEqual(engine.state, .poweredOff)

        // Restore and keep using the console.
        try engine.powerOn(restoring: captured)
        engine.sendInput("x")
        var restoredOutput = ""
        let echoDeadline = Date().addingTimeInterval(5)
        while !restoredOutput.contains("x") && Date() < echoDeadline {
            usleep(10_000)
            restoredOutput += String(decoding: engine.drainOutput(), as: UTF8.self)
        }
        XCTAssertTrue(restoredOutput.contains("x"))
        engine.powerOff()
        XCTAssertEqual(engine.state, .poweredOff)

        try store.deleteSnapshot(info, from: &config)
        XCTAssertTrue(config.snapshots.isEmpty)
    }
}

final class PCConfigurationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDecodesConfigurationsFromTheFirstVersion() throws {
        let json = """
        {"id":"7C9A1D2E-1111-4222-8333-944455556666","name":"Old","osType":"builtInMonitor",
         "memoryMB":8,"bootArguments":"","notes":"","createdAt":"2026-11-11T06:00:00Z","snapshots":[]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config = try decoder.decode(VMConfiguration.self, from: Data(json.utf8))
        XCTAssertEqual(config.name, "Old")
        XCTAssertEqual(config.osType, .builtInMonitor)
        XCTAssertFalse(config.hasSavedState)
        XCTAssertEqual(config.bootDevice, .automatic)
        XCTAssertNil(config.hardDiskFileName)
    }

    func testPCMachineNeedsBootMedia() throws {
        let store = try VMStore(rootURL: root)
        var config = VMConfiguration(name: "XP", osType: .windowsNT)
        XCTAssertEqual(config.platform, .pc)
        XCTAssertEqual(config.memoryMB, 512)
        XCTAssertFalse(config.acpiEnabled)
        XCTAssertNotNil(config.startProblem)

        try store.createHardDisk(sizeGB: 1, into: &config)
        XCTAssertNil(config.startProblem)
        XCTAssertEqual(config.hardDiskByteCount, 1 << 30)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.hardDiskURL(for: config)!.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 1 << 30)

        let iso = root.appendingPathComponent("install.iso")
        try Data(repeating: 0x41, count: 4096).write(to: iso)
        try store.attachCDROM(from: iso, into: &config)
        XCTAssertEqual(config.cdromName, "install.iso")
        let resolved = try store.resolveCDROM(for: &config)
        XCTAssertEqual(resolved?.standardizedFileURL.path, iso.standardizedFileURL.path)

        config.bootDevice = .cdrom
        let plan = try store.makePCBootPlan(for: config, cdromURL: resolved, restoreState: true)
        XCTAssertFalse(plan.restoreState)                 // no saved state yet
        let page = plan.pageConfiguration()
        XCTAssertEqual(page["memoryMB"] as? Int, 512)
        XCTAssertEqual(page["bootOrder"] as? Int, 0x123)
        XCTAssertEqual((page["cdrom"] as? [String: Any])?["size"] as? Int64, 4096)
        XCTAssertEqual((page["hda"] as? [String: Any])?["size"] as? Int64, 1 << 30)
        XCTAssertNoThrow(try plan.pageConfigurationJSON())

        // Saved state lifecycle.
        let tmp = root.appendingPathComponent("state.tmp")
        try Data([1, 2, 3]).write(to: tmp)
        try store.commitSavedState(from: tmp, into: &config)
        XCTAssertTrue(config.hasSavedState)
        XCTAssertTrue(try store.makePCBootPlan(for: config, cdromURL: resolved, restoreState: true).restoreState)
        try store.discardSavedState(of: &config)
        XCTAssertFalse(config.hasSavedState)

        // Clone copies the disk but not the saved state.
        let copy = try store.clone(config, name: "XP 2")
        XCTAssertNotNil(store.hardDiskURL(for: copy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.hardDiskURL(for: copy)!.path))
    }

    func testRawDiskImportValidatesSize() throws {
        let store = try VMStore(rootURL: root)
        var config = VMConfiguration(name: "DOS", osType: .dosX86)
        try store.save(config)
        let bad = root.appendingPathComponent("bad.img")
        try Data(count: 1000).write(to: bad)
        XCTAssertThrowsError(try store.importHardDisk(from: bad, into: &config))
        let good = root.appendingPathComponent("good.img")
        try Data(count: 2048).write(to: good)
        try store.importHardDisk(from: good, into: &config)
        XCTAssertEqual(config.hardDiskByteCount, 2048)
    }

    func testStartURLRoundTrip() {
        let id = UUID()
        XCTAssertEqual(MachineCatalog.machineID(from: MachineCatalog.startURL(for: id)), id)
        XCTAssertEqual(MachineCatalog.machineID(from: URL(string: "pocketvm://start/\(id.uuidString)")!), id)
        XCTAssertNil(MachineCatalog.machineID(from: URL(string: "https://example.com/start?id=\(id.uuidString)")!))
    }
}
