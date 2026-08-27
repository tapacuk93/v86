#!/usr/bin/env node
// Boot a Windows install ISO and report where it gets to. This is the harness the 64-bit work is
// driven from: Windows is the only guest at hand that exercises long mode end to end, and it gives
// no serial output, so what it is doing has to be read off the screen and the cpu state instead.
//
// Every SAMPLE_MS it writes a screenshot and a line of cpu state. A run that is making progress
// moves eip around; a run that has wedged repeats one address, and the -hot report at the end says
// which one, which is the thing to go and look at.
//
// Usage:
//   make debug-with-long-mode
//   ./tests/manual/boot-windows.mjs ~/Downloads/Win10_22H2_EnglishInternational_x64v1.iso [seconds]
//
// Environment:
//   OUT=dir          where screenshots and the log go (default build/boot-windows)
//   MEMORY=mb        guest memory in MiB (default 1024; this host has 8 GiB, and a larger guest
//                    swaps, which looks exactly like the emulator being slow)
//   LOG_LEVEL=n      v86 log mask, see src/const.js
//   SAMPLE_MS=n      how often to sample cpu state (default 250)
//   SHOT_MS=n        how often to write a screenshot (default 5000)
//   DISABLE_JIT=1    interpret everything, for telling a codegen bug from an interpreter one
//   HOT_FROM=n       ignore the first n seconds in the hot-address report, so that a phase late in
//                    the boot is not drowned out by the phases that worked
//   KEYS_AT=n,m,...  press a key at each of these times, in seconds. A guest polling int 16h is
//                    waiting for one; whether pressing it changes anything says which guest it is

import fs from "node:fs";
import zlib from "node:zlib";
import url from "node:url";

// v86 builds its framebuffer through ImageData, which browsers provide and node does not; without
// it vga.js takes its "TODO: nodejs" branch and leaves image_data null, so there is nothing to
// screenshot however graphical the guest gets. Everything downstream only reads .data, .width and
// .height, so a three field stand-in is enough.
globalThis.ImageData ??= class ImageData {
    constructor(data, width, height)
    {
        this.data = data;
        this.width = width;
        this.height = height;
    }
};

const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const { V86 } = await import(__dirname + "../../src/main.js");

const iso = process.argv[2];
const run_seconds = +process.argv[3] || 120;
if(!iso || !fs.existsSync(iso))
{
    console.error("usage: boot-windows.mjs <iso> [seconds]");
    process.exit(1);
}

const OUT = process.env.OUT || __dirname + "../../build/boot-windows";
const MEMORY = (+process.env.MEMORY || 1024) * 1024 * 1024;
const SAMPLE_MS = +process.env.SAMPLE_MS || 250;
const SHOT_MS = +process.env.SHOT_MS || 5000;
const HOT_FROM = +process.env.HOT_FROM || 0;
const KEYS_AT = (process.env.KEYS_AT || "").split(",").filter(Boolean).map(Number);

fs.mkdirSync(OUT, { recursive: true });
const log_file = fs.createWriteStream(OUT + "/boot.log");
function note(line)
{
    console.log(line);
    log_file.write(line + "\n");
}

// A minimal PNG writer, so that a screenshot needs nothing outside node. One IDAT, filter 0 on
// every scanline, which zlib compresses well enough for a mostly flat boot screen.
function png(width, height, rgba)
{
    const raw = Buffer.alloc(height * (1 + width * 4));
    for(let y = 0; y < height; y++)
    {
        raw[y * (1 + width * 4)] = 0;
        Buffer.from(rgba.buffer, rgba.byteOffset + y * width * 4, width * 4)
            .copy(raw, y * (1 + width * 4) + 1);
    }

    const chunk = (type, body) => {
        const out = Buffer.alloc(12 + body.length);
        out.writeUInt32BE(body.length, 0);
        out.write(type, 4, "ascii");
        body.copy(out, 8);
        out.writeInt32BE(zlib.crc32(out.subarray(4, 8 + body.length)) | 0, 8 + body.length);
        return out;
    };

    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;   // bit depth
    ihdr[9] = 6;   // truecolour with alpha
    return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk("IHDR", ihdr),
        chunk("IDAT", zlib.deflateSync(raw)),
        chunk("IEND", Buffer.alloc(0)),
    ]);
}

// A disk backed by synchronous reads straight out of the file.
//
// v86's own AsyncFileBuffer would do, but it answers every read a microtask later and caches what
// it read in 256-byte blocks. Both hurt here: bootmgr polls the ide status register while a read
// is outstanding, so a read that takes an event loop turn costs millions of guest instructions,
// and a windows install media is large enough that the block cache becomes hundreds of thousands
// of small Uint8Arrays for the gc to walk. Reading the file synchronously has neither problem and
// costs no memory, which matters on a host with 8 GiB and a 1 GiB guest in it.
//
// This is only reasonable because it is node and the medium is read-only.
function iso_buffer(path)
{
    const fd = fs.openSync(path, "r");
    const byteLength = fs.fstatSync(fd).size;
    return {
        byteLength,
        onload: undefined,
        onprogress: undefined,
        load() { this.onload && this.onload({}); },
        get(start, len, fn) {
            const block = Buffer.alloc(len);
            fs.readSync(fd, block, 0, len, start);
            fn(new Uint8Array(block.buffer, block.byteOffset, len));
        },
        set(start, slice, fn) { throw new Error("the install medium is read-only"); },
        get_buffer(fn) { fn(); },
        get_state() { return []; },
        set_state(state) {},
    };
}

