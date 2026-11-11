import Foundation

/// Serialises the full machine state (CPU, devices and RAM) so a running
/// guest can be saved and restored later, like VirtualBox snapshots.
extension RV32Machine {
    private static let snapshotMagic: UInt32 = 0x534d_5650 // "PVMS"
    private static let snapshotVersion: UInt32 = 1

    public func makeSnapshot() -> Data {
        var w = ByteWriter()
        w.u32(Self.snapshotMagic)
        w.u32(Self.snapshotVersion)
        w.u32(ramSize)
        w.u32(pc)
        for i in 0..<32 { w.u32(x[i]) }
        w.u32(mstatus); w.u32(mscratch); w.u32(mtvec); w.u32(mie); w.u32(mip)
        w.u32(mepc); w.u32(mtval); w.u32(mcause); w.u32(privilege)
        w.u32(waitingForInterrupt ? 1 : 0)
        w.u32(hasReservation ? 1 : 0)
        w.u32(reservationAddress)
        w.u32(UInt32(uartLCR))
        w.u64(cycle); w.u64(mtime); w.u64(mtimecmp)
        var data = w.data
        data.append(Data(bytes: ram, count: Int(ramSize)))
        return data
    }

    public func restore(from data: Data) throws {
        var r = ByteReader(data: data)
        guard try r.u32() == Self.snapshotMagic else { throw VMError.invalidSnapshot("bad magic") }
        guard try r.u32() == Self.snapshotVersion else { throw VMError.invalidSnapshot("unsupported version") }
        let size = try r.u32()
        guard size == ramSize else {
            throw VMError.invalidSnapshot("snapshot has \(size / (1024 * 1024)) MB RAM, machine has \(ramSize / (1024 * 1024)) MB")
        }
        pc = try r.u32()
        for i in 0..<32 { x[i] = try r.u32() }
        x[0] = 0
        mstatus = try r.u32(); mscratch = try r.u32(); mtvec = try r.u32()
        mie = try r.u32(); mip = try r.u32(); mepc = try r.u32()
        mtval = try r.u32(); mcause = try r.u32(); privilege = try r.u32() & 3
        waitingForInterrupt = try r.u32() != 0
        hasReservation = try r.u32() != 0
        reservationAddress = try r.u32()
        uartLCR = UInt8(truncatingIfNeeded: try r.u32())
        cycle = try r.u64(); mtime = try r.u64(); mtimecmp = try r.u64()
        let ramBytes = try r.bytes(Int(ramSize))
        ramBytes.withUnsafeBytes { buf in
            ram.copyMemory(from: buf.baseAddress!, byteCount: Int(ramSize))
        }
    }
}

struct ByteWriter {
    var data = Data()
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
}

struct ByteReader {
    let data: Data
    var offset: Int

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.endIndex else { throw VMError.invalidSnapshot("truncated") }
        let slice = data[offset..<(offset + count)]
        offset += count
        return slice
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return b.reduce(into: (UInt32(0), UInt32(0))) { acc, byte in
            acc.0 |= UInt32(byte) << acc.1
            acc.1 += 8
        }.0
    }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        let hi = UInt64(try u32())
        return lo | (hi << 32)
    }
}
