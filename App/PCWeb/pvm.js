// PocketVM PC page: boots v86 with the configuration sent by the iOS app,
// fits the screen, turns touches into a trackpad, and implements the
// save-state / power-off protocol with the app.
"use strict";

(function() {

const MB = 1024 * 1024;
const STATE_CHUNK = 4 * MB;

const post = message => {
    try {
        window.webkit.messageHandlers.pvm.postMessage(message);
    } catch(e) {
        console.log("pvm message", message);
    }
};

window.addEventListener("error", e => post({ type: "error", message: String(e.message) + " (" + e.filename + ":" + e.lineno + ")" }));
window.addEventListener("unhandledrejection", e => post({ type: "error", message: String((e.reason && e.reason.message) || e.reason) }));

let emulator = null;
const disks = {};
let restoring = false;

const container = document.getElementById("screen_container");
const touchLayer = document.getElementById("touch");
const keyboardField = document.querySelector(".phone_keyboard");
const keyboardButton = document.getElementById("keyboard_button");
const messageBox = document.getElementById("message");

function showMessage(text) {
    messageBox.textContent = text || "";
    messageBox.style.display = text ? "block" : "none";
}

// ---------------------------------------------------------------- screen

let scale = 1;

function fitScreen() {
    container.style.transform = "none";
    const w = container.offsetWidth || 720;
    const h = container.offsetHeight || 400;
    const W = window.innerWidth;
    const H = window.innerHeight;
    scale = Math.min(W / w, H / h);
    const x = (W - w * scale) / 2;
    const y = (H - h * scale) / 2;
    container.style.transform = "translate(" + x + "px, " + y + "px) scale(" + scale + ")";
}

window.addEventListener("resize", fitScreen);
setInterval(fitScreen, 500);

// ---------------------------------------------------------------- scancodes

// PS/2 set 1 make codes; values > 0xff are E0-prefixed.
const SCANCODES = {
    Escape: 0x01, Backspace: 0x0e, Tab: 0x0f, Enter: 0x1c, Space: 0x39,
    ControlLeft: 0x1d, ShiftLeft: 0x2a, AltLeft: 0x38, CapsLock: 0x3a,
    MetaLeft: 0xe05b, ContextMenu: 0xe05d,
    F1: 0x3b, F2: 0x3c, F3: 0x3d, F4: 0x3e, F5: 0x3f, F6: 0x40,
    F7: 0x41, F8: 0x42, F9: 0x43, F10: 0x44, F11: 0x57, F12: 0x58,
    Insert: 0xe052, Delete: 0xe053, Home: 0xe047, End: 0xe04f,
    PageUp: 0xe049, PageDown: 0xe051,
    ArrowUp: 0xe048, ArrowDown: 0xe050, ArrowLeft: 0xe04b, ArrowRight: 0xe04d,
};
"QWERTYUIOP".split("").forEach((c, i) => SCANCODES["Key" + c] = 0x10 + i);
"ASDFGHJKL".split("").forEach((c, i) => SCANCODES["Key" + c] = 0x1e + i);
"ZXCVBNM".split("").forEach((c, i) => SCANCODES["Key" + c] = 0x2c + i);
"1234567890".split("").forEach((c, i) => SCANCODES["Digit" + c] = 0x02 + i);

function scancodeBytes(code, release) {
    const low = (code & 0xff) | (release ? 0x80 : 0);
    return code > 0xff ? [0xe0, low] : [low];
}

function keyNameForChar(ch) {
    if(/^[a-z]$/i.test(ch)) return "Key" + ch.toUpperCase();
    if(/^[0-9]$/.test(ch)) return "Digit" + ch;
    if(ch === " ") return "Space";
    return null;
}

/** Presses the given keys in order and releases them in reverse order. */
function pressKeys(names) {
    if(!emulator) return;
    const codes = names.map(n => SCANCODES[n]).filter(c => c !== undefined);
    const bytes = [];
    codes.forEach(c => bytes.push(...scancodeBytes(c, false)));
    codes.slice().reverse().forEach(c => bytes.push(...scancodeBytes(c, true)));
    emulator.keyboard_send_scancodes(bytes);
}

// Sticky modifiers set from the app's key bar ("ctrl" then "c" = Ctrl+C).
const latched = new Set();

function typeText(text) {
    if(!emulator) return;
    for(const ch of text) {
        if(latched.size) {
            const name = keyNameForChar(ch);
            const mods = Array.from(latched);
            latched.clear();
            post({ type: "modifiers", active: [] });
            if(name) {
                pressKeys(mods.concat([name]));
                continue;
            }
        }
        if(ch === "\n" || ch === "\r") {
            pressKeys(["Enter"]);
        } else if(ch === "\t") {
            pressKeys(["Tab"]);
        } else {
            emulator.keyboard_send_text(ch);
        }
    }
}

// The on-screen keyboard: v86 reads the textarea itself; we only intercept
// characters while a modifier is latched.
keyboardField.addEventListener("beforeinput", e => {
    if(latched.size && e.inputType === "insertText" && e.data) {
        e.preventDefault();
        e.stopImmediatePropagation();
        typeText(e.data);
    }
}, true);

keyboardButton.addEventListener("click", e => {
    e.preventDefault();
    if(document.activeElement === keyboardField) {
        keyboardField.blur();
    } else {
        keyboardField.value = "";
        keyboardField.focus();
    }
});

// ---------------------------------------------------------------- trackpad

const SPEED = 1.6;
let lastX = 0, lastY = 0, startTime = 0, moved = 0, maxFingers = 0;
let lastTapTime = 0, dragging = false, wheelAccumulator = 0;

function mouseButtons(left, middle, right) {
    if(emulator) emulator.bus.send("mouse-click", [left, middle, right]);
}

function click(button) {
    mouseButtons(button === 0, button === 1, button === 2);
    setTimeout(() => mouseButtons(false, false, false), 60);
}

touchLayer.addEventListener("touchstart", e => {
    e.preventDefault();
    const t = e.touches[0];
    if(e.touches.length === 1) {
        lastX = t.clientX;
        lastY = t.clientY;
        startTime = Date.now();
        moved = 0;
        maxFingers = 1;
        // Tap, then touch again and move = drag with the left button held.
        if(Date.now() - lastTapTime < 300) {
            dragging = true;
            mouseButtons(true, false, false);
        }
    } else {
        maxFingers = Math.max(maxFingers, e.touches.length);
        lastY = e.touches[0].clientY;
    }
}, { passive: false });

touchLayer.addEventListener("touchmove", e => {
    e.preventDefault();
    if(!emulator) return;
    const t = e.touches[0];
    const dx = t.clientX - lastX;
    const dy = t.clientY - lastY;
    lastX = t.clientX;
    lastY = t.clientY;
    moved += Math.abs(dx) + Math.abs(dy);
    if(e.touches.length >= 2) {
        wheelAccumulator += dy;
        while(Math.abs(wheelAccumulator) > 20) {
            const step = wheelAccumulator > 0 ? -1 : 1;
            emulator.bus.send("mouse-wheel", [0, step]);
            wheelAccumulator += step * 20;
        }
        return;
    }
    const factor = SPEED / Math.max(scale, 0.25);
    emulator.bus.send("mouse-delta", [dx * factor, -dy * factor]);
}, { passive: false });

touchLayer.addEventListener("touchend", e => {
    e.preventDefault();
    if(e.touches.length > 0) return;
    const quick = Date.now() - startTime < 250 && moved < 12;
    if(dragging) {
        dragging = false;
        mouseButtons(false, false, false);
        lastTapTime = 0;
        return;
    }
    if(quick) {
        if(maxFingers >= 2) {
            click(2);
        } else {
            click(0);
            lastTapTime = Date.now();
        }
    }
}, { passive: false });

// ---------------------------------------------------------------- helpers

function blobToBase64(bytes) {
    return new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => {
            const s = reader.result;
            resolve(s.slice(s.indexOf(",") + 1));
        };
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(new Blob([bytes]));
    });
}

