import Foundation

/// Result of running a slice of guest instructions.
public enum StepResult: Equatable, Sendable {
    /// The slice finished normally; call `step` again.
    case ok
    /// The guest executed `wfi` and nothing is pending. The host may sleep.
    case waitingForInterrupt
    /// The guest asked the system controller to power off.
    case powerOff
    /// The guest asked the system controller to reboot.
    case reboot
    /// The guest hit a trap with no handler installed (mtvec == 0).
    case halted(String)
}

/// A single-hart RV32IMA (+Zicsr, machine mode) interpreter with a small,
/// "virt"-like board:
///
/// | Address      | Device                               |
/// |--------------|--------------------------------------|
/// | 0x1000_0000  | NS16550A-compatible UART             |
/// | 0x1100_0000  | CLINT (mtime / mtimecmp)              |
/// | 0x1110_0000  | syscon (0x5555 = poweroff, 0x7777 = reboot) |
/// | 0x8000_0000  | RAM                                  |
///
/// The memory map matches the one used by the popular `mini-rv32ima`
/// project, so no-MMU Linux kernel images built for it boot unchanged.
///
/// iOS does not allow third-party apps to use a hypervisor or JIT, so this is
/// a pure interpreter (the same approach UTM SE uses).
public final class RV32Machine {
    public static let ramBase: UInt32 = 0x8000_0000
    public static let uartBase: UInt32 = 0x1000_0000
    public static let clintBase: UInt32 = 0x1100_0000
    public static let sysconBase: UInt32 = 0x1110_0000

    public static let sysconPowerOff: UInt32 = 0x5555
    public static let sysconReboot: UInt32 = 0x7777

    // MARK: Architectural state

    public let ramSize: UInt32
    public let ram: UnsafeMutableRawPointer
    let x: UnsafeMutablePointer<UInt32>

    public var pc: UInt32 = RV32Machine.ramBase
    public var mstatus: UInt32 = 0
    public var mscratch: UInt32 = 0
    public var mtvec: UInt32 = 0
    public var mie: UInt32 = 0
    public var mip: UInt32 = 0
    public var mepc: UInt32 = 0
    public var mtval: UInt32 = 0
    public var mcause: UInt32 = 0
    /// Current privilege level: 3 = machine, 0 = user.
    public var privilege: UInt32 = 3
    public var cycle: UInt64 = 0
    /// CLINT timer, in microseconds (timebase-frequency = 1 MHz).
    public var mtime: UInt64 = 0
    public var mtimecmp: UInt64 = 0
    public var waitingForInterrupt = false

    var reservationAddress: UInt32 = 0
    var hasReservation = false
    var uartLCR: UInt8 = 0

    // MARK: Host I/O

    private var inputBuffer: [UInt8] = []
    private var inputIndex = 0
    /// Bytes written by the guest to the UART since the last `takeOutput()`.
    public private(set) var outputBuffer: [UInt8] = []

    private var memFault = false
    private var trapValue: UInt32 = 0
    private var pendingPowerEvent: StepResult?

    public init(ramSize: UInt32) {
        precondition(ramSize >= 64 * 1024, "RAM must be at least 64 KiB")
        precondition(ramSize % 4096 == 0, "RAM size must be page aligned")
        precondition(UInt64(ramSize) <= 0x8000_0000, "RAM must fit below 4 GiB")
        self.ramSize = ramSize
        ram = UnsafeMutableRawPointer.allocate(byteCount: Int(ramSize), alignment: 4096)
        ram.initializeMemory(as: UInt8.self, repeating: 0, count: Int(ramSize))
        x = UnsafeMutablePointer<UInt32>.allocate(capacity: 32)
        x.initialize(repeating: 0, count: 32)
    }

    deinit {
        ram.deallocate()
        x.deallocate()
    }

    /// General purpose register access (x0 is hard-wired to zero).
    public subscript(register index: Int) -> UInt32 {
        get { x[index] }
        set { if index != 0 { x[index] = newValue } }
    }

    // MARK: Lifecycle

    /// Puts the hart back into its power-on state.
    public func reset(clearMemory: Bool = true) {
        if clearMemory {
            ram.initializeMemory(as: UInt8.self, repeating: 0, count: Int(ramSize))
        }
        for i in 0..<32 { x[i] = 0 }
        pc = Self.ramBase
        mstatus = 0; mscratch = 0; mtvec = 0; mie = 0; mip = 0
        mepc = 0; mtval = 0; mcause = 0
        privilege = 3
        cycle = 0; mtime = 0; mtimecmp = 0
        waitingForInterrupt = false
        hasReservation = false
        uartLCR = 0
        inputBuffer.removeAll(); inputIndex = 0
        outputBuffer.removeAll()
        pendingPowerEvent = nil
    }

