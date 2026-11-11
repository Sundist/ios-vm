// Boots v86 (the exact build shipped in the app) with NativeDisk as the hard
// disk and checks that guest writes reach the backing "file" and survive a
// fresh boot. Run from the repository root: node tests/pcweb/disk-test.js
"use strict";
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const web = path.join(__dirname, "../../App/PCWeb");
const { V86 } = require(path.join(web, "libv86.js"));
const { NativeDisk } = require(path.join(web, "pvm-disk.js"));

const DISK_SIZE = 1024 * 1024;
const image = Buffer.alloc(DISK_SIZE);
fs.readFileSync(path.join(__dirname, "bootsector.bin")).copy(image, 0);
Buffer.from("ORIGINAL").copy(image, 2 * 512);

let reads = 0;
let writes = 0;

function makeDisk() {
    const disk = new NativeDisk({
        name: "hda",
        url: "media/hda",
        size: DISK_SIZE,
        writable: true,
        flushDelay: 10,
        read: async (url, start, length) => {
            reads++;
            return new Uint8Array(image.subarray(start, start + length));
        },
        toBase64: async bytes => Buffer.from(bytes).toString("base64"),
        post: message => {
            if(message.type === "diskWrite") {
                writes++;
                Buffer.from(message.data, "base64").copy(image, message.offset);
                setImmediate(() => disk.ack(message.id, true));
            } else if(message.type === "error") {
                console.error("disk error:", message.message);
            }
        },
    });
    return disk;
}

function boot(disk) {
    return new Promise((resolve, reject) => {
        const emulator = new V86({
            wasm_path: path.join(web, "v86.wasm"),
            bios: { url: path.join(web, "bios/seabios.bin") },
            vga_bios: { url: path.join(web, "bios/vgabios.bin") },
            hda: disk,
            memory_size: 16 * 1024 * 1024,
            autostart: true,
            disable_keyboard: true,
            disable_mouse: true,
            disable_speaker: true,
        });
        let serial = "";
        const timer = setTimeout(() => {
            emulator.destroy();
            reject(new Error("timeout, serial output: " + JSON.stringify(serial)));
        }, 60000);
        emulator.add_listener("serial0-output-byte", byte => {
            serial += String.fromCharCode(byte);
            if(serial.endsWith("|DONE") || serial.endsWith("|FAIL")) {
                clearTimeout(timer);
                setTimeout(async () => {
                    await emulator.destroy();
                    resolve(serial);
                }, 50);
            }
        });
    });
}

(async () => {
    const disk1 = makeDisk();
    const first = await boot(disk1);
    assert.strictEqual(first, "ORIGINAL|DONE");
    assert.ok(await disk1.flushAll(), "pending writes were not flushed");
    assert.strictEqual(image.subarray(1024, 1032).toString(), "WRITTEN!");
    assert.ok(writes > 0 && reads > 0);

    const second = await boot(makeDisk());
    assert.strictEqual(second, "WRITTEN!|DONE");
    console.log("disk-test passed (" + reads + " chunk reads, " + writes + " write messages)");
    process.exit(0);
})().catch(error => {
    console.error(error);
    process.exit(1);
});
