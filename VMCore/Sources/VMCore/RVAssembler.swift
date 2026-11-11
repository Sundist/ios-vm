import Foundation

/// RISC-V integer register names.
public enum Reg: UInt32 {
    case zero = 0, ra, sp, gp, tp, t0, t1, t2, s0, s1
    case a0, a1, a2, a3, a4, a5, a6, a7
    case s2, s3, s4, s5, s6, s7, s8, s9, s10, s11
    case t3, t4, t5, t6
}

/// A tiny two-pass RV32 assembler with labels. Used to build the built-in
/// monitor firmware and the unit tests, so no external toolchain is needed.
public struct RVAssembler {
    private enum Fixup {
        case branch(funct3: UInt32, rs1: Reg, rs2: Reg)
        case jal(rd: Reg)
        case la(rd: Reg)   // occupies two words: AUIPC + ADDI
    }

    public private(set) var bytes: [UInt8] = []
    private var labels: [String: Int] = [:]
    private var fixups: [(offset: Int, label: String, kind: Fixup)] = []

    public init() {}

    public var position: Int { bytes.count }

    public mutating func label(_ name: String) {
        precondition(labels[name] == nil, "duplicate label \(name)")
        labels[name] = bytes.count
    }

    public mutating func emit(_ word: UInt32) {
        precondition(bytes.count % 4 == 0, "instruction not word aligned")
        bytes.append(UInt8(truncatingIfNeeded: word))
        bytes.append(UInt8(truncatingIfNeeded: word >> 8))
        bytes.append(UInt8(truncatingIfNeeded: word >> 16))
        bytes.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    // MARK: Data

    public mutating func ascii(_ string: String, terminated: Bool = true) {
        bytes.append(contentsOf: Array(string.utf8))
        if terminated { bytes.append(0) }
    }

    public mutating func word(_ value: UInt32) {
        align(4)
        emit(value)
    }

    public mutating func align(_ boundary: Int) {
        while bytes.count % boundary != 0 { bytes.append(0) }
    }

    // MARK: Encoders

    public static func r(_ funct7: UInt32, _ rs2: Reg, _ rs1: Reg, _ funct3: UInt32, _ rd: Reg, _ opcode: UInt32) -> UInt32 {
        (funct7 << 25) | (rs2.rawValue << 20) | (rs1.rawValue << 15) | (funct3 << 12) | (rd.rawValue << 7) | opcode
    }

    public static func i(_ imm: Int32, _ rs1: Reg, _ funct3: UInt32, _ rd: Reg, _ opcode: UInt32) -> UInt32 {
        precondition(imm >= -2048 && imm <= 2047, "I-immediate out of range")
        return ((UInt32(bitPattern: imm) & 0xfff) << 20) | (rs1.rawValue << 15) | (funct3 << 12) | (rd.rawValue << 7) | opcode
    }

    public static func s(_ imm: Int32, _ rs2: Reg, _ rs1: Reg, _ funct3: UInt32) -> UInt32 {
        precondition(imm >= -2048 && imm <= 2047, "S-immediate out of range")
        let u = UInt32(bitPattern: imm)
        return (((u >> 5) & 0x7f) << 25) | (rs2.rawValue << 20) | (rs1.rawValue << 15) | (funct3 << 12) | ((u & 0x1f) << 7) | 0x23
    }

    public static func b(_ imm: Int32, _ rs2: Reg, _ rs1: Reg, _ funct3: UInt32) -> UInt32 {
        precondition(imm >= -4096 && imm <= 4094 && imm & 1 == 0, "B-immediate out of range")
        let u = UInt32(bitPattern: imm)
        return (((u >> 12) & 1) << 31) | (((u >> 5) & 0x3f) << 25) | (rs2.rawValue << 20) | (rs1.rawValue << 15)
            | (funct3 << 12) | (((u >> 1) & 0xf) << 8) | (((u >> 11) & 1) << 7) | 0x63
    }

    public static func u(_ imm20: UInt32, _ rd: Reg, _ opcode: UInt32) -> UInt32 {
        ((imm20 & 0xfffff) << 12) | (rd.rawValue << 7) | opcode
    }

    public static func j(_ imm: Int32, _ rd: Reg) -> UInt32 {
        precondition(imm >= -(1 << 20) && imm < (1 << 20) && imm & 1 == 0, "J-immediate out of range")
        let u = UInt32(bitPattern: imm)
        return (((u >> 20) & 1) << 31) | (((u >> 1) & 0x3ff) << 21) | (((u >> 11) & 1) << 20)
            | (((u >> 12) & 0xff) << 12) | (rd.rawValue << 7) | 0x6f
    }

    // MARK: Instructions

    public mutating func lui(_ rd: Reg, _ imm20: UInt32) { emit(Self.u(imm20, rd, 0x37)) }
    public mutating func auipc(_ rd: Reg, _ imm20: UInt32) { emit(Self.u(imm20, rd, 0x17)) }

    public mutating func addi(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 0, rd, 0x13)) }
    public mutating func slti(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 2, rd, 0x13)) }
    public mutating func sltiu(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 3, rd, 0x13)) }
    public mutating func xori(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 4, rd, 0x13)) }
    public mutating func ori(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 6, rd, 0x13)) }
    public mutating func andi(_ rd: Reg, _ rs1: Reg, _ imm: Int32) { emit(Self.i(imm, rs1, 7, rd, 0x13)) }
    public mutating func slli(_ rd: Reg, _ rs1: Reg, _ shamt: Int32) { emit(Self.i(shamt & 31, rs1, 1, rd, 0x13)) }
    public mutating func srli(_ rd: Reg, _ rs1: Reg, _ shamt: Int32) { emit(Self.i(shamt & 31, rs1, 5, rd, 0x13)) }
    public mutating func srai(_ rd: Reg, _ rs1: Reg, _ shamt: Int32) { emit(Self.i((shamt & 31) | 0x400, rs1, 5, rd, 0x13)) }

    public mutating func add(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 0, rd, 0x33)) }
    public mutating func sub(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0x20, rs2, rs1, 0, rd, 0x33)) }
    public mutating func sll(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 1, rd, 0x33)) }
    public mutating func slt(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 2, rd, 0x33)) }
    public mutating func sltu(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 3, rd, 0x33)) }
    public mutating func xor(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 4, rd, 0x33)) }
    public mutating func srl(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 5, rd, 0x33)) }
    public mutating func sra(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0x20, rs2, rs1, 5, rd, 0x33)) }
    public mutating func or(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 6, rd, 0x33)) }
    public mutating func and(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(0, rs2, rs1, 7, rd, 0x33)) }

    public mutating func mul(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 0, rd, 0x33)) }
    public mutating func mulh(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 1, rd, 0x33)) }
    public mutating func mulhu(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 3, rd, 0x33)) }
    public mutating func div(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 4, rd, 0x33)) }
    public mutating func divu(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 5, rd, 0x33)) }
    public mutating func rem(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 6, rd, 0x33)) }
    public mutating func remu(_ rd: Reg, _ rs1: Reg, _ rs2: Reg) { emit(Self.r(1, rs2, rs1, 7, rd, 0x33)) }

    public mutating func lb(_ rd: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.i(imm, rs1, 0, rd, 0x03)) }
    public mutating func lh(_ rd: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.i(imm, rs1, 1, rd, 0x03)) }
    public mutating func lw(_ rd: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.i(imm, rs1, 2, rd, 0x03)) }
    public mutating func lbu(_ rd: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.i(imm, rs1, 4, rd, 0x03)) }
    public mutating func lhu(_ rd: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.i(imm, rs1, 5, rd, 0x03)) }
    public mutating func sb(_ rs2: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.s(imm, rs2, rs1, 0)) }
    public mutating func sh(_ rs2: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.s(imm, rs2, rs1, 1)) }
    public mutating func sw(_ rs2: Reg, _ imm: Int32, _ rs1: Reg) { emit(Self.s(imm, rs2, rs1, 2)) }

    public mutating func jalr(_ rd: Reg, _ rs1: Reg, _ imm: Int32 = 0) { emit(Self.i(imm, rs1, 0, rd, 0x67)) }
    public mutating func ret() { jalr(.zero, .ra, 0) }

    public mutating func csrrw(_ rd: Reg, _ csr: UInt32, _ rs1: Reg) { emit((csr << 20) | (rs1.rawValue << 15) | (1 << 12) | (rd.rawValue << 7) | 0x73) }
    public mutating func csrrs(_ rd: Reg, _ csr: UInt32, _ rs1: Reg) { emit((csr << 20) | (rs1.rawValue << 15) | (2 << 12) | (rd.rawValue << 7) | 0x73) }
    public mutating func csrrc(_ rd: Reg, _ csr: UInt32, _ rs1: Reg) { emit((csr << 20) | (rs1.rawValue << 15) | (3 << 12) | (rd.rawValue << 7) | 0x73) }
    public mutating func csrrwi(_ rd: Reg, _ csr: UInt32, _ uimm: UInt32) { emit((csr << 20) | ((uimm & 31) << 15) | (5 << 12) | (rd.rawValue << 7) | 0x73) }
    public mutating func csrrsi(_ rd: Reg, _ csr: UInt32, _ uimm: UInt32) { emit((csr << 20) | ((uimm & 31) << 15) | (6 << 12) | (rd.rawValue << 7) | 0x73) }

    public mutating func ecall() { emit(0x0000_0073) }
    public mutating func ebreak() { emit(0x0010_0073) }
    public mutating func mret() { emit(0x3020_0073) }
    public mutating func wfi() { emit(0x1050_0073) }
    public mutating func fence() { emit(0x0ff0_000f) }

    public mutating func lrw(_ rd: Reg, _ rs1: Reg) { emit(Self.r(0x02 << 2, .zero, rs1, 2, rd, 0x2f)) }
    public mutating func scw(_ rd: Reg, _ rs2: Reg, _ rs1: Reg) { emit(Self.r(0x03 << 2, rs2, rs1, 2, rd, 0x2f)) }
    public mutating func amoaddw(_ rd: Reg, _ rs2: Reg, _ rs1: Reg) { emit(Self.r(0x00 << 2, rs2, rs1, 2, rd, 0x2f)) }
    public mutating func amoswapw(_ rd: Reg, _ rs2: Reg, _ rs1: Reg) { emit(Self.r(0x01 << 2, rs2, rs1, 2, rd, 0x2f)) }
    public mutating func amomaxw(_ rd: Reg, _ rs2: Reg, _ rs1: Reg) { emit(Self.r(0x14 << 2, rs2, rs1, 2, rd, 0x2f)) }

    /// Loads an arbitrary 32-bit constant (LUI + ADDI).
    public mutating func li(_ rd: Reg, _ value: UInt32) {
        let signed = Int32(bitPattern: value)
        if signed >= -2048 && signed <= 2047 {
            addi(rd, .zero, signed)
            return
        }
        let hi = (value &+ 0x800) >> 12
        let lo = Int32(bitPattern: value &- (hi << 12))
        lui(rd, hi)
        if lo != 0 { addi(rd, rd, lo) }
    }

    // MARK: Label-relative instructions

    public mutating func beq(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(0, rs1, rs2, label) }
    public mutating func bne(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(1, rs1, rs2, label) }
    public mutating func blt(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(4, rs1, rs2, label) }
    public mutating func bge(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(5, rs1, rs2, label) }
    public mutating func bltu(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(6, rs1, rs2, label) }
    public mutating func bgeu(_ rs1: Reg, _ rs2: Reg, _ label: String) { branch(7, rs1, rs2, label) }

    public mutating func jal(_ rd: Reg, _ label: String) {
        fixups.append((bytes.count, label, Fixup.jal(rd: rd)))
        emit(0)
    }

    public mutating func j(_ label: String) { jal(.zero, label) }
    public mutating func call(_ label: String) { jal(.ra, label) }

    /// Loads the address of `label` (PC-relative, position independent).
    public mutating func la(_ rd: Reg, _ label: String) {
        fixups.append((bytes.count, label, Fixup.la(rd: rd)))
        emit(0)
        emit(0)
    }

    private mutating func branch(_ funct3: UInt32, _ rs1: Reg, _ rs2: Reg, _ label: String) {
        fixups.append((bytes.count, label, Fixup.branch(funct3: funct3, rs1: rs1, rs2: rs2)))
        emit(0)
    }

    // MARK: Output

    /// Resolves labels and returns the final image.
    public func assemble() -> Data {
        var out = bytes
        func put(_ word: UInt32, at offset: Int) {
            out[offset] = UInt8(truncatingIfNeeded: word)
            out[offset + 1] = UInt8(truncatingIfNeeded: word >> 8)
            out[offset + 2] = UInt8(truncatingIfNeeded: word >> 16)
            out[offset + 3] = UInt8(truncatingIfNeeded: word >> 24)
        }
        for fixup in fixups {
            guard let target = labels[fixup.label] else {
                preconditionFailure("undefined label \(fixup.label)")
            }
            let delta = Int32(target - fixup.offset)
            switch fixup.kind {
            case let .branch(funct3, rs1, rs2):
                put(Self.b(delta, rs2, rs1, funct3), at: fixup.offset)
            case let .jal(rd):
                put(Self.j(delta, rd), at: fixup.offset)
            case let .la(rd):
                let d = UInt32(bitPattern: delta)
                let hi = (d &+ 0x800) >> 12
                let lo = Int32(bitPattern: d &- (hi << 12))
                put(Self.u(hi, rd, 0x17), at: fixup.offset)
                put(Self.i(lo, rd, 0, rd, 0x13), at: fixup.offset + 4)
            }
        }
        return Data(out)
    }
}
