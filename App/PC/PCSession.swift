import Foundation
import Observation
import UIKit
import VMCore
import WebKit

/// A running x86 PC: v86 inside a WKWebView (WebKit may JIT-compile
/// WebAssembly on iOS, which third-party native code may not), with disk
/// writes and saved states persisted by the app.
@MainActor
@Observable
final class PCSession: Identifiable {
    let id: UUID
    private(set) var state: VMEngine.State = .stopped
    private(set) var statusMessage: String?
    private(set) var instructionsPerSecond: Double = 0
    private(set) var activeModifiers: Set<String> = []
    private(set) var isSavingState = false
    /// Non-fatal problem reported by the page (shown as a banner).
    var warning: String?

    let webView: WKWebView
    @ObservationIgnored private let resources: PCResourceHandler
    @ObservationIgnored private let bridge: PCBridge
    @ObservationIgnored private let diskWriter = DiskWriter()
    @ObservationIgnored private var plan: PCBootPlan?
    @ObservationIgnored private var accessedURLs: [URL] = []
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var booted = false
    @ObservationIgnored private var guestReady = false
    @ObservationIgnored private var stateFile: (url: URL, handle: FileHandle)?
    @ObservationIgnored private var saveContinuation: CheckedContinuation<URL, Error>?
    @ObservationIgnored private var powerOffWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called once a saved state has been loaded into the guest.
    @ObservationIgnored var onStateRestored: (() -> Void)?
    /// Called when a saved state could not be restored.
    @ObservationIgnored var onRestoreFailed: ((String) -> Void)?

    init(id: UUID) {
        self.id = id
        let resources = PCResourceHandler()
        let bridge = PCBridge()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(resources, forURLScheme: PCResourceHandler.scheme)
        configuration.userContentController.add(bridge, name: "pvm")
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        if #available(iOS 16.4, *) {
            webView.isInspectable = true   // debug with Safari › Develop
        }
        webView.navigationDelegate = bridge