    /// Copies `data` into RAM at `offset` bytes from the start of RAM.
    public func load(_ data: Data, atOffset offset: UInt32 = 0) throws {
        guard UInt64(offset) + UInt64(data.count) <= UInt64(ramSize) else {
            throw VMError.imageTooLarge(size: data.count, available: Int(ramSize) - Int(offset))
        }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            (ram + Int(offset)).copyMemory(from: base, byteCount: buf.count)
        }
    }

    /// Size reserved at the top of RAM for the flattened device tree.
    public static let deviceTreeReserve: UInt32 = 16 * 1024

    /// Resets the machine and prepares a Linux boot: kernel at the start of
    /// RAM, a generated device tree at the top, a0 = hart id, a1 = DTB.
    public func bootLinux(kernel: Data, bootArguments: String) throws {
        reset(clearMemory: true)
        let dtbOffset = ramSize - Self.deviceTreeReserve
        guard kernel.count <= Int(dtbOffset) else {
            throw VMError.imageTooLarge(size: kernel.count, available: Int(dtbOffset))
        }
        let dtb = DeviceTree.makeBoardTree(memorySize: dtbOffset, bootArguments: bootArguments)
        guard dtb.count <= Int(Self.deviceTreeReserve) else {
            throw VMError.invalidImage("device tree too large")
        }
        try load(kernel, atOffset: 0)
        try load(dtb, atOffset: dtbOffset)
        x[10] = 0                              // a0: hart id
        x[11] = Self.ramBase &+ dtbOffset      // a1: device tree
        pc = Self.ramBase
        privilege = 3
    }

    // MARK: Host I/O

    /// Queues bytes to be read by the guest from the UART receive register.
    public func enqueueInput<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        inputBuffer.append(contentsOf: bytes)
    }

    public var hasPendingInput: Bool { inputIndex < inputBuffer.count }

    /// Returns and clears everything the guest printed so far.
    public func takeOutput() -> [UInt8] {
        let out = outputBuffer
        outputBuffer.removeAll(keepingCapacity: true)
        return out
    }

    // MARK: Execution

    /// Advances the timer by `elapsedMicroseconds` and executes up to
    /// `maxInstructions` instructions.
    public func step(elapsedMicroseconds: UInt64, maxInstructions: Int) -> StepResult {
        mtime &+= elapsedMicroseconds
        updateTimerPending()

        if waitingForInterrupt {
            if mip & mie != 0 {
                waitingForInterrupt = false
            } else {
                return .waitingForInterrupt
            }
        }

        var executed = 0
        while executed < maxInstructions {
            // Machine timer interrupt (the only interrupt source on this board).
            if mip & mie & 0x80 != 0 && (privilege < 3 || mstatus & 0x8 != 0) {
                if mtvec == 0 {
                    return .halted("Timer interrupt with no trap handler (pc=\(hex(pc)))")
                }
                takeTrap(cause: 0x8000_0007, value: 0)
            }

            executed += 1
            cycle &+= 1
            let trap = execute()
            if trap != 0 {
                let cause = trap - 1
                if mtvec == 0 {
                    return .halted("Unhandled exception \(Self.describe(cause: cause)) at pc=\(hex(pc)), mtval=\(hex(trapValue))")
                }
                takeTrap(cause: cause, value: trapValue)
            }
            if let event = pendingPowerEvent {
                pendingPowerEvent = nil
                return event
            }
            if waitingForInterrupt {
                return .waitingForInterrupt
            }
        }
        return .ok
    }

    private func takeTrap(cause: UInt32, value: UInt32) {
        mepc = pc
        mcause = cause
        mtval = value
        // MPIE <- MIE, MIE <- 0, MPP <- current privilege.
        mstatus = ((mstatus & 0x8) << 4) | (privilege << 11)
        privilege = 3
        let base = mtvec & ~3
        if cause & 0x8000_0000 != 0 && mtvec & 1 != 0 {
            pc = base &+ 4 &* (cause & 0x7fff_ffff)
        } else {
            pc = base
        }
        waitingForInterrupt = false
    }

    @inline(__always)
    private func updateTimerPending() {
        if mtimecmp != 0 && mtime >= mtimecmp {
            mip |= 0x80
        } else {
            mip &= ~UInt32(0x80)
        }
    }

    /// Executes one instruction. Returns 0, or (exception cause + 1).
    @inline(__always)
    private func execute() -> UInt32 {
        let pc = self.pc
        if pc & 3 != 0 {
            trapValue = pc
            return 0 + 1                       // instruction address misaligned
        }
        let fetchOffset = pc &- Self.ramBase
        if fetchOffset > ramSize &- 4 {
            trapValue = pc
            return 1 + 1                       // instruction access fault
        }
        let ir = ram.load(fromByteOffset: Int(fetchOffset), as: UInt32.self)

        let rd = Int((ir >> 7) & 31)
        let funct3 = (ir >> 12) & 7
        let rs1 = Int((ir >> 15) & 31)
        let rs2 = Int((ir >> 20) & 31)
        var rval: UInt32 = 0
        var writesRd = true
        var nextPC = pc &+ 4

        switch ir & 0x7f {
        case 0x37: // LUI
            rval = ir & 0xffff_f000

        case 0x17: // AUIPC
            rval = pc &+ (ir & 0xffff_f000)

        case 0x6f: // JAL
            var imm = ((ir & 0x8000_0000) >> 11) | ((ir & 0x7fe0_0000) >> 20)
                | ((ir & 0x0010_0000) >> 9) | (ir & 0x000f_f000)
            if imm & 0x0010_0000 != 0 { imm |= 0xffe0_0000 }
            rval = pc &+ 4
            nextPC = pc &+ imm

        case 0x67: // JALR
            let imm = UInt32(bitPattern: Int32(bitPattern: ir) >> 20)
            rval = pc &+ 4
            nextPC = (x[rs1] &+ imm) & ~UInt32(1)

        case 0x63: // BRANCH
            writesRd = false
            var imm = ((ir & 0xf00) >> 7) | ((ir & 0x7e00_0000) >> 20)
                | ((ir & 0x80) << 4) | ((ir >> 31) << 12)
            if imm & 0x1000 != 0 { imm |= 0xffff_e000 }
            let a = x[rs1], b = x[rs2]
            let taken: Bool
            switch funct3 {
            case 0: taken = a == b
            case 1: taken = a != b
            case 4: taken = Int32(bitPattern: a) < Int32(bitPattern: b)
            case 5: taken = Int32(bitPattern: a) >= Int32(bitPattern: b)
            case 6: taken = a < b
            case 7: taken = a >= b
            default:
                trapValue = ir
                return 2 + 1
            }
            if taken { nextPC = pc &+ imm }

        case 0x03: // LOAD
            let imm = UInt32(bitPattern: Int32(bitPattern: ir) >> 20)
            let addr = x[rs1] &+ imm
            memFault = false
            switch funct3 {
            case 0: rval = UInt32(bitPattern: Int32(Int8(bitPattern: load8(addr))))
            case 1: rval = UInt32(bitPattern: Int32(Int16(bitPattern: load16(addr))))
            case 2: rval = load32(addr)
            case 4: rval = UInt32(load8(addr))
            case 5: rval = UInt32(load16(addr))
            default:
                trapValue = ir
                return 2 + 1
            }
            if memFault {
                trapValue = addr
                return 5 + 1                   // load access fault
            }

        case 0x23: // STORE
            writesRd = false
            var imm = ((ir >> 7) & 0x1f) | ((ir & 0xfe00_0000) >> 20)
            if imm & 0x800 != 0 { imm |= 0xffff_f000 }
            let addr = x[rs1] &+ imm
            let value = x[rs2]
            memFault = false
            switch funct3 {
            case 0: store8(addr, UInt8(truncatingIfNeeded: value))
            case 1: store16(addr, UInt16(truncatingIfNeeded: value))
            case 2: store32(addr, value)
            default:
                trapValue = ir
                return 2 + 1
            }
            if memFault {
                trapValue = addr
                return 7 + 1                   // store access fault
            }

        case 0x13, 0x33: // OP-IMM, OP
            let isRegister = ir & 0x20 != 0
            let a = x[rs1]
            let b = isRegister ? x[rs2] : UInt32(bitPattern: Int32(bitPattern: ir) >> 20)
            if isRegister && (ir >> 25) == 1 {
                rval = Self.multiplyDivide(funct3, a, b)
            } else {
                let alt = ir & 0x4000_0000 != 0
                switch funct3 {
                case 0: rval = (isRegister && alt) ? a &- b : a &+ b
                case 1: rval = a &<< b
                case 2: rval = Int32(bitPattern: a) < Int32(bitPattern: b) ? 1 : 0
                case 3: rval = a < b ? 1 : 0
                case 4: rval = a ^ b
                case 5:
                    rval = alt
                        ? UInt32(bitPattern: Int32(bitPattern: a) &>> Int32(b & 31))
                        : a &>> b
                case 6: rval = a | b
                default: rval = a & b
                }
            }

        case 0x0f: // FENCE / FENCE.I
            writesRd = false

        case 0x73: // SYSTEM
            if funct3 == 0 {
                writesRd = false
                switch ir {
                case 0x0000_0073: // ECALL
                    trapValue = 0
                    return (privilege == 3 ? 11 : 8) + 1
                case 0x0010_0073: // EBREAK
                    trapValue = pc
                    return 3 + 1
                case 0x3020_0073: // MRET
                    // MIE <- MPIE, MPIE <- 1, privilege <- MPP, MPP <- U.
                    let previous = mstatus
                    mstatus = (previous & ~UInt32(0x1888)) | ((previous & 0x80) >> 4) | 0x80
                    privilege = (previous >> 11) & 3
                    nextPC = mepc
                case 0x1050_0073: // WFI
                    if mip & mie == 0 { waitingForInterrupt = true }
                default:
                    if ir & 0xfe00_7fff == 0x1200_0073 { break } // SFENCE.VMA
                    trapValue = ir
                    return 2 + 1
                }
            } else {
                let csr = ir >> 20
                let source = funct3 & 4 != 0 ? UInt32(rs1) : x[rs1]
                let old = readCSR(csr)
                let newValue: UInt32
                switch funct3 & 3 {
                case 1: newValue = source
                case 2: newValue = old | source
                case 3: newValue = old & ~source
                default:
                    trapValue = ir
                    return 2 + 1
                }
                // CSRRS/CSRRC with rs1 = x0 must not write.
                if funct3 & 3 == 1 || rs1 != 0 {
                    writeCSR(csr, newValue)
                }
                rval = old
            }

        case 0x2f: // AMO (A extension, 32-bit only)
            guard funct3 == 2 else {
                trapValue = ir
                return 2 + 1
            }
            let addr = x[rs1]
            let funct5 = ir >> 27
            memFault = false
            switch funct5 {
            case 0x02: // LR.W
                rval = load32(addr)
                if memFault { trapValue = addr; return 5 + 1 }
                reservationAddress = addr
                hasReservation = true
            case 0x03: // SC.W
                if hasReservation && reservationAddress == addr {
                    store32(addr, x[rs2])
                    if memFault { trapValue = addr; return 7 + 1 }
                    rval = 0
                } else {
                    rval = 1
                }
                hasReservation = false
            default:
                let old = load32(addr)
                if memFault { trapValue = addr; return 7 + 1 }
                let b = x[rs2]
                let result: UInt32
                switch funct5 {
                case 0x00: result = old &+ b                     // AMOADD
                case 0x01: result = b                            // AMOSWAP
                case 0x04: result = old ^ b                      // AMOXOR
                case 0x08: result = old | b                      // AMOOR
                case 0x0c: result = old & b                      // AMOAND
                case 0x10: result = Int32(bitPattern: old) < Int32(bitPattern: b) ? old : b // AMOMIN
                case 0x14: result = Int32(bitPattern: old) > Int32(bitPattern: b) ? old : b // AMOMAX
                case 0x18: result = old < b ? old : b            // AMOMINU
                case 0x1c: result = old > b ? old : b            // AMOMAXU
                default:
                    trapValue = ir
                    return 2 + 1
                }
                store32(addr, result)
                if memFault { trapValue = addr; return 7 + 1 }
                rval = old
            }

        default:
            trapValue = ir
            return 2 + 1                       // illegal instruction
        }

        if writesRd && rd != 0 { x[rd] = rval }
        self.pc = nextPC
        return 0
    }

    @inline(__always)
    static func multiplyDivide(_ funct3: UInt32, _ a: UInt32, _ b: UInt32) -> UInt32 {
        let sa = Int32(bitPattern: a), sb = Int32(bitPattern: b)
        switch funct3 {
        case 0: // MUL
            return a &* b
        case 1: // MULH
            return UInt32(truncatingIfNeeded: (Int64(sa) &* Int64(sb)) >> 32)
        case 2: // MULHSU
            return UInt32(truncatingIfNeeded: (Int64(sa) &* Int64(b)) >> 32)
        case 3: // MULHU
            return UInt32(truncatingIfNeeded: (UInt64(a) &* UInt64(b)) >> 32)
        case 4: // DIV
            if b == 0 { return 0xffff_ffff }
            if sa == Int32.min && sb == -1 { return a }
            return UInt32(bitPattern: sa / sb)
        case 5: // DIVU
            return b == 0 ? 0xffff_ffff : a / b
        case 6: // REM
            if b == 0 { return a }
            if sa == Int32.min && sb == -1 { return 0 }
            return UInt32(bitPattern: sa % sb)
        default: // REMU
            return b == 0 ? a : a % b
        }
    }

    // MARK: CSRs

    private func readCSR(_ csr: UInt32) -> UInt32 {
        switch csr {
        case 0x300: return mstatus
        case 0x301: return 0x4040_1101          // misa: RV32 + I, M, A
        case 0x304: return mie
        case 0x305: return mtvec
        case 0x340: return mscratch
        case 0x341: return mepc
        case 0x342: return mcause
        case 0x343: return mtval
        case 0x344: return mip
        case 0xb00, 0xc00: return UInt32(truncatingIfNeeded: cycle)
        case 0xb80, 0xc80: return UInt32(truncatingIfNeeded: cycle >> 32)
        case 0xc01: return UInt32(truncatingIfNeeded: mtime)
        case 0xc81: return UInt32(truncatingIfNeeded: mtime >> 32)
        case 0xb02, 0xc02: return UInt32(truncatingIfNeeded: cycle)   // instret ~ cycle
        case 0xb82, 0xc82: return UInt32(truncatingIfNeeded: cycle >> 32)
        case 0xf11: return 0xff0f_f0ff          // mvendorid
        default: return 0                        // mhartid and everything else
        }
    }

    private func writeCSR(_ csr: UInt32, _ value: UInt32) {
        switch csr {
        case 0x300: mstatus = value & 0x1888    // MIE, MPIE, MPP
        case 0x304: mie = value & 0x888
        case 0x305: mtvec = value
        case 0x340: mscratch = value
        case 0x341: mepc = value & ~UInt32(3)
        case 0x342: mcause = value
        case 0x343: mtval = value
        case 0x344: mip = (value & 0x8) | (mip & 0x80)   // MTIP is read-only
        default: break
        }
    }

    // MARK: Memory

    @inline(__always)
    private func load8(_ addr: UInt32) -> UInt8 {
        let offset = addr &- Self.ramBase
        if offset < ramSize {
            return ram.load(fromByteOffset: Int(offset), as: UInt8.self)
        }
        return UInt8(truncatingIfNeeded: mmioLoad(addr))
    }

    @inline(__always)
    private func load16(_ addr: UInt32) -> UInt16 {
        let offset = addr &- Self.ramBase
        if offset <= ramSize &- 2 {
            return ram.loadUnaligned(fromByteOffset: Int(offset), as: UInt16.self)
        }
        return UInt16(truncatingIfNeeded: mmioLoad(addr))
    }

    @inline(__always)
    private func load32(_ addr: UInt32) -> UInt32 {
        let offset = addr &- Self.ramBase
        if offset <= ramSize &- 4 {
            return ram.loadUnaligned(fromByteOffset: Int(offset), as: UInt32.self)
        }
        return mmioLoad(addr)
    }

    @inline(__always)
    private func store8(_ addr: UInt32, _ value: UInt8) {
        let offset = addr &- Self.ramBase
        if offset < ramSize {
            ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt8.self)
        } else {
            mmioStore(addr, UInt32(value))
        }
    }

    @inline(__always)
    private func store16(_ addr: UInt32, _ value: UInt16) {
        let offset = addr &- Self.ramBase
        if offset <= ramSize &- 2 {
            ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt16.self)
        } else {
            mmioStore(addr, UInt32(value))
        }
    }

    @inline(__always)
    private func store32(_ addr: UInt32, _ value: UInt32) {
        let offset = addr &- Self.ramBase
        if offset <= ramSize &- 4 {
            ram.storeBytes(of: value, toByteOffset: Int(offset), as: UInt32.self)
        } else {
            mmioStore(addr, value)
        }
    }

    private func mmioLoad(_ addr: UInt32) -> UInt32 {
        switch addr {
        case Self.uartBase: // RBR
            if uartLCR & 0x80 != 0 { return 0 }   // divisor latch
            guard inputIndex < inputBuffer.count else { return 0 }
            let byte = inputBuffer[inputIndex]
            inputIndex += 1
            if inputIndex == inputBuffer.count {
                inputBuffer.removeAll(keepingCapacity: true)
                inputIndex = 0
            }
            return UInt32(byte)
        case Self.uartBase + 3:
            return UInt32(uartLCR)
        case Self.uartBase + 5: // LSR: THR empty | transmitter idle | data ready
            return 0x60 | (inputIndex < inputBuffer.count ? 1 : 0)
        case Self.uartBase..<(Self.uartBase + 0x100):
            return 0
        case Self.clintBase + 0x4000:
            return UInt32(truncatingIfNeeded: mtimecmp)
        case Self.clintBase + 0x4004:
            return UInt32(truncatingIfNeeded: mtimecmp >> 32)
        case Self.clintBase + 0xbff8:
            return UInt32(truncatingIfNeeded: mtime)
        case Self.clintBase + 0xbffc:
            return UInt32(truncatingIfNeeded: mtime >> 32)
        case Self.clintBase..<(Self.clintBase + 0x10000):
            return 0
        case Self.sysconBase..<(Self.sysconBase + 0x1000):
            return 0
        default:
            memFault = true
            return 0
        }
    }

    private func mmioStore(_ addr: UInt32, _ value: UInt32) {
        switch addr {
        case Self.uartBase: // THR
            if uartLCR & 0x80 == 0 {
                outputBuffer.append(UInt8(truncatingIfNeeded: value))
            }
        case Self.uartBase + 3:
            uartLCR = UInt8(truncatingIfNeeded: value)
        case Self.uartBase..<(Self.uartBase + 0x100):
            break
        case Self.clintBase + 0x4000:
            mtimecmp = (mtimecmp & 0xffff_ffff_0000_0000) | UInt64(value)
            updateTimerPending()
        case Self.clintBase + 0x4004:
            mtimecmp = (mtimecmp & 0xffff_ffff) | (UInt64(value) << 32)
            updateTimerPending()
        case Self.clintBase + 0xbff8:
            mtime = (mtime & 0xffff_ffff_0000_0000) | UInt64(value)
            updateTimerPending()
        case Self.clintBase + 0xbffc:
            mtime = (mtime & 0xffff_ffff) | (UInt64(value) << 32)
            updateTimerPending()
        case Self.clintBase..<(Self.clintBase + 0x10000):
            break
        case Self.sysconBase:
            if value == Self.sysconPowerOff {
                pendingPowerEvent = .powerOff
            } else if value == Self.sysconReboot {
                pendingPowerEvent = .reboot
            }
        case Self.sysconBase..<(Self.sysconBase + 0x1000):
            break
        default:
            memFault = true
        }
    }

    // MARK: Helpers

    static func describe(cause: UInt32) -> String {
        switch cause {
        case 0: return "instruction address misaligned"
        case 1: return "instruction access fault"
        case 2: return "illegal instruction"
        case 3: return "breakpoint"
        case 5: return "load access fault"
        case 7: return "store access fault"
        case 8: return "ecall from U-mode"
        case 11: return "ecall from M-mode"
        default: return "cause \(cause)"
        }
    }
}

@inline(__always)
func hex(_ value: UInt32) -> String {
    let s = String(value, radix: 16)
    return "0x" + String(repeating: "0", count: max(0, 8 - s.count)) + s
}

public enum VMError: LocalizedError, Equatable {
    case imageTooLarge(size: Int, available: Int)
    case invalidImage(String)
    case invalidSnapshot(String)
    case missingKernel

    public var errorDescription: String? {
        switch self {
        case let .imageTooLarge(size, available):
            return "Image (\(size) bytes) does not fit in guest RAM (\(available) bytes available). Increase the base memory."
        case let .invalidImage(reason):
            return "Invalid image: \(reason)"
        case let .invalidSnapshot(reason):
            return "Invalid snapshot: \(reason)"
        case .missingKernel:
            return "This machine needs a kernel image. Attach one in Settings › Storage."
        }
    }
}
