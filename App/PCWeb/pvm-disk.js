// PocketVM disk bridge for v86.
//
// NativeDisk implements the buffer interface v86 accepts for drives
// (byteLength, load, get, set, get_and_cache, get_state, set_state).
//
//  * Reads are served by the iOS app through `Range:` requests on the
//    app's private URL scheme, in 64 KiB chunks kept in an LRU cache.
//  * Writes are kept in a pending map (256-byte blocks, like v86) and
//    flushed to the app every few hundred milliseconds. The app writes them
//    into the real disk image file and acknowledges; only then are they
//    dropped from the pending map. Reads always overlay pending blocks, so
//    the guest never sees stale data.
"use strict";

(function(global) {

const CHUNK = 64 * 1024;
const BLOCK = 256;
const MAX_RUN_BLOCKS = 4096;          // 1 MiB per write message
const DEFAULT_CACHE_CHUNKS = 1024;    // 64 MiB read cache

function defaultRead(url, start, length) {
    return new Promise((resolve, reject) => {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", url, true);
        xhr.responseType = "arraybuffer";
        xhr.setRequestHeader("Range", "bytes=" + start + "-" + (start + length - 1));
        xhr.onload = () => {
            if(xhr.status === 206 || xhr.status === 200) {
                resolve(new Uint8Array(xhr.response));
            } else {
                reject(new Error("read " + url + " failed with status " + xhr.status));
            }
        };
        xhr.onerror = () => reject(new Error("read " + url + " failed"));
        xhr.send(null);
    });
}

function defaultToBase64(bytes) {
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

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

/**
 * @param {Object} options
 *   name      - drive name reported to the app ("hda", "cdrom", ...)
 *   url       - URL serving the image with Range support
 *   size      - image size in bytes
 *   writable  - whether writes are persisted (false for CD-ROMs)
 *   post      - function(message) sending a message to the app
 *   read      - optional override of the range reader (for tests)
 *   toBase64  - optional override of the base64 encoder (for tests)
 *   flushDelay, cacheChunks - tuning
 */
function NativeDisk(options) {
    this.name = options.name;
    this.url = options.url;
    this.byteLength = options.size;
    this.writable = !!options.writable;
    this.post = options.post;
    this.read = options.read || defaultRead;
    this.toBase64 = options.toBase64 || defaultToBase64;
    this.flushDelay = options.flushDelay === undefined ? 300 : options.flushDelay;
    this.cacheChunks = options.cacheChunks || DEFAULT_CACHE_CHUNKS;

    this.chunks = new Map();     // chunk index -> Uint8Array
    this.inflight = new Map();   // chunk index -> Promise<Uint8Array>
    this.pending = new Map();    // block index -> { data, version }
    this.version = 0;
    this.acks = new Map();       // write id -> function(ok)
    this.nextWriteId = 1;
    this.flushTimer = null;
    this.flushing = null;        // Promise while a flush runs
    this.failedWrites = 0;

    this.onload = undefined;
    this.onprogress = undefined;
}

NativeDisk.prototype.load = async function() {
    this.onload && this.onload(Object.create(null));
};

NativeDisk.prototype.overlayPending = function(target, start) {
    if(this.pending.size === 0) return;
    const end = start + target.length;
    for(let off = start - (start % BLOCK); off < end; off += BLOCK) {
        const entry = this.pending.get(off / BLOCK);
        if(!entry) continue;
        const from = Math.max(off, start);
        const to = Math.min(off + BLOCK, end);
        target.set(entry.data.subarray(from - off, to - off), from - start);
    }
};

NativeDisk.prototype.fetchChunk = function(index) {
    const existing = this.inflight.get(index);
    if(existing) return existing;

    const start = index * CHUNK;
    const length = Math.min(CHUNK, this.byteLength - start);
    const promise = this.read(this.url, start, length).then(data => {
        this.inflight.delete(index);
        const chunk = new Uint8Array(length);
        chunk.set(data.subarray(0, Math.min(length, data.length)));
        this.overlayPending(chunk, start);
        this.chunks.set(index, chunk);
        while(this.chunks.size > this.cacheChunks) {
            this.chunks.delete(this.chunks.keys().next().value);
        }
        return chunk;
    }, error => {
        this.inflight.delete(index);
        throw error;
    });
    this.inflight.set(index, promise);
    return promise;
};

NativeDisk.prototype.get = function(offset, len, fn) {
    const first = Math.floor(offset / CHUNK);
    const last = Math.floor((offset + len - 1) / CHUNK);
    const parts = new Array(last - first + 1);
    const missing = [];

    for(let i = first; i <= last; i++) {
        const chunk = this.chunks.get(i);
        if(chunk) {
            // refresh LRU position
            this.chunks.delete(i);
            this.chunks.set(i, chunk);
            parts[i - first] = chunk;
        } else {
            missing.push(i);
        }
    }

    const assemble = () => {
        if(first === last) {
            const s = offset - first * CHUNK;
            fn(parts[0].slice(s, s + len));
            return;
        }
        const out = new Uint8Array(len);
        for(let i = first; i <= last; i++) {
            const chunk = parts[i - first];
            const chunkStart = i * CHUNK;
            const from = Math.max(offset, chunkStart);
            const to = Math.min(offset + len, chunkStart + chunk.length);
            out.set(chunk.subarray(from - chunkStart, to - chunkStart), from - offset);
        }
        fn(out);
    };

    if(missing.length === 0) {
        assemble();
        return;
    }

    Promise.all(missing.map(i => this.fetchChunk(i).then(chunk => { parts[i - first] = chunk; })))
        .then(assemble, error => {
            this.post({ type: "error", message: "Disk " + this.name + ": " + error.message });
            const out = new Uint8Array(len);
            this.overlayPending(out, offset);
            fn(out);
        });
};

NativeDisk.prototype.get_and_cache = function(offset, len, fn) {
    this.get(offset, len, fn);
};

NativeDisk.prototype.set = function(start, data, fn) {
    if(!this.writable) {
        fn();
        return;
    }

    const len = data.length;
    for(let i = 0; i < len; i += BLOCK) {
        this.pending.set((start + i) / BLOCK, {
            data: data.slice(i, i + BLOCK),
            version: ++this.version,
        });
    }

    // Keep cached chunks coherent.
    const first = Math.floor(start / CHUNK);
    const last = Math.floor((start + len - 1) / CHUNK);
    for(let i = first; i <= last; i++) {
        const chunk = this.chunks.get(i);
        if(!chunk) continue;
        const chunkStart = i * CHUNK;
        const from = Math.max(start, chunkStart);
        const to = Math.min(start + len, chunkStart + chunk.length);
        chunk.set(data.subarray(from - start, to - start), from - chunkStart);
    }

    this.scheduleFlush();
    fn();
};

NativeDisk.prototype.scheduleFlush = function() {
    if(this.flushTimer !== null) return;
    this.flushTimer = setTimeout(() => {
        this.flushTimer = null;
        this.flush();
    }, this.flushDelay);
};

/** Sends all pending writes to the app and waits for the acknowledgements. */
NativeDisk.prototype.flush = function() {
    if(this.flushing) {
        return this.flushing.then(() => this.pending.size ? this.flush() : undefined);
    }
    if(this.pending.size === 0) {
        return Promise.resolve();
    }

    const run = async () => {
        const keys = Array.from(this.pending.keys()).sort((a, b) => a - b);
        const waits = [];
        let i = 0;
        while(i < keys.length) {
            let j = i;
            while(j + 1 < keys.length && keys[j + 1] === keys[j] + 1 && j + 1 - i < MAX_RUN_BLOCKS) {
                j++;
            }
            const count = j - i + 1;
            const buffer = new Uint8Array(count * BLOCK);
            const versions = [];
            for(let k = 0; k < count; k++) {
                const entry = this.pending.get(keys[i + k]);
                buffer.set(entry.data, k * BLOCK);
                versions.push([keys[i + k], entry.version]);
            }
            const id = this.nextWriteId++;
            const data = await this.toBase64(buffer);
            waits.push(new Promise(resolve => {
                this.acks.set(id, ok => {
                    if(ok) {
                        for(const [key, version] of versions) {
                            const entry = this.pending.get(key);
                            if(entry && entry.version === version) {
                                this.pending.delete(key);
                            }
                        }
                    } else {
                        this.failedWrites++;
                    }
                    resolve();
                });
            }));
            this.post({ type: "diskWrite", disk: this.name, id, offset: keys[i] * BLOCK, data });
            i = j + 1;
        }
        await Promise.all(waits);
    };

    this.flushing = run().finally(() => {
        this.flushing = null;
        if(this.pending.size && this.failedWrites === 0) this.scheduleFlush();
    });
    return this.flushing;
};

/** Called by the app once a write has been stored. */
NativeDisk.prototype.ack = function(id, ok) {
    const callback = this.acks.get(id);
    if(callback) {
        this.acks.delete(id);
        callback(ok !== false);
    }
};

/** Flushes until nothing is pending (or writes keep failing). */
NativeDisk.prototype.flushAll = async function() {
    if(this.flushTimer !== null) {
        clearTimeout(this.flushTimer);
        this.flushTimer = null;
    }
    for(let attempt = 0; attempt < 5 && this.pending.size; attempt++) {
        this.failedWrites = 0;
        await this.flush();
        if(this.failedWrites) await sleep(100);
    }
    while(this.flushing) await this.flushing;
    return this.pending.size === 0;
};

// The image file itself is always up to date after flushAll(), so a saved
// state only needs the (normally empty) set of unflushed blocks.
NativeDisk.prototype.get_state = function() {
    const blocks = [];
    for(const [index, entry] of this.pending) blocks.push([index, entry.data]);
    return [blocks];
};

NativeDisk.prototype.set_state = function(state) {
    const blocks = (state && state[0]) || [];
    this.chunks.clear();
    for(const [index, data] of blocks) {
        this.pending.set(index, { data: new Uint8Array(data), version: ++this.version });
    }
    if(this.pending.size) this.scheduleFlush();
};

NativeDisk.prototype.get_buffer = function(fn) {
    fn(undefined);
};

NativeDisk.CHUNK = CHUNK;
NativeDisk.BLOCK = BLOCK;

global.NativeDisk = NativeDisk;
if(typeof module !== "undefined" && module.exports) {
    module.exports = { NativeDisk };
}

})(typeof window !== "undefined" ? window : globalThis);