const emulator = new V86({
    wasm_path: __dirname + "../../build/v86-debug.wasm",
    bios: { url: __dirname + "../../bios/seabios.bin" },
    vga_bios: { url: __dirname + "../../bios/vgabios.bin" },
    cdrom: iso_buffer(iso),
    memory_size: MEMORY,
    vga_memory_size: 32 * 1024 * 1024,
    autostart: true,
    disable_jit: +process.env.DISABLE_JIT || 0,
    log_level: +process.env.LOG_LEVEL || 0,
    screen_dummy: true,
});

process.on("unhandledRejection", exn => { throw exn; });

let reboots = 0;

emulator.add_listener("emulator-loaded", () => {
    note("loaded, booting " + iso);

    // A guest that resets looks from the outside like one that went back to the bootloader, and
    // the two want completely different investigations. Windows resets rather than reporting when
    // its early boot fails, so this is the signal that something went wrong, and when.
    const cpu = emulator.v86.cpu;
    const reboot = cpu.reboot_internal.bind(cpu);
    cpu.reboot_internal = function() {
        reboots++;
        note(`[${((Date.now() - start) / 1000).toFixed(1)}s] ** RESET #${reboots} ` +
             `(from eip=${state().eip}, 64=${state().is_64})`);
        return reboot();
    };
});

const start = Date.now();
// eip counted per address, so that a wedged run says which address it is wedged on.
const hot = new Map();
let last_line = "";
let shots = 0;

function hex64(lo, hi)
{
    const h = hi >>> 0, l = lo >>> 0;
    return (h ? h.toString(16) + l.toString(16).padStart(8, "0") : l.toString(16));
}

function state()
{
    const cpu = emulator.v86.cpu;
    const eip = hex64(cpu.instruction_pointer[0], cpu.instruction_pointer[1]);
    return {
        eip,
        cs: cpu.sreg[1],
        cpl: cpu.cpl[0],
        is_32: cpu.is_32[0],
        is_64: cpu.is_64 ? cpu.is_64[0] : 0,
        cr0: cpu.cr[0] >>> 0,
        cr3: cpu.cr[3] >>> 0,
        cr4: cpu.cr[4] >>> 0,
        efer: cpu.efer[0] >>> 0,
        in_hlt: cpu.in_hlt[0],
    };
}

function screenshot(tag)
{
    const vga = emulator.v86.cpu.devices.vga;
    if(vga)
    {
        // Which mode the card is in, since "the screenshot is blank" and "there is nothing to
        // screenshot" look the same from the outside and mean very different things.
        note(`  vga: graphical=${+!!vga.graphical_mode} svga=${+!!vga.svga_enabled} ` +
             `bpp=${vga.svga_bpp} ${vga.svga_width}x${vga.svga_height} ` +
             `virtual=${vga.virtual_width}x${vga.virtual_height}`);
    }
    // Nothing calls screen_fill_buffer under a dummy screen, and it is what rebuilds image_data
    // after wasm memory has grown - without it every screenshot finds a detached buffer.
    if(vga && vga.graphical_mode)
    {
        try { vga.screen_fill_buffer(); } catch(e) { note("  screen_fill_buffer: " + e.message); }
    }

    if(!vga || !vga.graphical_mode || !vga.image_data || !vga.image_data.data.byteLength)
    {
        // Text mode, which is where the whole bootloader phase lives. There is no framebuffer to
        // shoot, so dump the characters instead - that is what says which file bootmgr is on.
        // Straight out of the guest's text buffer at 0xB8000 rather than through the screen
        // adapter, which only sees characters that arrived as vga writes it recognised.
        const mem = emulator.v86.cpu.mem8;
        const rows = [];
        for(let y = 0; y < 25; y++)
        {
            let row = "";
            for(let x = 0; x < 80; x++)
            {
                const c = mem[0xB8000 + (y * 80 + x) * 2];
                row += c >= 0x20 && c < 0x7f ? String.fromCharCode(c) : " ";
            }
            rows.push(row.replace(/\s+$/, ""));
        }
        const text = rows.filter(r => r).join("\n");
        note("  text screen at " + tag + ":\n" + (text ? text.replace(/^/gm, "  | ") : "  | (blank)"));
        return;
    }
    const { width, height, data } = vga.image_data;
    // The buffer is already in the byte order a png wants; only the alpha channel needs forcing,
    // since the vga leaves it at whatever the guest wrote.
    const rgba = Buffer.from(Buffer.from(data.buffer, data.byteOffset, width * height * 4));
    for(let i = 3; i < rgba.length; i += 4) rgba[i] = 0xff;
    const path = OUT + "/screen-" + tag + ".png";
    fs.writeFileSync(path, png(width, height, rgba));
    note("  wrote " + path + " (" + width + "x" + height + ")");
}

