import Foundation

/// A small QEMU Machine Protocol client (JSON lines over a Unix socket).
public final class QMPClient: @unchecked Sendable {
    public struct QMPError: Error, Equatable, LocalizedError {
        public var errorClass: String
        public var message: String
        public var errorDescription: String? { "\(message) (\(errorClass))" }
    }

    public typealias Completion = (Result<Any, Error>) -> Void

    /// Called on the reader thread for asynchronous events (SHUTDOWN, STOP…).
    public var onEvent: ((String, [String: Any]) -> Void)?
    public var onDisconnect: ((Error?) -> Void)?

    private let socket: UnixSocket
    private let lock = NSLock()
    private var ready = false
    private var queued: [[UInt8]] = []
    private var pending: [Int: Completion] = [:]
    private var nextID = 1

    public init(socket: UnixSocket) {
        self.socket = socket
    }

    public func start() {
        let t = Thread { [self] in
            do {
                _ = try socket.readLine()                     // greeting
                try send(["execute": "qmp_capabilities", "id": 0], raw: true)
                while true {
                    let line = try socket.readLine()
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    handle(object)
                }
            } catch {
                failAll(error)
                onDisconnect?(error)
            }
        }
        t.name = "PocketVM QMP"
        t.start()
    }

    public func close() {
        socket.close()
    }

    /// Sends a command; `completion` runs on the reader thread.
    public func execute(_ command: String, arguments: [String: Any]? = nil, completion: Completion? = nil) {
        lock.lock()
        let id = nextID
        nextID += 1
        if let completion { pending[id] = completion }
        lock.unlock()
        var message: [String: Any] = ["execute": command, "id": id]
        if let arguments { message["arguments"] = arguments }
        do {
            try send(message, raw: false)
        } catch {
            lock.lock()
            let callback = pending.removeValue(forKey: id)
            lock.unlock()
            callback?(.failure(error))
        }
    }

    // MARK: Private

    private func send(_ message: [String: Any], raw: Bool) throws {
        var bytes = Array(try JSONSerialization.data(withJSONObject: message))
        bytes.append(0x0a)
        lock.lock()
        if !raw && !ready {
            queued.append(bytes)
            lock.unlock()
            return
        }
        lock.unlock()
        try socket.write(bytes)
    }

    private func handle(_ object: [String: Any]) {
        if let event = object["event"] as? String {
            onEvent?(event, object["data"] as? [String: Any] ?? [:])
            return
        }
        let id = (object["id"] as? NSNumber)?.intValue ?? -1
        if id == 0 {
            // qmp_capabilities answered: flush commands sent meanwhile.
            lock.lock()
            ready = true
            let toSend = queued
            queued.removeAll()
            lock.unlock()
            for bytes in toSend { try? socket.write(bytes) }
            return
        }
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        if let error = object["error"] as? [String: Any] {
            callback?(.failure(QMPError(errorClass: error["class"] as? String ?? "GenericError",
                                        message: error["desc"] as? String ?? "unknown error")))
        } else {
            callback?(.success(object["return"] ?? [:]))
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let callbacks = pending.values
        pending.removeAll()
        lock.unlock()
        callbacks.forEach { $0(.failure(error)) }
    }
}

/// Key codes for the VNC client: X11 keysyms plus PS/2 set-1 scancodes in
/// QEMU's "qnum" form (E0-prefixed keys = 0x80 | code). US layout.
public enum GuestKey {
    public struct Code: Equatable, Sendable {
        public var keysym: UInt32
        public var scancode: UInt32
    }

