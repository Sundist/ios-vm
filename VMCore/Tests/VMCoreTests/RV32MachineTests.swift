import XCTest
@testable import VMCore

final class RV32MachineTests: XCTestCase {
    /// Assembles `body`, appends a poweroff sequence and runs it.
    private func run(
        ramSize: UInt32 = 64 * 1024,
        maxSlices: Int = 100,
        _ body: (inout RVAssembler) -> Void
    ) -> (RV32Machine, StepResult) {
        var a = RVAssembler()
        body(&a)
        a.li(.t6, RV32Machine.sysconBase)
        a.li(.t5, RV32Machine.sysconPowerOff)
        a.sw(.t5, 0, .t6)
        a.label("__end")
        a.j("__end")
        let m = RV32Machine(ramSize: ramSize)
        XCTAssertNoThrow(try m.load(a.assemble()))
        var result = StepResult.ok
        for _ in 0..<maxSlices {
            result = m.step(elapsedMicroseconds: 1, maxInstructions: 10_000)
            if result != .ok && result != .waitingForInterrupt { break }
        }
        return (m, result)
    }

    func testArithmeticAndLogic() {
        let (m, result) = run { a in
            a.li(.a0, 7)
            a.li(.a1, 5)
            a.add(.a2, .a0, .a1)          // 12
            a.sub(.a3, .a1, .a0)          // -2
            a.xor(.a4, .a0, .a1)          // 2
            a.or(.a5, .a0, .a1)           // 7
            a.and(.a6, .a0, .a1)          // 5
            a.slli(.a7, .a0, 4)           // 112
            a.li(.s2, 0x8000_0000)
            a.srai(.s3, .s2, 4)           // 0xf800_0000
            a.srli(.s4, .s2, 4)           // 0x0800_0000
            a.slt(.s5, .a3, .a0)          // -2 < 7 = 1
            a.sltu(.s6, .a3, .a0)         // 0xffff_fffe < 7 = 0
            a.li(.s7, 0x1234_5678)
            a.addi(.s8, .zero, -1)
            a.addi(.zero, .zero, 5)       // x0 stays 0
        }
        XCTAssertEqual(result, .powerOff)
        XCTAssertEqual(m[register: 12], 12)
        XCTAssertEqual(m[register: 13], UInt32(bitPattern: -2))
        XCTAssertEqual(m[register: 14], 2)
        XCTAssertEqual(m[register: 15], 7)
        XCTAssertEqual(m[register: 16], 5)
        XCTAssertEqual(m[register: 17], 112)
        XCTAssertEqual(m[register: Int(Reg.s3.rawValue)], 0xf800_0000)
        XCTAssertEqual(m[register: Int(Reg.s4.rawValue)], 0x0800_0000)
        XCTAssertEqual(m[register: Int(Reg.s5.rawValue)], 1)
        XCTAssertEqual(m[register: Int(Reg.s6.rawValue)], 0)
        XCTAssertEqual(m[register: Int(Reg.s7.rawValue)], 0x1234_5678)
        XCTAssertEqual(m[register: Int(Reg.s8.rawValue)], 0xffff_ffff)
        XCTAssertEqual(m[register: 0], 0)
    }

    func testMultiplyDivide() {
        let (m, _) = run { a in
            a.li(.a0, UInt32(bitPattern: -6))
            a.li(.a1, 4)
            a.mul(.a2, .a0, .a1)          // -24
            a.mulh(.a3, .a0, .a1)         // -1 (high word)
            a.mulhu(.a4, .a0, .a1)        // 3
            a.div(.a5, .a0, .a1)          // -1 (truncates toward zero)
            a.rem(.a6, .a0, .a1)          // -2
            a.divu(.a7, .a1, .zero)       // div by zero -> all ones
            a.remu(.s2, .a1, .zero)       // -> dividend
            a.li(.s3, 0x8000_0000)
            a.li(.s4, UInt32(bitPattern: -1))
            a.div(.s5, .s3, .s4)          // overflow -> dividend
            a.rem(.s6, .s3, .s4)          // overflow -> 0
        }
        XCTAssertEqual(m[register: 12], UInt32(bitPattern: -24))
        XCTAssertEqual(m[register: 13], 0xffff_ffff)
        XCTAssertEqual(m[register: 14], 3)
        XCTAssertEqual(m[register: 15], UInt32(bitPattern: -1))
        XCTAssertEqual(m[register: 16], UInt32(bitPattern: -2))
        XCTAssertEqual(m[register: 17], 0xffff_ffff)
        XCTAssertEqual(m[register: Int(Reg.s2.rawValue)], 4)
        XCTAssertEqual(m[register: Int(Reg.s5.rawValue)], 0x8000_0000)
        XCTAssertEqual(m[register: Int(Reg.s6.rawValue)], 0)
    }

