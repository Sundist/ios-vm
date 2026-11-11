// Unit tests for App/PCWeb/pvm-disk.js (no emulator needed).
// Run from the repository root: node tests/pcweb/native-disk-unit.js
"use strict";
const path = require("path");
const assert = require("assert");
const { NativeDisk } = require(path.join(__dirname, "../../App/PCWeb/pvm-disk.js"));

const CHUNK = NativeDisk.CHUNK;

function harness(size, { autoAck = true, cacheChunks } = {}) {
    const file = Buffer.alloc(size);
    for(let i = 0; i < size; i++) file[i] = i & 0xff;
    const state = { file, reads: [], messages: [], heldAcks: [] };
    const disk = new NativeDisk({
        name: "hda", url: "media/hda", size, writable: true, flushDelay: 1, cacheChunks,
        read: async (url, start, length) => {
            state.reads.push([start, length]);
            return new Uint8Array(file.subarray(start, start + length));
        },
        toBase64: async bytes => Buffer.from(bytes).toString("base64"),
        post: message => {
            state.messages.push(message);
            if(message.type !== "diskWrite") return;
            const apply = () => {
                Buffer.from(message.data, "base64").copy(file, message.offset);
                disk.ack(message.id, true);
            };
            if(autoAck) setImmediate(apply); else state.heldAcks.push(apply);
        },
    });
    state.disk = disk;
    return state;
}

const get = (disk, offset, len) => new Promise(resolve => disk.get(offset, len, resolve));
const set = (disk, offset, data) => new Promise(resolve => disk.set(offset, data, resolve));
const tick = () => new Promise(resolve => setTimeout(resolve, 5));

const tests = {
    async "reads across chunk boundaries"() {
        const h = harness(3 * CHUNK + 1000);
        const data = await get(h.disk, CHUNK - 512, 1024);
        assert.strictEqual(data.length, 1024);
        for(let i = 0; i < 1024; i++) assert.strictEqual(data[i], (CHUNK - 512 + i) & 0xff);
        assert.strictEqual(h.reads.length, 2);
        await get(h.disk, CHUNK - 512, 1024);
        assert.strictEqual(h.reads.length, 2, "second read must come from the cache");
    },

    async "reads the short last chunk"() {
        const h = harness(CHUNK + 1024);
        const data = await get(h.disk, CHUNK + 512, 512);
        assert.deepStrictEqual(h.reads[0], [CHUNK, 1024]);
        assert.strictEqual(data[0], (CHUNK + 512) & 0xff);
    },

    async "writes are visible immediately and persisted after ack"() {
        const h = harness(2 * CHUNK, { autoAck: false });
        const payload = new Uint8Array(512).fill(0xab);
        await set(h.disk, 4096, payload);
        let data = await get(h.disk, 4096, 512);         // uncached: overlay pending
        assert.ok(data.every(b => b === 0xab));
        data = await get(h.disk, 4096, 512);              // cached chunk was patched
        assert.ok(data.every(b => b === 0xab));

        await tick();
        assert.strictEqual(h.messages.filter(m => m.type === "diskWrite").length, 1);
        assert.strictEqual(h.disk.pending.size, 2, "pending until acknowledged");
        h.heldAcks.splice(0).forEach(f => f());
        await tick();
        assert.strictEqual(h.disk.pending.size, 0);
        assert.ok(h.file.subarray(4096, 4608).every(b => b === 0xab));
    },

    async "evicted chunk re-reads see unacknowledged writes"() {
        const h = harness(8 * CHUNK, { autoAck: false, cacheChunks: 1 });
        await set(h.disk, 100 * 256, new Uint8Array(256).fill(7));
        await get(h.disk, 5 * CHUNK, 16);                 // evicts nothing relevant
        await get(h.disk, 6 * CHUNK, 16);
        const data = await get(h.disk, 100 * 256, 256);   // file still has old data
        assert.ok(data.every(b => b === 7));
    },

    async "contiguous blocks are merged into one message"() {
        const h = harness(4 * CHUNK);
        await set(h.disk, 0, new Uint8Array(8192).fill(1));
        await set(h.disk, 8192, new Uint8Array(8192).fill(2));
        await set(h.disk, 65536, new Uint8Array(256).fill(3));
        assert.ok(await h.disk.flushAll());
        const writes = h.messages.filter(m => m.type === "diskWrite");
        assert.strictEqual(writes.length, 2);
        assert.strictEqual(writes[0].offset, 0);
        assert.strictEqual(Buffer.from(writes[0].data, "base64").length, 16384);
        assert.strictEqual(h.file[8192], 2);
        assert.strictEqual(h.file[65536], 3);
    },

    async "a rewrite during a flush is not lost"() {
        const h = harness(CHUNK, { autoAck: false });
        await set(h.disk, 0, new Uint8Array(256).fill(1));
        await tick();                                     // flush #1 in flight
        await set(h.disk, 0, new Uint8Array(256).fill(2));
        h.heldAcks.splice(0).forEach(f => f());           // ack old version
        await tick();
        assert.strictEqual(h.disk.pending.size, 1, "newer version stays pending");
        const data = await get(h.disk, 0, 256);
        assert.ok(data.every(b => b === 2));
        await tick();
        h.heldAcks.splice(0).forEach(f => f());
        await tick();
        assert.strictEqual(h.disk.pending.size, 0);
        assert.strictEqual(h.file[0], 2);
    },

    async "read-only disks ignore writes"() {
        const h = harness(CHUNK);
        h.disk.writable = false;
        await set(h.disk, 0, new Uint8Array(256).fill(9));
        assert.strictEqual(h.disk.pending.size, 0);
        const data = await get(h.disk, 0, 4);
        assert.deepStrictEqual(Array.from(data), [0, 1, 2, 3]);
    },

    async "state round trip keeps unflushed blocks"() {
        const h = harness(CHUNK, { autoAck: false });
        await set(h.disk, 512, new Uint8Array(256).fill(5));
        const saved = h.disk.get_state();
        const h2 = harness(CHUNK);
        h2.disk.set_state(saved);
        const data = await get(h2.disk, 512, 256);
        assert.ok(data.every(b => b === 5));
        assert.ok(await h2.disk.flushAll());
        assert.strictEqual(h2.file[512], 5);
    },
};

(async () => {
    let failed = 0;
    for(const [name, test] of Object.entries(tests)) {
        try {
            await test();
            console.log("ok   " + name);
        } catch(error) {
            failed++;
            console.log("FAIL " + name + "\n     " + (error && error.stack || error));
        }
    }
    process.exit(failed ? 1 : 0);
})();
