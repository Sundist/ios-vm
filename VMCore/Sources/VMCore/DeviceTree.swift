import Foundation

/// Minimal flattened device tree (DTB, version 17) writer.
public struct FDTBuilder {
    private var structure = Data()
    private var strings = Data()
    private var stringOffsets: [String: UInt32] = [:]
    private var depth = 0

    public init() {}

    public mutating func beginNode(_ name: String) {
        appendU32(0x1, to: &structure)
        structure.append(contentsOf: Array(name.utf8))
        structure.append(0)
        pad(&structure)
        depth += 1
    }

    public mutating func endNode() {
        precondition(depth > 0, "unbalanced endNode()")
        appendU32(0x2, to: &structure)
        depth -= 1
    }

    public mutating func property(_ name: String, bytes: [UInt8] = []) {
        appendU32(0x3, to: &structure)
        appendU32(UInt32(bytes.count), to: &structure)
        appendU32(offset(of: name), to: &structure)
        structure.append(contentsOf: bytes)
        pad(&structure)
    }

    public mutating func property(_ name: String, cells: [UInt32]) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cells.count * 4)
        for cell in cells {
            bytes.append(UInt8(truncatingIfNeeded: cell >> 24))
            bytes.append(UInt8(truncatingIfNeeded: cell >> 16))
            bytes.append(UInt8(truncatingIfNeeded: cell >> 8))
            bytes.append(UInt8(truncatingIfNeeded: cell))
        }
        property(name, bytes: bytes)
    }

    public mutating func property(_ name: String, string: String) {
        property(name, strings: [string])
    }

    public mutating func property(_ name: String, strings: [String]) {
        var bytes: [UInt8] = []
        for s in strings {
            bytes.append(contentsOf: Array(s.utf8))
            bytes.append(0)
        }
        property(name, bytes: bytes)
    }

    public func finish() -> Data {
        precondition(depth == 0, "unclosed device tree node")
        var body = structure
        appendU32(0x9, to: &body) // FDT_END

        let headerSize = 40
        let reserveMapOffset = headerSize               // 8-byte aligned
        let reserveMapSize = 16                         // one terminating entry
        let structOffset = reserveMapOffset + reserveMapSize
        let stringsOffset = structOffset + body.count
        let total = stringsOffset + strings.count

        var out = Data()
        appendU32(0xd00d_feed, to: &out)               // magic
        appendU32(UInt32(total), to: &out)             // totalsize
        appendU32(UInt32(structOffset), to: &out)      // off_dt_struct
        appendU32(UInt32(stringsOffset), to: &out)     // off_dt_strings
        appendU32(UInt32(reserveMapOffset), to: &out)  // off_mem_rsvmap
        appendU32(17, to: &out)                        // version
        appendU32(16, to: &out)                        // last_comp_version
        appendU32(0, to: &out)                         // boot_cpuid_phys
        appendU32(UInt32(strings.count), to: &out)     // size_dt_strings
        appendU32(UInt32(body.count), to: &out)        // size_dt_struct
        out.append(Data(count: reserveMapSize))
        out.append(body)
        out.append(strings)
        return out
    }

    private mutating func offset(of name: String) -> UInt32 {
        if let existing = stringOffsets[name] { return existing }
        let off = UInt32(strings.count)
        strings.append(contentsOf: Array(name.utf8))
        strings.append(0)
        stringOffsets[name] = off
        return off
    }

    private func pad(_ data: inout Data) {
        while data.count % 4 != 0 { data.append(0) }
    }

    private func appendU32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

public enum DeviceTree {
    public static let defaultBootArguments =
        "earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0"

    /// Builds the device tree describing `RV32Machine`'s board.
    public static func makeBoardTree(memorySize: UInt32, bootArguments: String) -> Data {
        let cpuPhandle: UInt32 = 1
        let intcPhandle: UInt32 = 2
        let sysconPhandle: UInt32 = 4

        var fdt = FDTBuilder()
        fdt.beginNode("")
        fdt.property("#address-cells", cells: [2])
        fdt.property("#size-cells", cells: [2])
        fdt.property("compatible", string: "riscv-minimal-nommu")
        fdt.property("model", string: "PocketVM RV32IMA")

        fdt.beginNode("chosen")
        fdt.property("bootargs", string: bootArguments)
        fdt.property("stdout-path", string: "/soc/uart@10000000")
        fdt.endNode()

        fdt.beginNode("memory@80000000")
        fdt.property("device_type", string: "memory")
        fdt.property("reg", cells: [0, RV32Machine.ramBase, 0, memorySize])
        fdt.endNode()

        fdt.beginNode("cpus")
        fdt.property("#address-cells", cells: [1])
        fdt.property("#size-cells", cells: [0])
        fdt.property("timebase-frequency", cells: [1_000_000])
        fdt.beginNode("cpu@0")
        fdt.property("phandle", cells: [cpuPhandle])
        fdt.property("device_type", string: "cpu")
        fdt.property("reg", cells: [0])
        fdt.property("status", string: "okay")
        fdt.property("compatible", string: "riscv")
        fdt.property("riscv,isa", string: "rv32ima")
        fdt.property("mmu-type", string: "riscv,none")
        fdt.beginNode("interrupt-controller")
        fdt.property("#interrupt-cells", cells: [1])
        fdt.property("interrupt-controller")
        fdt.property("compatible", string: "riscv,cpu-intc")
        fdt.property("phandle", cells: [intcPhandle])
        fdt.endNode()
        fdt.endNode() // cpu@0
        fdt.beginNode("cpu-map")
        fdt.beginNode("cluster0")
        fdt.beginNode("core0")
        fdt.property("cpu", cells: [cpuPhandle])
        fdt.endNode()
        fdt.endNode()
        fdt.endNode()
        fdt.endNode() // cpus

        fdt.beginNode("soc")
        fdt.property("#address-cells", cells: [2])
        fdt.property("#size-cells", cells: [2])
        fdt.property("compatible", string: "simple-bus")
        fdt.property("ranges")

        fdt.beginNode("uart@10000000")
        fdt.property("clock-frequency", cells: [0x100_0000])
        fdt.property("reg", cells: [0, RV32Machine.uartBase, 0, 0x100])
        fdt.property("compatible", string: "ns16550a")
        fdt.endNode()

        fdt.beginNode("poweroff")
        fdt.property("value", cells: [RV32Machine.sysconPowerOff])
        fdt.property("offset", cells: [0])
        fdt.property("regmap", cells: [sysconPhandle])
        fdt.property("compatible", string: "syscon-poweroff")
        fdt.endNode()

        fdt.beginNode("reboot")
        fdt.property("value", cells: [RV32Machine.sysconReboot])
        fdt.property("offset", cells: [0])
        fdt.property("regmap", cells: [sysconPhandle])
        fdt.property("compatible", string: "syscon-reboot")
        fdt.endNode()

        fdt.beginNode("syscon@11100000")
        fdt.property("phandle", cells: [sysconPhandle])
        fdt.property("reg", cells: [0, RV32Machine.sysconBase, 0, 0x1000])
        fdt.property("compatible", string: "syscon")
        fdt.endNode()

        fdt.beginNode("clint@11000000")
        fdt.property("interrupts-extended", cells: [intcPhandle, 3, intcPhandle, 7])
        fdt.property("reg", cells: [0, RV32Machine.clintBase, 0, 0x10000])
        fdt.property("compatible", strings: ["sifive,clint0", "riscv,clint0"])
        fdt.endNode()

        fdt.endNode() // soc
        fdt.endNode() // root
        return fdt.finish()
    }
}
