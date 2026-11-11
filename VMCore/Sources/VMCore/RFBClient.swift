import Foundation

/// The guest screen: 32-bit BGRA pixels (little endian, alpha unused).
public final class RFBFramebuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UnsafeMutableRawPointer?
    public private(set) var width = 0
    public private(set) var height = 0
    /// Incremented after each completed update, so views can skip redraws.
    public private(set) var generation: UInt64 = 0

    public init() {}

    deinit { storage?.deallocate() }

    public var bytesPerRow: Int { width * 4 }

    func resize(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard width != self.width || height != self.height else { return }
        storage?.deallocate()
        let bytes = max(width * height * 4, 4)
        storage = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        storage!.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
        self.width = width
        self.height = height
        generation &+= 1
    }

    /// Copies a tightly packed BGRA rectangle into the framebuffer.
    func write(x: Int, y: Int, width w: Int, height h: Int, from source: UnsafeRawPointer) {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, x >= 0, y >= 0, x + w <= width, y + h <= height else { return }
        for row in 0..<h {
            (storage + ((y + row) * width + x) * 4).copyMemory(from: source + row * w * 4, byteCount: w * 4)
        }
    }

    func copyRect(fromX sx: Int, fromY sy: Int, toX dx: Int, toY dy: Int, width w: Int, height h: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard let storage, sx >= 0, sy >= 0, dx >= 0, dy >= 0,
              sx + w <= width, sy + h <= height, dx + w <= width, dy + h <= height else { return }
        let temp = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
        defer { temp.deallocate() }
        for row in 0..<h {
            (temp + row * w * 4).copyMemory(from: storage + ((sy + row) * width + sx) * 4, byteCount: w * 4)
        }
        for row in 0..<h {
            (storage + ((dy + row) * width + dx) * 4).copyMemory(from: temp + row * w * 4, byteCount: w * 4)
        }
    }

    func markUpdated() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    /// Gives locked access to the pixels: (pointer, width, height, bytesPerRow).
    public func withPixels<T>(_ body: (UnsafeRawPointer?, Int, Int, Int) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(storage.map { UnsafeRawPointer($0) }, width, height, width * 4)
    }

    /// Reads one pixel as 0xAARRGGBB (tests and debugging).
    public func pixel(x: Int, y: Int) -> UInt32 {
        withPixels { pointer, w, h, _ in
            guard let pointer, x < w, y < h else { return 0 }
            return pointer.load(fromByteOffset: (y * w + x) * 4, as: UInt32.self)
        }
    }
}

public protocol RFBClientDelegate: AnyObject {
    func rfbClientDidConnect(_ client: RFBClient)
    func rfbClient(_ client: RFBClient, didResizeTo width: Int, height: Int)
    func rfbClientDidUpdate(_ client: RFBClient)
    func rfbClient(_ client: RFBClient, didDisconnectWith error: Error?)
}

