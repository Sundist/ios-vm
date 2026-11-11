import Foundation

/// A small VT100-ish terminal model for the serial console. It understands
/// the control sequences a Linux shell commonly emits (cursor movement,
/// erase line / screen, SGR) and keeps a bounded scrollback.
public struct TerminalBuffer {
    public private(set) var lines: [[Character]] = [[]]
    public private(set) var row = 0
    public private(set) var column = 0
    public let maxLines: Int
    /// Rows considered "the screen" for absolute cursor positioning.
    public var screenRows = 24

    private enum ParseState { case normal, escape, csi, osc, oscEscape }
    private var state = ParseState.normal
    private var csiParameters = ""
    private var utf8Pending: [UInt8] = []
    private var utf8Expected = 0

    public init(maxLines: Int = 2000) {
        self.maxLines = max(maxLines, 10)
    }

    public var text: String {
        lines.map { String($0) }.joined(separator: "\n")
    }

    public mutating func clear() {
        lines = [[]]
        row = 0
        column = 0
    }

    public mutating func feed<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        for byte in bytes { feed(byte) }
    }

    public mutating func feed(_ byte: UInt8) {
        switch state {
        case .normal:
            handleNormal(byte)
        case .escape:
            switch byte {
            case UInt8(ascii: "["): state = .csi; csiParameters = ""
            case UInt8(ascii: "]"): state = .osc
            case UInt8(ascii: "c"): clear(); state = .normal
            default: state = .normal
            }
        case .csi:
            if byte >= 0x40 && byte <= 0x7e {
                performCSI(final: byte)
                state = .normal
            } else {
                csiParameters.append(Character(Unicode.Scalar(byte)))
                if csiParameters.count > 32 { state = .normal }
            }
        case .osc:
            if byte == 0x07 { state = .normal } else if byte == 0x1b { state = .oscEscape }
        case .oscEscape:
            state = .normal
        }
    }

    private mutating func handleNormal(_ byte: UInt8) {
        if utf8Expected > 0 {
            if byte & 0xc0 == 0x80 {
                utf8Pending.append(byte)
                if utf8Pending.count == utf8Expected {
                    let s = String(decoding: utf8Pending, as: UTF8.self)
                    utf8Pending.removeAll()
                    utf8Expected = 0
                    for ch in s { put(ch) }
                }
                return
            }
            utf8Pending.removeAll()
            utf8Expected = 0
        }

        switch byte {
        case 0x1b: state = .escape
        case 0x0a: lineFeed()
        case 0x0d: column = 0
        case 0x08: column = max(0, column - 1)
        case 0x09:
            let next = (column / 8 + 1) * 8
            while column < next { put(" ") }
        case 0x07, 0x00: break
        case 0x01...0x1f, 0x7f: break
        case 0x20...0x7e: put(Character(Unicode.Scalar(byte)))
        case 0xc0...0xdf: utf8Pending = [byte]; utf8Expected = 2
        case 0xe0...0xef: utf8Pending = [byte]; utf8Expected = 3
        case 0xf0...0xf7: utf8Pending = [byte]; utf8Expected = 4
        default: put("\u{FFFD}")
        }
    }

    private mutating func put(_ ch: Character) {
        while lines[row].count < column { lines[row].append(" ") }
        if column < lines[row].count {
            lines[row][column] = ch
        } else {
            lines[row].append(ch)
        }
        column += 1
    }

    private mutating func lineFeed() {
        row += 1
        if row == lines.count { lines.append([]) }
        trimScrollback()
    }

    private mutating func trimScrollback() {
        let excess = lines.count - maxLines
        if excess > 0 {
            lines.removeFirst(excess)
            row = max(0, row - excess)
        }
    }

    private var screenTop: Int { max(0, lines.count - screenRows) }

    private mutating func performCSI(final: UInt8) {
        let params = csiParameters
            .trimmingCharacters(in: CharacterSet(charactersIn: "?>"))
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) }
        func param(_ index: Int, default value: Int) -> Int {
            guard index < params.count, let v = params[index] else { return value }
            return v
        }

        switch final {
        case UInt8(ascii: "A"):
            row = max(screenTop, row - max(1, param(0, default: 1)))
        case UInt8(ascii: "B"):
            row = min(lines.count - 1, row + max(1, param(0, default: 1)))
        case UInt8(ascii: "C"):
            column += max(1, param(0, default: 1))
        case UInt8(ascii: "D"):
            column = max(0, column - max(1, param(0, default: 1)))
        case UInt8(ascii: "G"):
            column = max(0, param(0, default: 1) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            let top = screenTop
            let targetRow = top + max(0, param(0, default: 1) - 1)
            while lines.count <= targetRow { lines.append([]) }
            row = targetRow
            column = max(0, param(1, default: 1) - 1)
            trimScrollback()
        case UInt8(ascii: "K"):
            switch param(0, default: 0) {
            case 0:
                if column < lines[row].count { lines[row].removeSubrange(column...) }
            case 1:
                for i in 0..<min(column + 1, lines[row].count) { lines[row][i] = " " }
            default:
                lines[row].removeAll()
            }
        case UInt8(ascii: "J"):
            switch param(0, default: 0) {
            case 0:
                if column < lines[row].count { lines[row].removeSubrange(column...) }
                if row + 1 < lines.count { lines.removeSubrange((row + 1)...) }
            case 2, 3:
                clear()
            default:
                break
            }
        default:
            break // SGR (m), modes (h/l), etc. are ignored.
        }
    }
}