    func testLoadsStoresAndBranches() {
        let (m, _) = run { a in
            a.li(.s0, RV32Machine.ramBase + 0x8000)
            a.li(.t0, 0xdead_beef)
            a.sw(.t0, 0, .s0)
            a.lb(.a0, 0, .s0)             // 0xffff_ffef
            a.lbu(.a1, 0, .s0)            // 0xef
            a.lh(.a2, 2, .s0)             // 0xffff_dead
            a.lhu(.a3, 2, .s0)            // 0xdead
            a.li(.t1, 0x42)
            a.sb(.t1, 1, .s0)
            a.lw(.a4, 0, .s0)             // 0xdead_42ef
            // Loop: sum 1..10 into a5.
            a.li(.a5, 0)
            a.li(.t2, 1)
            a.li(.t3, 11)
            a.label("loop")
            a.add(.a5, .a5, .t2)
            a.addi(.t2, .t2, 1)
            a.blt(.t2, .t3, "loop")
            // Function call.
            a.li(.a6, 0)
            a.call("func")
            a.j("done")
            a.label("func")
            a.li(.a6, 99)
            a.ret()
            a.label("done")
        }
        XCTAssertEqual(m[register: 10], 0xffff_ffef)
        XCTAssertEqual(m[register: 11], 0xef)
        XCTAssertEqual(m[register: 12], 0xffff_dead)
        XCTAssertEqual(m[register: 13], 0xdead)
        XCTAssertEqual(m[register: 14], 0xdead_42ef)
        XCTAssertEqual(m[register: 15], 55)
        XCTAssertEqual(m[register: 16], 99)
    }

    func testAtomics() {
        let (m, _) = run { a in
            a.li(.s0, RV32Machine.ramBase + 0x8000)
            a.li(.t0, 10)
            a.sw(.t0, 0, .s0)
            a.li(.t1, 5)
            a.amoaddw(.a0, .t1, .s0)      // a0 = 10, mem = 15
            a.li(.t1, 3)
            a.amoswapw(.a1, .t1, .s0)     // a1 = 15, mem = 3
            a.li(.t1, 8)
            a.amomaxw(.a2, .t1, .s0)      // a2 = 3, mem = 8
            a.lrw(.a3, .s0)               // a3 = 8
            a.li(.t1, 77)
            a.scw(.a4, .t1, .s0)          // success: a4 = 0, mem = 77
            a.scw(.a5, .t1, .s0)          // no reservation: a5 = 1
            a.lw(.a6, 0, .s0)
        }
        XCTAssertEqual(m[register: 10], 10)
        XCTAssertEqual(m[register: 11], 15)
        XCTAssertEqual(m[register: 12], 3)
        XCTAssertEqual(m[register: 13], 8)
        XCTAssertEqual(m[register: 14], 0)
        XCTAssertEqual(m[register: 15], 1)
        XCTAssertEqual(m[register: 16], 77)
    }

    func testEcallTrapAndMret() {
        let (m, result) = run { a in
            a.la(.t0, "handler")
            a.csrrw(.zero, 0x305, .t0)    // mtvec
            a.li(.a0, 1)
            a.ecall()
            a.addi(.a0, .a0, 100)         // runs after mret
            a.j("out")
            a.label("handler")
            a.csrrs(.a1, 0x342, .zero)    // mcause
            a.csrrs(.t1, 0x341, .zero)    // mepc
            a.addi(.t1, .t1, 4)
            a.csrrw(.zero, 0x341, .t1)
            a.addi(.a0, .a0, 10)
            a.mret()
            a.label("out")
        }
        XCTAssertEqual(result, .powerOff)
        XCTAssertEqual(m[register: 11], 11)          // ecall from M-mode
        XCTAssertEqual(m[register: 10], 111)
    }

    func testIllegalInstructionWithoutHandlerHalts() {
        let m = RV32Machine(ramSize: 64 * 1024)
        var a = RVAssembler()
        a.emit(0xffff_ffff)
        try? m.load(a.assemble())
        let result = m.step(elapsedMicroseconds: 0, maxInstructions: 10)
        guard case let .halted(reason) = result else {
            return XCTFail("expected halt, got \(result)")
        }
        XCTAssertTrue(reason.contains("illegal instruction"))
    }

    func testTimerInterrupt() {
        let m = RV32Machine(ramSize: 64 * 1024)
        var a = RVAssembler()
        a.la(.t0, "handler")
        a.csrrw(.zero, 0x305, .t0)        // mtvec
        a.li(.t1, RV32Machine.clintBase + 0x4000)
        a.li(.t2, 100)
        a.sw(.zero, 4, .t1)
        a.sw(.t2, 0, .t1)                 // mtimecmp = 100 us
        a.li(.t0, 0x80)
        a.csrrs(.zero, 0x304, .t0)        // mie.MTIE
        a.csrrsi(.zero, 0x300, 8)         // mstatus.MIE
        a.label("spin")
        a.wfi()
        a.j("spin")
        a.label("handler")
        a.csrrs(.a0, 0x342, .zero)        // mcause
        a.li(.t6, RV32Machine.sysconBase)
        a.li(.t5, RV32Machine.sysconPowerOff)
        a.sw(.t5, 0, .t6)
        a.label("hang")
        a.j("hang")
        try? m.load(a.assemble())

        XCTAssertEqual(m.step(elapsedMicroseconds: 0, maxInstructions: 1000), .waitingForInterrupt)
        XCTAssertEqual(m.step(elapsedMicroseconds: 50, maxInstructions: 1000), .waitingForInterrupt)
        XCTAssertEqual(m.step(elapsedMicroseconds: 60, maxInstructions: 1000), .powerOff)
        XCTAssertEqual(m[register: 10], 0x8000_0007)
    }