async function flushDisks() {
    let ok = true;
    for(const disk of Object.values(disks)) {
        if(disk.writable) ok = (await disk.flushAll()) && ok;
    }
    return ok;
}

// ---------------------------------------------------------------- API used by the app

let statsTimer = null;
let lastCount = 0;
let lastStatsTime = 0;

window.pvm = {
    boot(config) {
        if(emulator) return;
        restoring = !!config.restoreState;
        showMessage(restoring ? "Restoring saved state…" : "Starting…");

        const options = {
            wasm_path: "v86.wasm",
            memory_size: config.memoryMB * MB,
            vga_memory_size: config.vgaMemoryMB * MB,
            screen_container: container,
            bios: { url: "bios/seabios.bin" },
            vga_bios: { url: "bios/vgabios.bin" },
            autostart: true,
            disable_mouse: true,     // the trackpad above drives the PS/2 mouse
            acpi: !!config.acpi,
            boot_order: config.bootOrder || 0,
            fastboot: true,
        };
        if(config.cpuidLevel) options.cpuid_level = config.cpuidLevel;

        const drive = (name, info, writable) => {
            disks[name] = new NativeDisk({
                name, url: "media/" + name, size: info.size, writable, post,
            });
            return disks[name];
        };
        if(config.cdrom) options.cdrom = drive("cdrom", config.cdrom, false);
        if(config.hda) options.hda = drive("hda", config.hda, true);
        if(config.fda) options.fda = { url: "media/fda", size: config.fda.size };
        if(restoring) options.initial_state = { url: "media/state" };

        try {
            emulator = new V86(options);
        } catch(error) {
            post({ type: "bootFailed", message: String(error && error.message || error), restoring });
            return;
        }

        emulator.add_listener("emulator-ready", () => {
            showMessage("");
            post({ type: "ready", restored: restoring });
        });
        emulator.add_listener("emulator-started", () => post({ type: "running", running: true }));
        emulator.add_listener("emulator-stopped", () => post({ type: "running", running: false }));
        emulator.add_listener("screen-set-size", () => setTimeout(fitScreen, 0));
        emulator.add_listener("download-progress", e => {
            if(e && e.total && e.file_name && /state/.test(e.file_name)) {
                showMessage("Restoring saved state… " + Math.round(100 * e.loaded / e.total) + "%");
            }
        });

        statsTimer = setInterval(() => {
            if(!emulator) return;
            const now = performance.now();
            const count = emulator.get_instruction_counter();
            if(lastStatsTime) {
                const ips = (count - lastCount) / ((now - lastStatsTime) / 1000);
                post({ type: "stats", ips: Math.max(0, ips) });
            }
            lastCount = count;
            lastStatsTime = now;
        }, 1000);
    },

    pause() { emulator && emulator.stop(); },
    resume() { emulator && emulator.run(); },
    reset() { emulator && emulator.restart(); },

    text(s) { typeText(s); },
    keys(names) { pressKeys(names); },
    ctrlAltDel() { pressKeys(["ControlLeft", "AltLeft", "Delete"]); },
    latch(name, on) {
        if(on) latched.add(name); else latched.delete(name);
        post({ type: "modifiers", active: Array.from(latched) });
    },
    focusKeyboard() { keyboardField.focus(); },

    ack(disk, id, ok) {
        if(disks[disk]) disks[disk].ack(id, ok);
    },

    async insertCD(info) {
        if(!emulator) return;
        disks.cdrom = new NativeDisk({ name: "cdrom", url: "media/cdrom?" + Date.now(), size: info.size, writable: false, post });
        await emulator.set_cdrom(disks.cdrom);
    },

    ejectCD() {
        if(emulator) emulator.eject_cdrom();
        delete disks.cdrom;
    },

    /** Saves CPU/RAM/device state in chunks, then powers off. */
    async saveState() {
        if(!emulator) return;
        try {
            showMessage("Saving state…");
            await emulator.stop();
            await flushDisks();
            const state = new Uint8Array(await emulator.save_state());
            const total = Math.ceil(state.length / STATE_CHUNK);
            for(let i = 0; i < total; i++) {
                const part = state.subarray(i * STATE_CHUNK, (i + 1) * STATE_CHUNK);
                post({ type: "stateChunk", index: i, total, data: await blobToBase64(part) });
                showMessage("Saving state… " + Math.round(100 * (i + 1) / total) + "%");
            }
            post({ type: "stateDone", size: state.length });
            await window.pvm.powerOff();
        } catch(error) {
            showMessage("");
            post({ type: "stateFailed", message: String(error && error.message || error) });
            emulator && emulator.run();
        }
    },

    async powerOff() {
        if(!emulator) {
            post({ type: "poweredOff", clean: true });
            return;
        }
        try {
            await emulator.stop();
        } catch(e) {}
        const clean = await flushDisks();
        clearInterval(statsTimer);
        try {
            await emulator.destroy();
        } catch(e) {}
        emulator = null;
        showMessage("");
        post({ type: "poweredOff", clean });
    },
};

post({ type: "pageReady" });

})();