    public static let named: [String: Code] = [
        "Escape": Code(keysym: 0xff1b, scancode: 0x01),
        "Backspace": Code(keysym: 0xff08, scancode: 0x0e),
        "Tab": Code(keysym: 0xff09, scancode: 0x0f),
        "Enter": Code(keysym: 0xff0d, scancode: 0x1c),
        "Space": Code(keysym: 0x20, scancode: 0x39),
        "ControlLeft": Code(keysym: 0xffe3, scancode: 0x1d),
        "ShiftLeft": Code(keysym: 0xffe1, scancode: 0x2a),
        "AltLeft": Code(keysym: 0xffe9, scancode: 0x38),
        "MetaLeft": Code(keysym: 0xffeb, scancode: 0xdb),
        "ContextMenu": Code(keysym: 0xff67, scancode: 0xdd),
        "CapsLock": Code(keysym: 0xffe5, scancode: 0x3a),
        "Insert": Code(keysym: 0xff63, scancode: 0xd2),
        "Delete": Code(keysym: 0xffff, scancode: 0xd3),
        "Home": Code(keysym: 0xff50, scancode: 0xc7),
        "End": Code(keysym: 0xff57, scancode: 0xcf),
        "PageUp": Code(keysym: 0xff55, scancode: 0xc9),
        "PageDown": Code(keysym: 0xff56, scancode: 0xd1),
        "ArrowUp": Code(keysym: 0xff52, scancode: 0xc8),
        "ArrowDown": Code(keysym: 0xff54, scancode: 0xd0),
        "ArrowLeft": Code(keysym: 0xff51, scancode: 0xcb),
        "ArrowRight": Code(keysym: 0xff53, scancode: 0xcd),
        "F1": Code(keysym: 0xffbe, scancode: 0x3b), "F2": Code(keysym: 0xffbf, scancode: 0x3c),
        "F3": Code(keysym: 0xffc0, scancode: 0x3d), "F4": Code(keysym: 0xffc1, scancode: 0x3e),
        "F5": Code(keysym: 0xffc2, scancode: 0x3f), "F6": Code(keysym: 0xffc3, scancode: 0x40),
        "F7": Code(keysym: 0xffc4, scancode: 0x41), "F8": Code(keysym: 0xffc5, scancode: 0x42),
        "F9": Code(keysym: 0xffc6, scancode: 0x43), "F10": Code(keysym: 0xffc7, scancode: 0x44),
        "F11": Code(keysym: 0xffc8, scancode: 0x57), "F12": Code(keysym: 0xffc9, scancode: 0x58),
    ]

    // US layout: unshifted and shifted characters per scancode.
    private static let rows: [(UInt32, Character, Character)] = [
        (0x02, "1", "!"), (0x03, "2", "@"), (0x04, "3", "#"), (0x05, "4", "$"), (0x06, "5", "%"),
        (0x07, "6", "^"), (0x08, "7", "&"), (0x09, "8", "*"), (0x0a, "9", "("), (0x0b, "0", ")"),
        (0x0c, "-", "_"), (0x0d, "=", "+"), (0x1a, "[", "{"), (0x1b, "]", "}"), (0x27, ";", ":"),
        (0x28, "'", "\""), (0x29, "`", "~"), (0x2b, "\\", "|"), (0x33, ",", "<"), (0x34, ".", ">"),
        (0x35, "/", "?"),
        (0x10, "q", "Q"), (0x11, "w", "W"), (0x12, "e", "E"), (0x13, "r", "R"), (0x14, "t", "T"),
        (0x15, "y", "Y"), (0x16, "u", "U"), (0x17, "i", "I"), (0x18, "o", "O"), (0x19, "p", "P"),
        (0x1e, "a", "A"), (0x1f, "s", "S"), (0x20, "d", "D"), (0x21, "f", "F"), (0x22, "g", "G"),
        (0x23, "h", "H"), (0x24, "j", "J"), (0x25, "k", "K"), (0x26, "l", "L"),
        (0x2c, "z", "Z"), (0x2d, "x", "X"), (0x2e, "c", "C"), (0x2f, "v", "V"), (0x30, "b", "B"),
        (0x31, "n", "N"), (0x32, "m", "M"),
    ]

    private static let characters: [Character: (code: Code, shift: Bool)] = {
        var map: [Character: (code: Code, shift: Bool)] = [:]
        for (scancode, plain, shifted) in rows {
            map[plain] = (Code(keysym: plain.unicodeScalars.first!.value, scancode: scancode), false)
            map[shifted] = (Code(keysym: shifted.unicodeScalars.first!.value, scancode: scancode), true)
        }
        map[" "] = (named["Space"]!, false)
        map["\n"] = (named["Enter"]!, false)
        map["\r"] = (named["Enter"]!, false)
        map["\t"] = (named["Tab"]!, false)
        return map
    }()

    /// The key (and whether Shift is needed) that types `character` on a US layout.
    public static func forCharacter(_ character: Character) -> (code: Code, shift: Bool)? {
        if let entry = characters[character] { return entry }
        // Other Latin-1 characters: keysym only (no scancode).
        if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, scalar.value < 0x100 {
            return (Code(keysym: scalar.value, scancode: 0), false)
        }
        return nil
    }
}