        self.resources = resources
        self.bridge = bridge
        self.webView = webView
        bridge.session = self
    }

    var speedDescription: String {
        String(format: "%.0f MIPS", instructionsPerSecond / 1_000_000)
    }

    // MARK: Power

    /// Starts the machine. `accessing` are security-scoped URLs that stay
    /// open until the machine powers off.
    func start(plan: PCBootPlan, accessing: [URL]) throws {
        self.plan = plan
        accessedURLs = accessing
        for drive in PCDrive.allCases {
            resources.setMedia(drive.rawValue, url: plan.drives[drive]?.url)
        }
        resources.setMedia("state", url: plan.stateURL)
        if let hda = plan.drives[.hda] {
            try diskWriter.open(hda.url)
        }
        state = .running
        statusMessage = plan.restoreState ? "Restoring saved state…" : "Starting…"
        if pageReady {
            boot()
        } else {
            webView.load(URLRequest(url: PCResourceHandler.pageURL))
        }
    }

    func pause() { run("pvm.pause()") }
    func resume() { run("pvm.resume()") }
    func reset() { run("pvm.reset()") }

    /// Flushes pending disk writes and stops the machine.
    func powerOff() async {
        guard state.isActive else { return }
        statusMessage = "Powering off…"
        run("pvm.powerOff()")
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.finishPowerOff()   // the page did not answer
        }
        await withCheckedContinuation { powerOffWaiters.append($0) }
    }

    /// Saves the complete machine state, then powers off. Returns the
    /// temporary file holding the state.
    func saveStateAndPowerOff() async throws -> URL {
        guard state.isActive, saveContinuation == nil else {
            throw VMError.invalidSnapshot("the machine is not running")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocketvm-\(UUID().uuidString).state")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw VMError.invalidSnapshot("could not create a temporary file")
        }
        stateFile = (url, try FileHandle(forWritingTo: url))
        isSavingState = true
        statusMessage = "Saving state…"
        run("pvm.saveState()")
        return try await withCheckedThrowingContinuation { saveContinuation = $0 }
    }

    /// Immediate stop without flushing (used when deleting the machine).
    func terminate() {
        finishPowerOff()
    }

    // MARK: Input

    func type(_ text: String) { run("pvm.text(\(jsString(text)))") }
    func press(_ keys: [String]) { run("pvm.keys(\(jsArray(keys)))") }
    func sendCtrlAltDel() { run("pvm.ctrlAltDel()") }

    func toggleModifier(_ name: String) {
        let on = !activeModifiers.contains(name)
        activeModifiers = on ? activeModifiers.union([name]) : activeModifiers.subtracting([name])
        run("pvm.latch(\(jsString(name)), \(on))")
    }

    // MARK: CD-ROM

    func insertCD(url: URL, size: Int64) {
        resources.setMedia("cdrom", url: url)
        accessedURLs.append(url)
        run("pvm.insertCD({size: \(size)})")
    }

    func ejectCD() {
        run("pvm.ejectCD()")
    }

    // MARK: Page messages

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "pageReady":
            pageReady = true
            boot()
        case "ready":
            guestReady = true
            statusMessage = nil
            if body["restored"] as? Bool == true { onStateRestored?() }
        case "running":
            guard state.isActive, !isSavingState else { break }
            state = (body["running"] as? Bool ?? true) ? .running : .paused
        case "stats":
            instructionsPerSecond = (body["ips"] as? NSNumber)?.doubleValue ?? 0
        case "modifiers":
            activeModifiers = Set(body["active"] as? [String] ?? [])
        case "diskWrite":
            handleDiskWrite(body)
        case "stateChunk":
            appendStateChunk(body)
        case "stateDone":
            finishSavedState()
        case "stateFailed":
            failSavedState(body["message"] as? String ?? "unknown error")
        case "poweredOff":
            if body["clean"] as? Bool == false {
                warning = "Some disk writes could not be saved."
            }
            finishPowerOff()
        case "bootFailed", "error":
            handlePageError(body["message"] as? String ?? "unknown error")
        default:
            break
        }
    }

    fileprivate func webContentTerminated() {
        let reason = "iOS stopped the emulator (most likely it ran out of memory). Try less base memory."
        if isSavingState { failSavedState(reason) }
        finishPowerOff()
        state = .halted(reason)
    }

    private func boot() {
        guard let plan, !booted else { return }
        booted = true
        do {
            run("pvm.boot(\(try plan.pageConfigurationJSON()))")
        } catch {
            state = .halted(error.localizedDescription)
        }
    }

    private func handlePageError(_ message: String) {
        if !guestReady {
            if plan?.restoreState == true {
                onRestoreFailed?(message)
                finishPowerOff()
                state = .halted("The saved state could not be restored: \(message)")
            } else {
                finishPowerOff()
                state = .halted(message)
            }
        } else {
            warning = message
        }
    }

    private func handleDiskWrite(_ body: [String: Any]) {
        guard let disk = body["disk"] as? String,
              let id = (body["id"] as? NSNumber)?.intValue,
              let offset = (body["offset"] as? NSNumber)?.int64Value,
              let data = body["data"] as? String else { return }
        diskWriter.write(base64: data, offset: offset) { [weak self] ok in
            if !ok { self?.warning = "Writing to the hard disk image failed (is the device full?)" }
            self?.run("pvm.ack(\(self?.jsString(disk) ?? "''"), \(id), \(ok))")
        }
    }

    private func appendStateChunk(_ body: [String: Any]) {
        guard let file = stateFile, let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else {
            failSavedState("invalid state data")
            return
        }
        do {
            try file.handle.write(contentsOf: data)
        } catch {
            failSavedState(error.localizedDescription)
        }
    }

    private func finishSavedState() {
        guard let file = stateFile else { return }
        try? file.handle.close()
        stateFile = nil
        isSavingState = false
        saveContinuation?.resume(returning: file.url)
        saveContinuation = nil
    }

    private func failSavedState(_ message: String) {
        if let file = stateFile {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.url)
        }
        stateFile = nil
        isSavingState = false
        statusMessage = nil
        saveContinuation?.resume(throwing: VMError.invalidSnapshot(message))
        saveContinuation = nil
    }

    private func finishPowerOff() {
        if state.isActive || state == .stopped {
            state = .poweredOff
        }
        statusMessage = nil
        instructionsPerSecond = 0
        diskWriter.close()
        for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
        accessedURLs.removeAll()
        let waiters = powerOffWaiters
        powerOffWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if isSavingState { failSavedState("the machine stopped while saving") }
    }

    // MARK: JavaScript helpers

    private func run(_ script: String) {
        webView.evaluateJavaScript(script + "; true", completionHandler: nil)
    }

    private func jsString(_ value: String) -> String {
        (try? String(decoding: JSONEncoder().encode(value), as: UTF8.self)) ?? "\"\""
    }

    private func jsArray(_ values: [String]) -> String {
        (try? String(decoding: JSONEncoder().encode(values), as: UTF8.self)) ?? "[]"
    }
}

/// Receives messages from the page; kept separate so the web view's
/// content controller does not retain the session.
@MainActor
final class PCBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var session: PCSession?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        session?.handle(body)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        session?.webContentTerminated()
    }
}

/// Serialised writes into the hard disk image.
final class DiskWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "PocketVM.DiskWriter", qos: .userInitiated)
    private var handle: FileHandle?

    func open(_ url: URL) throws {
        let h = try FileHandle(forUpdating: url)
        queue.sync { handle = h }
    }

    func write(base64: String, offset: Int64, completion: @escaping @MainActor (Bool) -> Void) {
        queue.async {
            var ok = false
            if let handle = self.handle, let data = Data(base64Encoded: base64) {
                do {
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: data)
                    ok = true
                } catch {
                    ok = false
                }
            }
            Task { @MainActor in completion(ok) }
        }
    }

    func close() {
        queue.sync {
            if let handle {
                try? handle.synchronize()
                try? handle.close()
            }
            handle = nil
        }
    }
}
