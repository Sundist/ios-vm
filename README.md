# PocketVM — a virtual machine manager for iPhone

PocketVM is a VirtualBox-style virtual machine app for iPhone and iPad. You can create
machines, edit their settings, start, pause, reset and power them off, save their state and
restore it later, and use the guest full screen with touch, the on-screen keyboard or a
hardware keyboard.

> **Why not VirtualBox itself?** iOS does not let App Store apps use Hypervisor.framework or
> generate code at run time (JIT). Hardware-assisted virtualization like VirtualBox's is
> therefore impossible on an iPhone. PocketVM takes the same route as UTM SE: it **emulates**
> the guest CPU. This follows the iOS rules and needs no jailbreak.

## Engines

| Engine | Guests | How it runs |
|--------|--------|-------------|
| **RISC-V** (built-in) | PocketVM Monitor, 32-bit RISC-V no-MMU Linux | Swift interpreter |
| **PC** ([v86](https://github.com/copy/v86)) | 32-bit x86: Windows 95–XP, Vista/7 32-bit, Linux, DOS | x86 → WebAssembly JIT inside WebKit |
| **QEMU** ([UTM's fork](https://github.com/utmapp/qemu)) | Windows 11 ARM64 / x64, 64-bit Linux | QEMU as a framework, on a thread in the app |

## Features

- **VM manager:** machine list, details pane (General, System, Storage, Serial Port,
  Snapshots / Saved State, Description), creation wizard, settings, clone and delete.
- **Storage:** ISO images are used in place (Files, iCloud, On My iPhone) without copying;
  blank sparse hard disks or existing raw `.img` files; floppy images for the PC engine.
- **Home Screen:** every machine can be started like an app, through a Shortcuts icon, a
  widget or Siri (see below).
- Machines live in `Documents/Machines/` and are visible in the Files app.

### RISC-V engine

- RV32IMA + Zicsr CPU (machine mode, one hart) with a memory map compatible with
  `mini-rv32ima`:
  - 1–512 MB RAM (`0x8000_0000`)
  - NS16550A UART serial console (`0x1000_0000`)
  - CLINT timer, 1 MHz (`0x1100_0000`)
  - syscon power off / reboot (`0x1110_0000`)
  - a generated device tree (DTB) and boot arguments for Linux
- **PocketVM Monitor:** a small built-in firmware that needs no files. It echoes what you
  type; Ctrl-D powers the machine off.
- **Linux (RISC-V 32-bit, no-MMU):** boots an `Image` kernel with a built-in initramfs, such as
  the images built for `mini-rv32ima`.
- **Console:** handles VT100 escape sequences (erase, cursor movement; colours are ignored).
  Keys go straight to the guest from the software or a hardware keyboard, and a key bar
  provides Esc, Tab, Ctrl and the arrow keys. Copy, paste and font size are supported.
- **Snapshots:** the whole CPU, device and RAM state; *Restore* continues where it was saved.
- An idle guest executes `WFI` and the engine sleeps, so it does not waste CPU or battery.

### PC engine (Windows and ISOs, 32-bit x86)

PC machines run on the open-source x86 emulator [v86](https://github.com/copy/v86) (BSD-2,
version 0.5.471, in `App/PCWeb`). v86 translates x86 code to WebAssembly. On iOS only WebKit
may JIT-compile code, so v86 runs inside a `WKWebView`, which is far faster than an
interpreter.

- **Supported:** 32-bit x86 systems — Windows 95/98/ME, Windows 2000/XP, Windows Vista/7
  32-bit (experimental and very slow), 32-bit Linux ISOs, FreeDOS, KolibriOS, ReactOS…
- **Not supported:** 64-bit systems. Use the QEMU engine for those.
- **Hard disk:** what the guest writes is saved to the disk image on the iPhone right away.
- **Save State:** RAM and CPU state are saved so the machine continues where it left off.
- **Controls:** touch trackpad (tap = click, two-finger tap = right click, two-finger drag =
  scroll). ⌨︎ opens the keyboard. The key bar has Ctrl+Alt+Del, F1–F12, Esc, Win and the
  arrow keys. Hardware keyboards work too.
- **Installing Windows XP:** 512 MB RAM, 4 GB disk, ACPI off. Press F5 at the start of setup
  and choose "Standard PC".

### QEMU engine (Windows 11 ARM64 / x64, 64-bit Linux)

For 64-bit systems the app uses **QEMU**, the iOS build from UTM (as frameworks, running on a
thread inside the app).

- **Machine types:** Windows 11 ARM64 (recommended, faster), Windows 10/11 x64, Linux ARM64,
  Linux x86-64.
- **Hardware:**
  - ARM64: `virt`, UEFI, ramfb display, NVMe disk, USB CD/DVD, USB keyboard and tablet.
  - x64: `q35`, UEFI, VGA, NVMe disk, AHCI CD/DVD, e1000e network.
- **Windows 11 requirements:** the app attaches an answer disk (`autounattend.xml`) that skips
  the TPM 2.0, Secure Boot, 4 GB RAM and CPU checks and allows a local account without a
  network (Settings › "Skip Windows 11 checks").
- **Screen and input:** QEMU's VNC server is read over a local Unix socket.
  - Tap to click, touch and hold or tap with two fingers to right-click, drag to drag,
    drag with two fingers to scroll.
  - Keys are sent as scancodes through QEMU's extended key event extension (US layout).
- **Control:** pause, reset, ACPI shutdown and CD changes over QMP.

**About speed:**
- The App Store compatible **TCI** build uses no JIT and is very slow. Installing Windows 11
  can take hours.
- The **JIT** build is much faster but requires sideloading the app and enabling JIT with a
  debugger-based tool (e.g. StikDebug, SideStore).
- ARM64 guests are clearly faster than x64 guests.
- QEMU can run only once per app launch (the same limitation as in UTM).

**Getting the app with QEMU:**
1. **Prebuilt IPA:** run the **QEMU IPA** workflow in GitHub Actions (choose TCI or JIT). Sign
   the resulting unsigned `.ipa` with your own Apple ID using SideStore, AltStore or
   Sideloadly, and install it.
2. **Build it yourself:** on a Mac, run `scripts/fetch-qemu-sysroot.sh tci` (or `jit`), then
   generate the project with `xcodegen generate` and build for a device. The QEMU files are
   embedded during the build. `PVM_QEMU_FLAVOR` in `project.yml` must match the flavour you
   downloaded.

**Other notes:**
- The app requests the `increased-memory-limit` and `extended-virtual-addressing`
  entitlements for large guest RAM. If a free developer account cannot sign them, remove these
  two lines from `project.yml`.
- **License:** QEMU is licensed under GPLv2. Its source code is at
  https://github.com/utmapp/qemu; the build used is recorded in `QEMU-SOURCE.txt`.

## Adding a machine to the Home Screen

Every virtual machine can be added to the Home Screen in two ways (the app shows the steps
under **Add to Home Screen…**):

1. **App icon:** in the Shortcuts app, choose the *Start Virtual Machine* action, pick the
   machine, then use *Add to Home Screen*. You choose the name and icon; it looks like a
   separate app. You can also tell Siri "Start ‹name› in PocketVM".
2. **Widget:** add the *PocketVM › Virtual Machine* widget and edit it to choose the machine.

Both open the app with a `pocketvm://start?id=<uuid>` link and start the machine. The widget
and the app share an App Group. Before signing, replace `APP_BUNDLE_ID` and `APP_GROUP_ID` in
`project.yml` with your own identifiers.

## Project layout

```
VMCore/                    Platform-independent emulator core (Swift package)
  Sources/VMCore/
    RV32Machine.swift      CPU interpreter + memory + UART/CLINT/syscon
    DeviceTree.swift       FDT (DTB) writer
    RVAssembler.swift      Tiny RISC-V assembler (firmware and tests)
    MonitorFirmware.swift  Built-in demo firmware
    MachineSnapshot.swift  Save / restore machine state
    TerminalBuffer.swift   VT100-like terminal model
    VMEngine.swift         VM engine running on a background thread
    VMConfiguration.swift  Machine settings (Codable)
    VMStore*.swift         On-disk machine library, PC and QEMU media
    QEMUArguments.swift    QEMU command line builder
    RFBClient.swift        VNC client for the QEMU screen
    QMPClient.swift        QEMU Machine Protocol client
    FATImage.swift         FAT12 image + Windows answer file
  Sources/QEMUShim/        C layer that runs QEMU inside the app
  Tests/VMCoreTests/       Unit tests
App/                       SwiftUI iOS app
  AppModel.swift, VMSession.swift
  Views/                   RootView, MachineDetailView, NewMachineView,
                           MachineSettingsView, ConsoleView, TerminalInputView, …
App/PC/                    PC engine (WKWebView + v86, disk/state bridge)
App/PCWeb/                 v86, BIOS images and page scripts (pvm.js, pvm-disk.js)
App/QEMU/                  QEMU engine (launcher, VNC screen, touch input)
App/Intents/, Shared/      App Intents (Shortcuts / Siri)
Widget/                    Home Screen widget
tests/pcweb/               Disk bridge tests (Node.js)
scripts/fetch-v86.sh       Downloads v86 and the BIOS images at a pinned version
scripts/fetch-qemu-sysroot.sh  Downloads and trims UTM's iOS QEMU sysroot
project.yml                XcodeGen project definition
```

## Building

Requirements: Xcode 15 or later (iOS 17 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate          # creates PocketVM.xcodeproj
open PocketVM.xcodeproj
```

In Xcode, choose your own Team under *Signing & Capabilities*, change
`PRODUCT_BUNDLE_IDENTIFIER` if needed, and run the app on your iPhone. For speed, build with
the **Release** configuration; the interpreter is much slower in Debug builds.

Core tests:

```bash
swift test --package-path VMCore
node tests/pcweb/native-disk-unit.js
node tests/pcweb/disk-test.js
```

GitHub Actions (`.github/workflows/ci.yml`) runs the tests on every push and builds the app
and widget for the iOS Simulator; `.github/workflows/qemu-ipa.yml` builds the device IPA with
the QEMU engine.

## Running RISC-V Linux

1. Get an RV32 no-MMU Linux `Image`, for example by building it with the buildroot
   configuration of [cnlohr/mini-rv32ima](https://github.com/cnlohr/mini-rv32ima) or by using
   one of the images that project publishes.
2. In the app, tap **+**, choose type *Linux (RISC-V 32-bit, no-MMU)*, set the memory to
   64 MB and choose the file as *Kernel Image*.
3. Tap **Start**. Boot messages appear in the console; type `poweroff` to shut the machine
   down cleanly.

Default boot arguments:
`earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0`

## Roadmap

- Saved state (qcow2 + savevm), TPM (swtpm) and a SPICE display for the QEMU engine
- Network drivers out of the box for Windows 11 ARM64 guests
- Shared folders between the iPhone and guests
- A framebuffer display for the RISC-V engine
- Compressed snapshots
