import UIKit
import XCTest
@testable import PocketVM
import VMCore

/// End-to-end checks that run inside the app (iOS Simulator in CI):
/// the real WKWebView + v86 PC engine and, when the simulator QEMU sysroot
/// was embedded, the in-process QEMU engine.
@MainActor
final class EngineSmokeTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func hostWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first
    }

    /// Boots a boot sector with v86 that prints what is in LBA 2 and then
    /// overwrites it with "WRITTEN!". Passing means: the page and v86 load
    /// from the private URL scheme, Range reads work, guest disk writes go
    /// through the JavaScript bridge and land in the image file.
    func testPCEngineBootsAndPersistsDiskWrites() async throws {
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "Boot sector", osType: .dosX86, memoryMB: 16)
        try store.save(config)

        var image = Data(count: 1024 * 1024)
        let bootSector = try Data(contentsOf: Bundle(for: Self.self).url(forResource: "bootsector", withExtension: "bin")!)
        image.replaceSubrange(0..<bootSector.count, with: bootSector)
        image.replaceSubrange(1024..<1032, with: Data("ORIGINAL".utf8))
        let source = root.appendingPathComponent("disk.img")
        try image.write(to: source)
        try store.importHardDisk(from: source, into: &config)

        let plan = try store.makePCBootPlan(for: config, cdromURL: nil, restoreState: false)
        let session = PCSession(id: config.id)
        if let window = hostWindow() {
            session.webView.frame = window.bounds
            window.addSubview(session.webView)
        }
        defer { session.webView.removeFromSuperview() }
        try session.start(plan: plan, accessing: [])

        let disk = store.hardDiskURL(for: config)!
        let deadline = Date().addingTimeInterval(180)
        var written = false
        while Date() < deadline && !written {
            try await Task.sleep(nanoseconds: 500_000_000)
            if case let .halted(reason) = session.state { XCTFail("PC engine halted: \(reason)"); break }
            let handle = try FileHandle(forReadingFrom: disk)
            try handle.seek(toOffset: 1024)
            written = try handle.read(upToCount: 8) == Data("WRITTEN!".utf8)
            try handle.close()
        }
        XCTAssertTrue(written, "the guest's disk write did not reach the image file (warning: \(session.warning ?? "none"))")
        await session.powerOff()
        XCTAssertEqual(session.state, .poweredOff)
    }

    /// Starts the embedded QEMU (simulator sysroot) with the app's command
    /// line and checks the screen and control channels. Skipped when the
    /// build has no QEMU engine. QEMU can run once per process, so this is
    /// the only QEMU test.
    func testQEMUEngineStartsAndShowsTheScreen() async throws {
        let runtime = QEMURuntime.shared
        guard runtime.isInstalled(.aarch64) else {
            throw XCTSkip("this build does not embed the QEMU engine")
        }
        let store = try VMStore(rootURL: root.appendingPathComponent("Machines"))
        var config = VMConfiguration(name: "QEMU smoke", osType: .linuxARM64, memoryMB: 512)
        config.cpuCount = 1
        try store.createHardDisk(sizeGB: 1, into: &config)

        let plan = try store.makeQEMULaunchPlan(
            for: &config,
            resourceDirectory: runtime.resourceDirectory,
            socketDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("q", isDirectory: true),
            relativeSocketPaths: true)
        let session = QEMUSession(id: config.id)
        try session.start(plan: plan)

        let deadline = Date().addingTimeInterval(240)
        var sawPixels = false
        while Date() < deadline && !sawPixels {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if case let .halted(reason) = session.state { XCTFail("QEMU halted: \(reason)"); break }
            guard let framebuffer = session.rfb?.framebuffer else { continue }
            sawPixels = framebuffer.withPixels { pointer, width, height, bytesPerRow in
                guard let pointer, width > 0, height > 0 else { return false }
                let bytes = pointer.assumingMemoryBound(to: UInt8.self)
                for offset in stride(from: 0, to: bytesPerRow * height, by: 4) where bytes[offset] | bytes[offset + 1] | bytes[offset + 2] != 0 {
                    return true
                }
                return false
            }
        }
        XCTAssertTrue(sawPixels, "no QEMU screen content (warning: \(session.warning ?? "none"))")
        XCTAssertEqual(session.state, .running)
        XCTAssertGreaterThan(session.screenSize.width, 0)

        // The guest CPU really executes: its program counter moves.
        func programCounter() async -> String? {
            guard let registers = await session.monitor("info registers") else { return nil }
            guard let range = registers.range(of: #"PC=[0-9a-fA-F]+"#, options: .regularExpression) else { return nil }
            return String(registers[range])
        }
        var counters = Set<String>()
        for _ in 0..<10 {
            if let pc = await programCounter() { counters.insert(pc) }
            if counters.count > 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertGreaterThan(counters.count, 1, "the guest program counter did not change: \(counters)")

        session.pause()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertEqual(session.state, .paused, "QMP stop was not acknowledged with a STOP event")
        session.resume()

        session.powerOff()
        let exitDeadline = Date().addingTimeInterval(60)
        while session.state.isActive && Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(session.state, .poweredOff, "QEMU did not exit cleanly after quit")
    }
}
