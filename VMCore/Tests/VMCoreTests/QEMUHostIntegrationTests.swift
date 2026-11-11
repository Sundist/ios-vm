#if os(macOS)
import XCTest
@testable import VMCore

/// Runs a real QEMU (e.g. Homebrew's) with the command line the app builds,
/// then drives it through our QMP and VNC clients. Opt-in:
///
///     PVM_QEMU_BIN_DIR=/opt/homebrew/bin PVM_QEMU_SHARE=/opt/homebrew/share/qemu swift test
final class QEMUHostIntegrationTests: XCTestCase, RFBClientDelegate {
    private var root: URL!
    private var updates = 0
    private let updateLock = NSLock()
    private var connected: XCTestExpectation?

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PVM_QEMU_BIN_DIR"] != nil else {
            throw XCTSkip("set PVM_QEMU_BIN_DIR and PVM_QEMU_SHARE to run QEMU integration tests")
        }
        // Short path: Unix socket paths are limited to 104 bytes.
        root = URL(fileURLWithPath: "/tmp/pvm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testWindows11ARMCommandLineBootsInQEMU() throws {
        try boot(osType: .windows11ARM)
    }

    func testWindows11x64CommandLineBootsInQEMU() throws {
        try boot(osType: .windows11x64)
    }

    // MARK: RFBClientDelegate

    func rfbClientDidConnect(_ client: RFBClient) { connected?.fulfill() }
    func rfbClient(_ client: RFBClient, didResizeTo width: Int, height: Int) {}
    func rfbClientDidUpdate(_ client: RFBClient) {
        updateLock.lock(); updates += 1; updateLock.unlock()
    }
    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?) {}

    // MARK: Helpers

    private func boot(osType: GuestOSType) throws {
        let env = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: env["PVM_QEMU_BIN_DIR"]!)
        let share = URL(fileURLWithPath: env["PVM_QEMU_SHARE"] ?? "/opt/homebrew/share/qemu")

        let store = try VMStore(rootURL: root.appendingPathComponent("M"))
        var config = VMConfiguration(name: "Integration \(osType.shortName)", osType: osType, memoryMB: 1024)
        try store.createHardDisk(sizeGB: 1, into: &config)
        let iso = root.appendingPathComponent("empty.iso")
        try Data(count: 2048 * 16).write(to: iso)
        try store.attachCDROM(from: iso, into: &config)

        let plan = try store.makeQEMULaunchPlan(for: &config, resourceDirectory: share,
                                                socketDirectory: root.appendingPathComponent("s"))
        let process = Process()
        process.executableURL = binDir.appendingPathComponent("qemu-system-\(plan.architecture.rawValue)")
        process.arguments = plan.arguments
        let log = Pipe()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
        }

        // QMP: capabilities, then query-status must report a running VM.
        let qmp = QMPClient(socket: try waitForSocket(plan.qmpSocket, process: process, log: log))
        let shutdown = expectation(description: "SHUTDOWN event")
        shutdown.assertForOverFulfill = false
        qmp.onEvent = { event, _ in if event == "SHUTDOWN" { shutdown.fulfill() } }
        qmp.start()
        let status = expectation(description: "query-status")
        qmp.execute("query-status") { result in
            if case let .success(value) = result, (value as? [String: Any])?["status"] as? String == "running" {
                status.fulfill()
            }
        }
        wait(for: [status], timeout: 30)

        // VNC: handshake, a framebuffer, QEMU's extended key events.
        connected = expectation(description: "VNC connected")
        let rfb = RFBClient(socket: try waitForSocket(plan.vncSocket, process: process, log: log))
        rfb.delegate = self
        rfb.start()
        wait(for: [connected!], timeout: 30)

        let deadline = Date().addingTimeInterval(120)
        var sawPixels = false
        while Date() < deadline && !sawPixels {
            Thread.sleep(forTimeInterval: 0.5)
            sawPixels = rfb.framebuffer.withPixels { pointer, width, height, bytesPerRow in
                guard let pointer, width > 0, height > 0 else { return false }
                let bytes = pointer.assumingMemoryBound(to: UInt8.self)
                for offset in stride(from: 0, to: bytesPerRow * height, by: 4) where bytes[offset] | bytes[offset + 1] | bytes[offset + 2] != 0 {
                    return true
                }
                return false
            }
        }
        XCTAssertTrue(sawPixels, "the guest screen stayed black")
        XCTAssertGreaterThan(rfb.framebuffer.width, 0)
        XCTAssertTrue(rfb.supportsExtendedKeys, "QEMU acknowledges extended key events")
        updateLock.lock(); let updateCount = updates; updateLock.unlock()
        XCTAssertGreaterThan(updateCount, 0)

        // Input goes through without breaking the connection.
        rfb.sendPointer(x: 10, y: 10, buttons: 1)
        rfb.sendPointer(x: 10, y: 10, buttons: 0)
        let escape = GuestKey.named["Escape"]!
        rfb.sendKey(keysym: escape.keysym, scancode: escape.scancode, down: true)
        rfb.sendKey(keysym: escape.keysym, scancode: escape.scancode, down: false)

        // CD change through QMP uses the device id the app relies on.
        let eject = expectation(description: "eject")
        qmp.execute("eject", arguments: ["id": "cddev", "force": true]) { result in
            if case let .failure(error) = result { XCTFail("eject failed: \(error)") }
            eject.fulfill()
        }
        wait(for: [eject], timeout: 30)

        qmp.execute("quit")
        wait(for: [shutdown], timeout: 30)
        let exitDeadline = Date().addingTimeInterval(30)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertFalse(process.isRunning, "QEMU did not exit after quit")
        rfb.disconnect()
        qmp.close()
    }

    private func waitForSocket(_ url: URL, process: Process, log: Pipe) throws -> UnixSocket {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if !process.isRunning {
                let output = String(decoding: log.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                XCTFail("QEMU exited early: \(output)")
                throw UnixSocket.SocketError.closed
            }
            if let socket = try? UnixSocket.connect(path: url.path) { return socket }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw UnixSocket.SocketError.system("timed out waiting for \(url.path)")
    }
}
#endif
