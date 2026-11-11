import Foundation

/// A small built-in firmware so a new machine can be started without
/// downloading anything. It prints a banner, then runs an echo console with
/// line editing; Ctrl-D powers the machine off through the syscon device.
/// The idle loop programs the CLINT timer and sleeps with WFI, so an idle
/// guest does not burn the host CPU.
public enum MonitorFirmware {
    public static let banner = """
    \r
    PocketVM Monitor 1.0 (RV32IMA, machine mode)\r
    Built-in firmware - attach a Linux kernel image in Settings to boot Linux.\r
    Type text and press Return. Ctrl-D powers the machine off.\r
    \r

    """

    public static let image: Data = {
        var a = RVAssembler()

        a.label("start")
        a.lui(.s0, RV32Machine.uartBase >> 12)          // s0 = UART
        a.lui(.s1, RV32Machine.clintBase >> 12)         // s1 = CLINT
        a.li(.t0, 0x80)
        a.csrrs(.zero, 0x304, .t0)                       // mie.MTIE = 1 (wake-up source only)
        a.la(.a0, "banner")
        a.call("puts")

        a.label("prompt")
        a.la(.a0, "promptText")
        a.call("puts")

        a.label("loop")
        a.lbu(.t0, 5, .s0)                               // LSR
        a.andi(.t0, .t0, 1)
        a.beq(.t0, .zero, "idle")
        a.lbu(.t1, 0, .s0)                               // RBR
        a.li(.t2, 4)                                     // Ctrl-D
        a.beq(.t1, .t2, "poweroff")
        a.li(.t2, 13)                                    // CR
        a.beq(.t1, .t2, "newline")
        a.li(.t2, 10)                                    // LF
        a.beq(.t1, .t2, "newline")
        a.li(.t2, 127)                                   // DEL
        a.beq(.t1, .t2, "backspace")
        a.li(.t2, 8)                                     // BS
        a.beq(.t1, .t2, "backspace")
        a.sb(.t1, 0, .s0)                                // echo
        a.j("loop")

        a.label("newline")
        a.la(.a0, "newlineText")
        a.call("puts")
        a.j("prompt")

        a.label("backspace")
        a.la(.a0, "backspaceText")
        a.call("puts")
        a.j("loop")

        // Sleep ~2 ms: mtimecmp = mtime + 2000, then WFI.
        a.label("idle")
        a.lui(.t3, (RV32Machine.clintBase + 0xc000) >> 12)
        a.lw(.t5, -8, .t3)                               // mtime low  (0x1100bff8)
        a.lw(.t6, -4, .t3)                               // mtime high (0x1100bffc)
        a.addi(.a1, .t5, 2000)
        a.sltu(.a2, .a1, .t5)                            // carry
        a.add(.t6, .t6, .a2)
        a.li(.a3, 0x4000)
        a.add(.a3, .a3, .s1)                             // a3 = mtimecmp
        a.sw(.t6, 4, .a3)
        a.sw(.a1, 0, .a3)
        a.wfi()
        a.j("loop")

        a.label("poweroff")
        a.la(.a0, "byeText")
        a.call("puts")
        a.li(.t0, RV32Machine.sysconBase)
        a.li(.t1, RV32Machine.sysconPowerOff)
        a.sw(.t1, 0, .t0)
        a.label("hang")
        a.j("hang")

        // puts(a0): writes a NUL-terminated string to the UART.
        a.label("puts")
        a.lbu(.t0, 0, .a0)
        a.beq(.t0, .zero, "putsDone")
        a.sb(.t0, 0, .s0)
        a.addi(.a0, .a0, 1)
        a.j("puts")
        a.label("putsDone")
        a.ret()

        a.label("banner")
        a.ascii(banner)
        a.label("promptText")
        a.ascii("monitor> ")
        a.label("newlineText")
        a.ascii("\r\n")
        a.label("backspaceText")
        a.ascii("\u{8} \u{8}")
        a.label("byeText")
        a.ascii("\r\nPowering off.\r\n")
        a.align(4)
        return a.assemble()
    }()
}
