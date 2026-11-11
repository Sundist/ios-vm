import Foundation
import WebKit

/// Serves the PC page, the v86 runtime and the machine's disk images to the
/// web view through the private `pvm-local://vm/...` scheme. Disk images are
/// read lazily with HTTP `Range` requests, so multi-GB ISOs and disks never
/// have to be loaded into memory.
final class PCResourceHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "pvm-local"
    static let pageURL = URL(string: "\(scheme)://vm/index.html")!

    private let webRoot: URL
    private let lock = NSLock()
    private var media: [String: URL] = [:]
    private var stoppedTasks = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "PocketVM.PCResources", qos: .userInitiated, attributes: .concurrent)

    override init() {
        webRoot = Bundle.main.resourceURL!.appendingPathComponent("PCWeb", isDirectory: true)
        super.init()
    }

    /// Makes `url` available as `pvm-local://vm/media/<name>`.
    func setMedia(_ name: String, url: URL?) {
        lock.lock()
        media[name] = url
        lock.unlock()
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let range = task.request.value(forHTTPHeaderField: "Range")

        let fileURL: URL?
        if path.hasPrefix("/media/") {
            lock.lock()
            fileURL = media[String(path.dropFirst("/media/".count))]
            lock.unlock()
        } else {
            let relative = path.split(separator: "/").filter { $0 != ".." }.joined(separator: "/")
            fileURL = webRoot.appendingPathComponent(relative.isEmpty ? "index.html" : relative)
        }

        guard let fileURL else {
            respond(task, url: url, status: 404, headers: [:], body: Data())
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                let (status, headers, body) = try Self.read(fileURL, range: range)
                self.respond(task, url: url, status: status, headers: headers, body: body)
            } catch {
                self.respond(task, url: url, status: 404, headers: [:], body: Data())
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.insert(ObjectIdentifier(task))
        lock.unlock()
    }

    // MARK: Helpers

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, headers: [String: String], body: Data) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stopped = self.stoppedTasks.remove(ObjectIdentifier(task)) != nil
            self.lock.unlock()
            if stopped { return }

            var all = headers
            all["Content-Length"] = String(body.count)
            all["Access-Control-Allow-Origin"] = "*"
            all["Cache-Control"] = "no-store"
            if all["Content-Type"] == nil {
                all["Content-Type"] = Self.mimeType(for: url.pathExtension)
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: all)!
            task.didReceive(response)
            if !body.isEmpty { task.didReceive(body) }
            task.didFinish()
        }
    }

    private static func read(_ url: URL, range: String?) throws -> (Int, [String: String], Data) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let total = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard let range, let bounds = parse(range: range, total: total) else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return (200, ["Accept-Ranges": "bytes"], data)
        }
        let (start, end) = bounds

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: Int(end - start + 1)) ?? Data()
        let last = start + Int64(data.count) - 1
        return (206, [
            "Accept-Ranges": "bytes",
            "Content-Range": "bytes \(start)-\(max(last, start))/\(total)",
            "Content-Type": "application/octet-stream",
        ], data)
    }

    /// Parses `bytes=START-END` (END optional), clamped to the file.
    static func parse(range: String, total: Int64) -> (Int64, Int64)? {
        guard range.hasPrefix("bytes="), total > 0 else { return nil }
        let spec = range.dropFirst("bytes=".count).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)) ?? (total - 1)
        guard start >= 0, start < total, end >= start else { return nil }
        return (start, min(end, total - 1))
    }

    static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "wasm": return "application/wasm"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }
}