/// A minimal RFB (VNC) 3.3–3.8 client for QEMU's local VNC server:
/// security type None, Raw + CopyRect encodings, DesktopSize, and QEMU's
/// extended key events (raw scancodes, keyboard-layout independent).
public final class RFBClient: @unchecked Sendable {
    public enum RFBError: Error, Equatable, LocalizedError {
        case unsupportedVersion(String)
        case unsupportedSecurity
        case serverRefused(String)
        case protocolError(String)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(v): return "Unsupported VNC server version \(v)"
            case .unsupportedSecurity: return "The VNC server requires authentication"
            case let .serverRefused(reason): return "The VNC server refused the connection: \(reason)"
            case let .protocolError(message): return "VNC protocol error: \(message)"
            }
        }
    }

    public enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case desktopSize = -223
        case qemuExtendedKeyEvent = -258
        case extendedDesktopSize = -308
    }

    public let framebuffer = RFBFramebuffer()
    public weak var delegate: RFBClientDelegate?
    public private(set) var serverName = ""
    public private(set) var supportsExtendedKeys = false

    private let socket: UnixSocket
    private var thread: Thread?

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    public func start() {
        let t = Thread { [self] in
            do {
                try handshake()
                delegate?.rfbClientDidConnect(self)
                try runLoop()
            } catch {
                delegate?.rfbClient(self, didDisconnectWith: error)
                return
            }
            delegate?.rfbClient(self, didDisconnectWith: nil)
        }
        t.name = "PocketVM VNC"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func disconnect() {
        socket.close()
    }

    // MARK: Input

    /// Sends a key. `scancode` is a PS/2 set-1 code in QEMU's "qnum" form
    /// (E0-prefixed keys = 0x80 | code). Falls back to the keysym when the
    /// server lacks extended key events.
    public func sendKey(keysym: UInt32, scancode: UInt32, down: Bool) {
        var bytes: [UInt8]
        if supportsExtendedKeys && scancode != 0 {
            bytes = [255, 0]
            bytes += be16(down ? 1 : 0)
            bytes += be32(keysym)
            bytes += be32(scancode)
        } else {
            bytes = [4, down ? 1 : 0, 0, 0]
            bytes += be32(keysym)
        }
        try? socket.write(bytes)
    }

    /// Absolute pointer position (framebuffer pixels) and button mask
    /// (1 = left, 2 = middle, 4 = right, 8/16 = wheel up/down).
    public func sendPointer(x: Int, y: Int, buttons: UInt8) {
        let cx = UInt16(clamping: max(0, min(x, max(framebuffer.width - 1, 0))))
        let cy = UInt16(clamping: max(0, min(y, max(framebuffer.height - 1, 0))))
        var bytes: [UInt8] = [5, buttons]
        bytes += be16(cx)
        bytes += be16(cy)
        try? socket.write(bytes)
    }

    public func requestUpdate(incremental: Bool) {
        var bytes: [UInt8] = [3, incremental ? 1 : 0]
        bytes += be16(0) + be16(0)
        bytes += be16(UInt16(clamping: framebuffer.width)) + be16(UInt16(clamping: framebuffer.height))
        try? socket.write(bytes)
    }

    // MARK: Protocol

    func handshake() throws {
        let versionBytes = try socket.read(12)
        let version = String(decoding: versionBytes, as: UTF8.self)
        guard version.hasPrefix("RFB 003.") else { throw RFBError.unsupportedVersion(version) }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let useMinor = minor >= 8 ? 8 : (minor == 7 ? 7 : 3)
        try socket.write(Array("RFB 003.00\(useMinor)\n".utf8))

        if useMinor == 3 {
            let type = try u32()
            if type == 0 { throw RFBError.serverRefused(try readString()) }
            guard type == 1 else { throw RFBError.unsupportedSecurity }
        } else {
            let count = Int(try socket.read(1)[0])
            if count == 0 { throw RFBError.serverRefused(try readString()) }
            let types = try socket.read(count)
            guard types.contains(1) else { throw RFBError.unsupportedSecurity }
            try socket.write([1])
            if useMinor == 8 {
                let result = try u32()
                if result != 0 { throw RFBError.serverRefused(try readString()) }
            }
        }

        try socket.write([1]) // ClientInit: shared
        let width = Int(try u16())
        let height = Int(try u16())
        _ = try socket.read(16) // server pixel format; we set our own
        serverName = try readString()
        framebuffer.resize(width: width, height: height)
        delegate?.rfbClient(self, didResizeTo: width, height: height)

        // SetPixelFormat: 32 bpp, depth 24, little endian, true colour, BGRA in memory.
        var format: [UInt8] = [0, 0, 0, 0, 32, 24, 0, 1]
        format += be16(255) + be16(255) + be16(255)
        format += [16, 8, 0, 0, 0, 0]
        try socket.write(format)

        let encodings: [Encoding] = [.copyRect, .raw, .desktopSize, .extendedDesktopSize, .qemuExtendedKeyEvent]
        var message: [UInt8] = [2, 0]
        message += be16(UInt16(encodings.count))
        for encoding in encodings { message += be32(UInt32(bitPattern: encoding.rawValue)) }
        try socket.write(message)
        requestUpdate(incremental: false)
    }

    func runLoop() throws {
        while true {
            let type = try socket.read(1)[0]
            switch type {
            case 0:
                try readFramebufferUpdate()
                framebuffer.markUpdated()
                delegate?.rfbClientDidUpdate(self)
                requestUpdate(incremental: true)
            case 1: // SetColourMapEntries (unused with true colour)
                _ = try socket.read(3)
                let count = Int(try u16())
                _ = try socket.read(count * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try socket.read(3)
                let length = Int(Int32(bitPattern: try u32()).magnitude)
                _ = try socket.read(length)
            default:
                throw RFBError.protocolError("unknown server message \(type)")
            }
        }
    }

    private func readFramebufferUpdate() throws {
        _ = try socket.read(1)
        let rects = Int(try u16())
        for _ in 0..<rects {
            let x = Int(try u16()), y = Int(try u16())
            let w = Int(try u16()), h = Int(try u16())
            let encoding = Int32(bitPattern: try u32())
            switch Encoding(rawValue: encoding) {
            case .raw:
                let count = w * h * 4
                guard count > 0 else { continue }
                let temp = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
                defer { temp.deallocate() }
                try socket.read(into: temp, count: count)
                framebuffer.write(x: x, y: y, width: w, height: h, from: temp)
            case .copyRect:
                let sx = Int(try u16()), sy = Int(try u16())
                framebuffer.copyRect(fromX: sx, fromY: sy, toX: x, toY: y, width: w, height: h)
            case .desktopSize:
                framebuffer.resize(width: w, height: h)
                delegate?.rfbClient(self, didResizeTo: w, height: h)
            case .extendedDesktopSize:
                let screens = Int(try socket.read(4)[0])
                _ = try socket.read(screens * 16)
                if w > 0 && h > 0 {
                    framebuffer.resize(width: w, height: h)
                    delegate?.rfbClient(self, didResizeTo: w, height: h)
                }
            case .qemuExtendedKeyEvent:
                supportsExtendedKeys = true
            case nil:
                throw RFBError.protocolError("unsupported encoding \(encoding)")
            }
        }
    }

    // MARK: Helpers

    private func u16() throws -> UInt16 {
        let b = try socket.read(2)
        return UInt16(b[0]) << 8 | UInt16(b[1])
    }

    private func u32() throws -> UInt32 {
        let b = try socket.read(4)
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    private func readString() throws -> String {
        let length = Int(try u32())
        guard length < 1 << 20 else { throw RFBError.protocolError("string too long") }
        return String(decoding: try socket.read(length), as: UTF8.self)
    }
}

@inline(__always) func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
@inline(__always) func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
}