// instruction_counter is a u32 that wraps, so accumulate the deltas rather than reading it once.
let last_counter = 0;
let instructions = 0;

const spaces = new Set();
let last_tick = -1;
let ticks_seen = 0;

const seen = new Set();
function milestone(name)
{
    if(seen.has(name)) return;
    seen.add(name);
    note(`[${((Date.now() - start) / 1000).toFixed(1)}s] ** ${name}`);
}

const sampler = setInterval(() => {
    const s = state();
    const elapsed = (Date.now() - start) / 1000;
    if(elapsed >= HOT_FROM) hot.set(s.eip, (hot.get(s.eip) || 0) + 1);

    const counter = emulator.v86.cpu.instruction_counter[0] >>> 0;
    instructions += (counter - last_counter) >>> 0;
    last_counter = counter;

    // Each new cr3 is a new address space, which is the clearest sign of real progress there is:
    // the bootloader builds one, winload builds another, and the kernel another after that.
    if(s.cr3 && !spaces.has(s.cr3))
    {
        spaces.add(s.cr3);
        milestone(`address space #${spaces.size} (cr3=${s.cr3.toString(16)})`);
    }

    if(s.cr0 & 1) milestone("protected mode");
    if(s.is_32) milestone("32-bit code segment");
    if(s.cr4 & 0x20) milestone("pae enabled (cr4.pae)");
    if(s.efer & 0x100) milestone("long mode enabled (efer.lme)");
    if(s.efer & 0x400) milestone("long mode active (efer.lma)");
    if(s.is_64) milestone("64-bit code segment (cs.l)");
    if(s.efer & 0x800) milestone("nx enabled (efer.nxe)");
    if(emulator.v86.cpu.devices.vga && emulator.v86.cpu.devices.vga.graphical_mode)
        milestone("graphical mode");

    // The bios tick count in the bda at 0040:006c, which the int 1a ah=00 service returns. A boot
    // manager counting down a timeout reads this and nothing else, so a stuck value is a hang.
    const mem = emulator.v86.cpu.mem8;
    const tick = mem[0x46c] | mem[0x46d] << 8 | mem[0x46e] << 16 | mem[0x46f] << 24;
    if(tick !== last_tick)
    {
        if(ticks_seen++ < 6 || ticks_seen % 200 === 0)
            note(`[${elapsed.toFixed(1)}s] bda tick = ${tick} (${ticks_seen} changes so far)`);
        last_tick = tick;
    }

    const line = `cs=${s.cs.toString(16)} cpl=${s.cpl} 32=${s.is_32} 64=${s.is_64} ` +
        `cr0=${s.cr0.toString(16)} cr3=${s.cr3.toString(16)} cr4=${s.cr4.toString(16)} ` +
        `efer=${s.efer.toString(16)} hlt=${s.in_hlt}`;
    if(line !== last_line)
    {
        note(`[${((Date.now() - start) / 1000).toFixed(1)}s] eip=${s.eip} ${line}`);
        last_line = line;
    }
}, SAMPLE_MS);

const shooter = setInterval(() => {
    const tag = String(++shots * (SHOT_MS / 1000)) + "s";
    const seconds = (Date.now() - start) / 1000;
    note(`[${seconds.toFixed(1)}s] eip=${state().eip} ` +
         `(${(instructions / seconds / 1e6).toFixed(1)} million instructions/s)`);
    screenshot(tag);
}, SHOT_MS);

for(const at of KEYS_AT)
{
    setTimeout(() => {
        note(`[${((Date.now() - start) / 1000).toFixed(1)}s] ** pressing enter`);
        emulator.keyboard_send_scancodes([0x1c, 0x9c]);
    }, at * 1000);
}

setTimeout(() => {
    clearInterval(sampler);
    clearInterval(shooter);
    screenshot("final");

    const ranked = [...hot].sort((a, b) => b[1] - a[1]).slice(0, 15);
    const total = [...hot.values()].reduce((a, b) => a + b, 0);
    note("\n== where the run spent its samples" + (HOT_FROM ? ` after ${HOT_FROM}s` : "") + " (" + total + " samples, " + hot.size + " distinct eips)");
    for(const [eip, n] of ranked)
    {
        note(`  ${(100 * n / total).toFixed(1).padStart(5)}%  ${n.toString().padStart(5)}  eip=${eip}`);
    }
    note("\n== resets: " + reboots);
    note("== bda tick count: " + last_tick + ", changed " + ticks_seen + " times");
    note("\n== milestones reached: " + (seen.size ? [...seen].join(", ") : "none"));
    note("\n== final state\n  " + JSON.stringify(state(), null, 2).replace(/\n/g, "\n  "));

    log_file.end();
    emulator.destroy();
    process.exit(0);
}, run_seconds * 1000);
