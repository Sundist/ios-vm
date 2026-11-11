import Foundation
import QEMUShim
import VMCore

/// Locates the embedded QEMU build and starts it in-process.
///
/// QEMU is not compiled by this project: `scripts/fetch-qemu-sysroot.sh`
/// downloads UTM's prebuilt iOS sysroot and the Xcode build embeds its
/// frameworks and data files. Without them the app still runs; QEMU
/// machines then explain how to get the engine.
final class QEMURuntime: @unchecked Sendable {
    static let shared = QEMURuntime()

    enum Flavor: String {
        /// Threaded interpreter (no JIT needed, App Store compatible, slow).
        case tci
        /// TCG JIT; needs JIT enabled by a debugger (sideloaded apps).
        case jit
    }

    private let lock = NSLock()
    private var running = false
    private var finished = false

    var frameworksURL: URL { Bundle.main.privateFrameworksURL ?? Bundle.main.bundleURL.appendingPathComponent("Frameworks") }
    var resourceDirectory: URL { Bundle.main.bundleURL.appendingPathComponent("qemu", isDirectory: true) }

    var flavor: Flavor {
        Flavor(rawValue: Bundle.main.object(forInfoDictionaryKey: "PVMQEMUFlavor") as? String ?? "") ?? .tci
    }

    var isJITEnabled: Bool { pvm_jit_enabled() != 0 }

    func libraryURL(for architecture: QEMUArchitecture) -> URL {
        let name = QEMUArgumentBuilder.libraryName(for: architecture)
        return frameworksURL.appendingPathComponent("\(name).framework/\(name)")
    }

    func isInstalled(_ architecture: QEMUArchitecture) -> Bool {
        FileManager.default.fileExists(atPath: libraryURL(for: architecture).path)
    }

    /// Why a QEMU machine cannot start right now, if anything prevents it.
    func startProblem(for architecture: QEMUArchitecture) -> String? {
        if !isInstalled(architecture) {
            return "This build of PocketVM does not include the QEMU engine. Build it with scripts/fetch-qemu-sysroot.sh or install the IPA from the “QEMU IPA” GitHub Actions workflow."
        }
        if flavor == .jit && !isJITEnabled {
            return "This is the JIT build of the QEMU engine. Enable JIT for PocketVM (for example with StikDebug or SideStore), then start the machine again."
        }
        lock.lock()
        defer { lock.unlock() }
        if running { return "Another QEMU machine is running. Only one QEMU machine can run at a time." }
        if finished { return "QEMU can run only once per app launch. Close PocketVM completely (swipe it away in the app switcher) and open it again." }
        return nil
    }

    /// Starts QEMU. `onExit` runs on the QEMU thread.
    func launch(_ plan: QEMULaunchPlan, onExit: @escaping (Int32) -> Void) throws {
        if let problem = startProblem(for: plan.architecture) {
            throw VMError.invalidImage(problem)
        }
        setenv("TMPDIR", FileManager.default.temporaryDirectory.path, 1)

        let box = Unmanaged.passRetained(ExitBox(handler: { [weak self] status in
            self?.markFinished()
            onExit(status)
        }))
        let argv = [plan.libraryName] + plan.arguments
        let errorSize = 1024
        var error = [CChar](repeating: 0, count: errorSize)
        let cStrings = argv.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let pointers = cStrings.map { UnsafePointer<CChar>($0) }

        lock.lock()
        running = true
        lock.unlock()

        let result = pointers.withUnsafeBufferPointer { buffer in
            pvm_qemu_start(libraryURL(for: plan.architecture).path, Int32(argv.count), buffer.baseAddress,
                           { status, context in
                               let box = Unmanaged<ExitBox>.fromOpaque(context!).takeRetainedValue()
                               box.handler(status)
                           },
                           box.toOpaque(), &error, errorSize)
        }
        if result != 0 {
            box.release()
            lock.lock()
            running = false
            lock.unlock()
            throw VMError.invalidImage("QEMU could not be loaded: \(String(cString: error))")
        }
    }

    private func markFinished() {
        lock.lock()
        running = false
        finished = true
        lock.unlock()
    }

    private final class ExitBox {
        let handler: (Int32) -> Void
        init(handler: @escaping (Int32) -> Void) { self.handler = handler }
    }
}