    func testUARTOutputAndInput() {
        let m = RV32Machine(ramSize: 64 * 1024)
        var a = RVAssembler()
        a.li(.s0, RV32Machine.uartBase)
        a.label("wait")
        a.lbu(.t0, 5, .s0)
        a.andi(.t0, .t0, 1)
        a.beq(.t0, .zero, "wait")
        a.lbu(.t1, 0, .s0)
        a.addi(.t1, .t1, 1)               // echo next letter
        a.sb(.t1, 0, .s0)
        a.j("wait")
        try? m.load(a.assemble())
        _ = m.step(elapsedMicroseconds: 0, maxInstructions: 1000)
        XCTAssertTrue(m.takeOutput().isEmpty)
        m.enqueueInput(Array("HAL".utf8))
        _ = m.step(elapsedMicroseconds: 0, maxInstructions: 1000)
        XCTAssertEqual(String(decoding: m.takeOutput(), as: UTF8.self), "IBM")
    }

    func testMonitorFirmwareBootsEchoesAndPowersOff() {
        let m = RV32Machine(ramSize: 1024 * 1024)
        XCTAssertNoThrow(try m.load(MonitorFirmware.image))
        var output: [UInt8] = []
        var result = StepResult.ok
        for _ in 0..<50 {
            result = m.step(elapsedMicroseconds: 1000, maxInstructions: 100_000)
            output += m.takeOutput()
            if result == .waitingForInterrupt { break }
        }
        XCTAssertEqual(result, .waitingForInterrupt)
        var text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("PocketVM Monitor"))
        XCTAssertTrue(text.hasSuffix("monitor> "))

        m.enqueueInput(Array("hi\r".utf8) + [4])
        output.removeAll()
        for _ in 0..<50 {
            result = m.step(elapsedMicroseconds: 3000, maxInstructions: 100_000)
            output += m.takeOutput()
            if result == .powerOff { break }
        }
        XCTAssertEqual(result, .powerOff)
        text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("hi\r\nmonitor> "))
        XCTAssertTrue(text.contains("Powering off."))
    }

    func testSnapshotRoundTrip() throws {
        let m = RV32Machine(ramSize: 1024 * 1024)
        try m.load(MonitorFirmware.image)
        _ = m.step(elapsedMicroseconds: 0, maxInstructions: 100_000)
        _ = m.takeOutput()
        let snapshot = m.makeSnapshot()

        let restored = RV32Machine(ramSize: 1024 * 1024)
        try restored.restore(from: snapshot)
        XCTAssertEqual(restored.pc, m.pc)
        XCTAssertEqual(restored.mie, m.mie)
        XCTAssertEqual(restored.cycle, m.cycle)
        for i in 0..<32 { XCTAssertEqual(restored[register: i], m[register: i]) }

        restored.enqueueInput(Array("ok".utf8))
        _ = restored.step(elapsedMicroseconds: 5000, maxInstructions: 100_000)
        XCTAssertEqual(String(decoding: restored.takeOutput(), as: UTF8.self), "ok")

        let other = RV32Machine(ramSize: 2 * 1024 * 1024)
        XCTAssertThrowsError(try other.restore(from: snapshot))
        XCTAssertThrowsError(try restored.restore(from: snapshot.prefix(100)))
    }

    func testLinuxBootSetup() throws {
        let m = RV32Machine(ramSize: 4 * 1024 * 1024)
        let kernel = Data([0x13, 0x00, 0x00, 0x00]) // nop
        try m.bootLinux(kernel: kernel, bootArguments: "console=ttyS0")
        XCTAssertEqual(m.pc, RV32Machine.ramBase)
        XCTAssertEqual(m[register: 10], 0)
        let dtbAddress = m[register: 11]
        XCTAssertEqual(dtbAddress, RV32Machine.ramBase + 4 * 1024 * 1024 - RV32Machine.deviceTreeReserve)
        let offset = Int(dtbAddress - RV32Machine.ramBase)
        let magic = m.ram.load(fromByteOffset: offset, as: UInt32.self).bigEndian
        XCTAssertEqual(magic, 0xd00d_feed)

        XCTAssertThrowsError(try m.bootLinux(kernel: Data(count: 5 * 1024 * 1024), bootArguments: ""))
    }
}
