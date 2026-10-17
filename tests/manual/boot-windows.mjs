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
//   DETERMINISTIC=1  drive the guest's clock from its own instruction counter rather than the
//                    host's, which makes a boot a function of the image alone. Two things vary
//                    between runs otherwise: the wall clock, which windows folds into the seed it
//                    lays the kernel out with, so the base moves every boot; and the rate the host
//                    happens to run at, which decides where in the instruction stream each timer
//                    interrupt lands. An intermittent failure is much cheaper to study when it
//                    either happens every run or none. Keypresses and the run's length move to the
//                    same clock, so a busy host makes a run slower rather than meaningless.
//   VIRTUAL_KIPS=n   instructions per virtual millisecond under DETERMINISTIC (default 30000),
//                    which is what the emulated machine's speed amounts to
//   SEED=n           the seed the deterministic run answers rdrand from. Varying this, or
//                    VIRTUAL_KIPS, moves where each timer interrupt lands in the instruction
//                    stream - which is how to hunt a race that a single fixed schedule steps over
//   MIN_MIPS=n       give up if the emulator falls below this (default 8). A run on a host that is
//                    swapping does not merely go slowly: node's timers fire minutes late, so the
//                    keypresses land in the wrong phase and the whole run is noise that looks like
//                    a result. Better to stop and say so.
//   HOT_FROM=n       ignore the first n seconds in the hot-address report, so that a phase late in
//                    the boot is not drowned out by the phases that worked
//   FDA=path         attach a floppy image, which is how an answer file reaches windows setup
//   SERIAL_EXPECT=s  watch the guest's serial port for this string and report whether it came.
//                    A guest that says anything at all has booted, logged in and run a program
//   STOP_ON_SERIAL=1 stop as soon as it does, rather than running out the clock
//   HDA=path         attach a writable disk at that path, creating it sparse if it is not there,
//                    and keep booting the install medium first. Windows setup runs without one but
//                    has nowhere to install to
//   HDA_GB=n         how large to make it when creating (default 24, which is what windows 10 asks
//                    for; the file is sparse, so only what the guest writes costs anything)
//   SAVE_AT=n        write the whole machine to OUT/state.bin after n seconds
//   RESTORE=path     start from a state written that way instead of booting. The frontier of this
//                    work is several minutes into a boot, and re-reaching it for every experiment
//                    is most of the cost of an experiment
//   KEYS_AT=n,m,...  press a key at each of these times, in seconds. A guest polling int 16h is
//                    waiting for one; whether pressing it changes anything says which guest it is
//   SCRIPT=t:key,... press named keys at given times, which is how a dialog driven guest is told
//                    what to do: SCRIPT=2400:enter,2425:alt+a,2430:enter. Names are enter, tab,
//                    space, esc, the arrows, a few letters, and alt+x for a dialog's accelerators
//   KEYS_EVERY=n     press one every n seconds instead. Prefer this: a boot's phases move around
//                    by minutes depending on what else the host is doing, and a key pressed in the
//                    wrong phase is a wasted run rather than an obvious failure

import fs from "node:fs";
import zlib from "node:zlib";
import url from "node:url";

// Held before anything can replace it: a deterministic run redefines Date.now for the guest, and
// the harness still has to know how much real time has passed.
const real_now = Date.now.bind(Date);

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
const { V86, v86 } = await import(__dirname + "../../src/main.js");

const iso = process.argv[2];
const run_seconds = +process.argv[3] || 120;
if(!iso || !fs.existsSync(iso))
{
    console.error("usage: boot-windows.mjs <iso> [seconds]");
    process.exit(1);
}

const OUT = process.env.OUT || __dirname + "../../build/boot-windows";
const MEMORY = (+process.env.MEMORY || 1024) * 1024 * 1024;
// Instructions per virtual millisecond. Only the ratio matters: it decides how much guest work
// happens between timer ticks, so it is the emulated machine's speed.
const DETERMINISTIC = +process.env.DETERMINISTIC || 0;
const VIRTUAL_KIPS = +process.env.VIRTUAL_KIPS || 30000;
// How far the clock's rate is allowed to wander, 0 for a perfectly regular one. 1 means the
// interval between two timer interrupts varies by half either way, which is roughly what a loaded
// host does to it.
const JITTER = +process.env.JITTER || 0;

// A clock the guest cannot tell from a real one, that depends on nothing outside the emulator.
//
// Two things vary between runs of the same boot and make an intermittent failure expensive to
// study: the wall clock, which windows folds into the seed it lays the kernel out with - the base
// moves every boot - and the rate the host happens to run at, which decides where in the guest's
// instruction stream each timer interrupt lands. Both come from here. Driving them off the
// instruction counter instead makes the whole boot a function of the image alone, so a failure
// either happens every time or never, and the run that reproduces it can be repeated.
let instructions_total = 0;
let instructions_last = 0;
let clock_cpu = null;

// What a line in the log is timed against: the guest's clock when there is one, so that two runs
// of the same image produce the same timestamps and can be diffed against each other.
function stamp()
{
    return ((DETERMINISTIC ? virtual_ms() : real_now() - start) / 1000).toFixed(1);
}

// The clock's rate over one bucket of instructions. A pure function of which bucket, so that it
// does not matter how often the clock is read - which is the whole difficulty: the harness samples
// on the host's clock, so anything that advances per call to this function makes the guest depend
// on the host again, by the back door.
const JITTER_BUCKET = 65536;

function jitter_factor(bucket)
{
    let h = Math.imul(bucket ^ 0x9e3779b9, 2654435761) >>> 0;
    h ^= h >>> 15;
    h = Math.imul(h, 2246822519) >>> 0;
    h ^= h >>> 13;
    return 1 + JITTER * ((h >>> 24) / 255 - 0.5);
}

let jitter_bucket = 0;      // buckets whose time is already accounted for
let jitter_base_ms = 0;     // the clock at the start of that bucket

let halted_ms = 0;
let halted_since = 0;

function virtual_ms()
{
    if(!clock_cpu) return 0;
    // the counter is a u32 that wraps, so take the delta rather than the value
    const now = clock_cpu.instruction_counter[0] >>> 0;
    instructions_total += (now - instructions_last) >>> 0;
    instructions_last = now;

    // A halted guest retires no instructions, so a clock made only of instructions stops with it -
    // and then no timer can come due, and nothing ever wakes it. The machine deadlocks against its
    // own clock, which looks exactly like the guest hanging and is not the guest's doing at all.
    // Time has to keep moving across a halt; real time is what it moves by, since there is nothing
    // else running to measure.
    //
    // The cost of that, which is worth knowing before trusting a run: the idle stretches are part
    // of the clock, so a busy host does not merely slow a run down. It lengthens every halt in
    // clock terms, which moves where each timer interrupt lands in the instruction stream, which
    // is the one thing DETERMINISTIC exists to hold still. Two runs of the same build on a host
    // under load average 40 took visibly different paths through a windows boot. The summary at
    // the end reports how much of the clock came from halts for exactly this reason: when that
    // share is large the run is a different experiment from a quiet one, whatever it shows.
    if(clock_cpu.in_hlt && clock_cpu.in_hlt[0])
    {
        const t = real_now();
        if(halted_since) halted_ms += t - halted_since;
        halted_since = t;
    }
    else
    {
        halted_since = 0;
    }

    if(!JITTER) return instructions_total / VIRTUAL_KIPS + halted_ms;

    // A rate that wanders instead of a fixed one. On a real host the interval between two timer
    // interrupts, counted in guest instructions, is never the same twice - the host's own load
    // decides it. A perfectly regular clock lands every interrupt on a grid, and a race that needs
    // one to arrive at an awkward instruction never gets tried. Wandering the rate deterministically
    // puts the irregularity back without putting the host back with it.
    while(instructions_total >= (jitter_bucket + 1) * JITTER_BUCKET)
    {
        jitter_base_ms += JITTER_BUCKET / (VIRTUAL_KIPS * jitter_factor(jitter_bucket));
        jitter_bucket++;
    }
    const within = instructions_total - jitter_bucket * JITTER_BUCKET;
    return jitter_base_ms + within / (VIRTUAL_KIPS * jitter_factor(jitter_bucket)) + halted_ms;
}

if(DETERMINISTIC)
{
    // A fixed wall clock. The date itself is arbitrary; that it is the same every run is the point.
    const epoch = Date.UTC(2026, 0, 1, 12, 0, 0);
    v86.microtick = virtual_ms;
    Date.now = () => epoch + virtual_ms();

    // And the other way entropy gets in. cpuid advertises rdrand, so windows seeds itself from it,
    // and v86 answers out of crypto.getRandomValues - which is real randomness and so is the one
    // thing left that differs between two runs of the same image. A seeded generator answers the
    // same sequence every time, which is what makes the boot repeatable rather than merely similar.
    let seed = (+process.env.SEED || 0x2545f491) >>> 0;
    const next = () => {
        seed ^= seed << 13; seed >>>= 0;
        seed ^= seed >>> 17;
        seed ^= seed << 5;  seed >>>= 0;
        return seed | 0;
    };
    const fill = arr => {
        for(let i = 0; i < arr.length; i++) arr[i] = next();
        return arr;
    };
    try { globalThis.crypto.getRandomValues = fill; }
    catch(e) { Object.defineProperty(globalThis, "crypto", { value: { getRandomValues: fill } }); }
}
const SAMPLE_MS = +process.env.SAMPLE_MS || 250;
const SHOT_MS = +process.env.SHOT_MS || 5000;
const HOT_FROM = +process.env.HOT_FROM || 0;
// Under a virtual clock a starved host makes a run slower, not wrong: the guest sees the same
// instruction stream either way, so there is nothing to give up on.
const MIN_MIPS = process.env.MIN_MIPS !== undefined ? +process.env.MIN_MIPS
    : DETERMINISTIC ? 0 : 8;
// A disk to install onto. Without one windows setup runs but has nowhere to put anything.
const HDA = process.env.HDA || "";
// A floppy, which is how an answer file reaches windows setup: it looks for autounattend.xml on
// removable media before it draws anything.
const FDA = process.env.FDA || "";
// What the guest is expected to say on its serial port, and whether to stop as soon as it does.
// A guest that can say anything at all has booted, logged in and run a program, which is a great
// deal more than a screenshot can establish.
const SERIAL_EXPECT = process.env.SERIAL_EXPECT || "";
const STOP_ON_SERIAL = process.env.STOP_ON_SERIAL === "1";
const HDA_GB = +process.env.HDA_GB || 24;
const SAVE_AT = +process.env.SAVE_AT || 0;
const RESTORE = process.env.RESTORE || "";
const KEYS_AT = (process.env.KEYS_AT || "").split(",").filter(Boolean).map(Number);
const KEYS_EVERY = +process.env.KEYS_EVERY || 0;

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
// A class rather than an object literal, because v86's state serializer refuses anything whose
// constructor is Object - see save_object in src/state.js. A plain literal works right up until
// something tries to save the machine, which is exactly when it is least convenient to find out.
class IsoBuffer
{
    constructor(path)
    {
        this.fd = fs.openSync(path, "r");
        this.byteLength = fs.fstatSync(this.fd).size;
        this.onload = undefined;
        this.onprogress = undefined;
    }
    load() { this.onload && this.onload({}); }
    get(start, len, fn)
    {
        const block = Buffer.alloc(len);
        fs.readSync(this.fd, block, 0, len, start);
        fn(new Uint8Array(block.buffer, block.byteOffset, len));
    }
    set(start, slice, fn) { throw new Error("the install medium is read-only"); }
    get_buffer(fn) { fn(); }
    get_state() { return []; }
    set_state(state) {}
}


// A writable disk, file backed and sparse: the bytes cost nothing until the guest writes them, so
// a disk large enough for windows to agree to install on it does not cost that much of the host's.
// Unlike the install medium this has to take writes, and they have to survive the reboot in the
// middle of an installation, which is why it is a file rather than memory.
class DiskBuffer
{
    constructor(path, size)
    {
        if(!fs.existsSync(path))
        {
            const fd = fs.openSync(path, "w");
            fs.ftruncateSync(fd, size);
            fs.closeSync(fd);
            note(`created ${path}, ${(size / (1 << 30)).toFixed(0)} GiB and empty`);
        }
        this.fd = fs.openSync(path, "r+");
        this.byteLength = fs.fstatSync(this.fd).size;
        this.onload = undefined;
        this.onprogress = undefined;
    }
    load() { this.onload && this.onload({}); }
    get(start, len, fn)
    {
        const block = Buffer.alloc(len);
        fs.readSync(this.fd, block, 0, len, start);
        fn(new Uint8Array(block.buffer, block.byteOffset, len));
    }
    set(start, slice, fn)
    {
        fs.writeSync(this.fd, Buffer.from(slice.buffer, slice.byteOffset, slice.length),
                     0, slice.length, start);
        fn && fn();
    }
    // A file is already as cached as it needs to be, so the two cache shaped methods the ide
    // code expects are just reads. The synchronous one has to hand the block back rather than
    // call anything.
    get_and_cache(start, len, fn) { this.get(start, len, fn); }
    get_from_cache(start, len)
    {
        const block = Buffer.alloc(len);
        fs.readSync(this.fd, block, 0, len, start);
        return new Uint8Array(block.buffer, block.byteOffset, len);
    }
    get_buffer(fn) { fn(); }
    get_state() { return []; }
    set_state(state) {}
}

const emulator = new V86({
    wasm_path: __dirname + "../../build/v86-debug.wasm",
    bios: { url: __dirname + "../../bios/seabios.bin" },
    vga_bios: { url: __dirname + "../../bios/vgabios.bin" },
    cdrom: new IsoBuffer(iso),
    // Attaching a disk makes the starter prefer booting from it; say otherwise, or an empty disk
    // is chosen over the install medium and nothing happens at all.
    ...(HDA ? { hda: new DiskBuffer(HDA, HDA_GB * (1 << 30)), boot_order: 0x123 } : {}),
    ...(FDA ? { fda: { buffer: new Uint8Array(fs.readFileSync(FDA)).buffer } } : {}),
    memory_size: MEMORY,
    vga_memory_size: 32 * 1024 * 1024,
    // Windows x64 has no support for a machine without acpi, and drives its timer through the
    // apic. handle_irqs only consults the apic when this is on, so with it off the guest's timer
    // interrupt is never delivered and every timeout it counts against stalls forever.
    acpi: true,
    // A restore replaces the state a boot would have built, so there is nothing to start yet.
    autostart: !RESTORE,
    disable_jit: +process.env.DISABLE_JIT || 0,
    log_level: +process.env.LOG_LEVEL || 0,
    screen_dummy: true,
});

process.on("unhandledRejection", exn => { throw exn; });

let reboots = 0;

emulator.add_listener("emulator-loaded", async () => {
    if(RESTORE)
    {
        note("restoring " + RESTORE);
        await emulator.restore_state(new Uint8Array(fs.readFileSync(RESTORE)).buffer);
        await emulator.run();
        note("restored and running");
    }
    else
    {
        note("loaded, booting " + iso);
    }

    // A guest that resets looks from the outside like one that went back to the bootloader, and
    // the two want completely different investigations. Windows resets rather than reporting when
    // its early boot fails, so this is the signal that something went wrong, and when.
    const cpu = emulator.v86.cpu;
    clock_cpu = cpu;
    emulator.add_listener("serial0-output-byte", byte => {
    const ch = String.fromCharCode(byte);
    serial_text += ch;
    if(serial_text.length > 1 << 16) serial_text = serial_text.slice(-(1 << 15));
    if(ch === "\n")
    {
        const line = serial_text.slice(serial_text.lastIndexOf("\n", serial_text.length - 2) + 1).trim();
        if(line) note(`[${stamp()}s] serial: ${line}`);
    }
    if(SERIAL_EXPECT && serial_seen_at === null && serial_text.includes(SERIAL_EXPECT))
    {
        serial_seen_at = stamp();
        note(`[${serial_seen_at}s] ** the guest said '${SERIAL_EXPECT}' on its serial port`);
        screenshot("serial-marker");
        if(STOP_ON_SERIAL) setTimeout(finish, 2000);
    }
});

const reboot = cpu.reboot_internal.bind(cpu);
    cpu.reboot_internal = function() {
        reboots++;
        note(`[${stamp()}s] ** RESET #${reboots} ` +
             `(from eip=${state().eip}, 64=${state().is_64})`);
        // Whatever is on screen now is the reason: windows draws its bugcheck screen, which names
        // the stop code, and then restarts itself. One instruction later the framebuffer is gone,
        // so this is the only moment the screen can be read.
        try { cpu.wm.exports["xdump_trace"] && cpu.wm.exports["xdump_trace"](); }
        catch(e) { note("  could not dump the trace: " + e); }
        try { screenshot(`reset-${reboots}`); }
        catch(e) { note("  could not capture the screen at reset: " + e); }
        return reboot();
    };
});

const start = real_now();
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
        interrupts_enabled: (cpu.flags[0] & 0x200) !== 0,
        cr4: cpu.cr[4] >>> 0,
        efer: cpu.efer[0] >>> 0,
        in_hlt: cpu.in_hlt[0],
    };
}

function screenshot(tag)
{
    if(!emulator || !emulator.v86 || !emulator.v86.cpu) return;
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

// Everything the guest writes to its first serial port. Windows will not say a word here unless
// it has booted far enough to log a session in and run something in it, which is why the marker an
// answer file sends is worth more than any number of screenshots. Module scope, because the
// verdict at the end of the run reads them.
let serial_text = "";
let serial_seen_at = null;

const spaces = new Set();
const modes = new Map();
let last_sample_at = real_now();
let starved = 0;
let last_tick = -1;
let ticks_seen = 0;

const seen = new Set();
function milestone(name)
{
    if(seen.has(name)) return;
    seen.add(name);
    note(`[${stamp()}s] ** ${name}`);
}

let wedged_at = null;
let wedged_for = 0;
let idle_at = null;
let idle_for = 0;

const sampler = setInterval(() => {
    // Before the guard below, and before anything that could throw: a run that will not stop is
    // worse than one that stops early, and an hour was spent on one that outlived its own clock.
    if(DETERMINISTIC) virtual_schedule();
    // At a short sample interval the first tick can beat the emulator into existence.
    if(!emulator.v86 || !emulator.v86.cpu) return;

    // A machine halted with interrupts closed is not going to do anything else. Windows gets here
    // by bugchecking without being able to restart, and nothing after it is worth waiting for.
    {
        const st = state();
        if(st.in_hlt && !st.interrupts_enabled && st.eip === wedged_at)
        {
            if(++wedged_for * SAMPLE_MS >= 20000)
            {
                note(`[${stamp()}s] ** the guest is wedged: halted at ${st.eip} with interrupts closed`);
                finish();
                return;
            }
        }
        // Halted with interrupts *open* is a different thing: the machine is idle, waiting for an
        // interrupt that is not coming. Say so, and ask the apic why, rather than letting the run
        // look like slow progress.
        else if(st.in_hlt && st.interrupts_enabled && st.eip === idle_at)
        {
            if(++idle_for * SAMPLE_MS === 30000)
            {
                note(`[${stamp()}s] ** idle: halted at ${st.eip} with interrupts open, nothing waking it`);
                try { emulator.v86.cpu.wm.exports["xdump_apic"] && emulator.v86.cpu.wm.exports["xdump_apic"](); }
                catch(e) { note("  could not read the apic: " + e); }
            }
        }
        else
        {
            wedged_at = st.in_hlt && !st.interrupts_enabled ? st.eip : null;
            wedged_for = 0;
            idle_at = st.in_hlt && st.interrupts_enabled ? st.eip : null;
            idle_for = 0;
        }
    }
    const s = state();
    const elapsed = (real_now() - start) / 1000;
    if(elapsed >= HOT_FROM) hot.set(s.eip, (hot.get(s.eip) || 0) + 1);

    // How often the guest is in each mode with interrupts open. A guest that never runs long mode
    // with if set cannot be delivered a timer tick there, and every timeout it counts stalls.
    const bucket = (s.is_64 ? "64-bit   " : s.cr0 & 1 ? "protected" : "real     ") +
        (s.interrupts_enabled ? "  if=1" : "  if=0");
    modes.set(bucket, (modes.get(bucket) || 0) + 1);

    const counter = emulator.v86.cpu.instruction_counter[0] >>> 0;
    const delta = (counter - last_counter) >>> 0;
    instructions += delta;
    last_counter = counter;

    // Two symptoms of a host that is swapping, either of which invalidates the run: the emulator
    // crawling, and this very interval firing late - which is what moves the keypresses out of the
    // phase they were aimed at.
    const gap = real_now() - last_sample_at;
    last_sample_at = real_now();
    if(elapsed > 20 && MIN_MIPS)
    {
        const mips = delta / gap / 1000;
        starved = mips < MIN_MIPS || gap > SAMPLE_MS * 8 ? starved + 1 : 0;
        if(starved >= 20)
        {
            note(`\n== giving up at ${elapsed.toFixed(0)}s: ${mips.toFixed(1)} million ` +
                 `instructions/s and this sampler ${gap}ms late, against a ${SAMPLE_MS}ms interval.`);
            note("== the host is not able to run this; the result would be noise. Free memory and retry.");
            clearInterval(sampler);
            clearInterval(shooter);
            log_file.end();
            emulator.destroy();
            process.exit(2);
        }
    }

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
        ticks_seen++;
        if(process.env.TICKS) note(`[${elapsed.toFixed(1)}s] bda tick = ${tick}`);
        else if(ticks_seen < 6 || ticks_seen % 200 === 0)
            note(`[${elapsed.toFixed(1)}s] bda tick = ${tick} (${ticks_seen} changes so far)`);
        last_tick = tick;
    }

    const line = `cs=${s.cs.toString(16)} cpl=${s.cpl} 32=${s.is_32} 64=${s.is_64} ` +
        `cr0=${s.cr0.toString(16)} cr3=${s.cr3.toString(16)} cr4=${s.cr4.toString(16)} ` +
        `efer=${s.efer.toString(16)} hlt=${s.in_hlt}`;
    if(line !== last_line)
    {
        note(`[${stamp()}s] eip=${s.eip} ${line}`);
        last_line = line;
    }
}, SAMPLE_MS);

const shooter = setInterval(() => {
    const tag = String(++shots * (SHOT_MS / 1000)) + "s";
    // Whose handler int 1a and int 16 reach. A bootloader that hooks them maintains its own tick
    // from its own timer handler; if that handler never runs, the tick it returns never moves and
    // every timeout counted against it stalls.
    const mem = emulator.v86.cpu.mem8;
    const vector = n => {
        const off = mem[n * 4] | mem[n * 4 + 1] << 8;
        const seg = mem[n * 4 + 2] | mem[n * 4 + 3] << 8;
        return seg.toString(16).padStart(4, "0") + ":" + off.toString(16).padStart(4, "0");
    };
    note(`  ivt: int 1a -> ${vector(0x1a)}   int 16 -> ${vector(0x16)}   int 8 -> ${vector(8)}`);

    // Two clocks, and saying which is which matters: everything else in this log is stamped with
    // the guest's, and a line stamped with the host's reads as the guest having run four times
    // further than it has. The rate is instructions per *real* second, which is the one worth
    // knowing - it says whether this machine is giving the run a whole core or a quarter of one.
    const seconds = (real_now() - start) / 1000;
    note(`[${stamp()}s guest, ${seconds.toFixed(0)}s wall] eip=${state().eip} ` +
         `(${(instructions / seconds / 1e6).toFixed(1)} million instructions/s)`);
    screenshot(tag);
}, SHOT_MS);

if(SAVE_AT)
{
    setTimeout(async () => {
        const path = OUT + "/state.bin";
        note(`[${stamp()}s] ** saving the machine to ${path}`);
        await emulator.stop();
        const state = await emulator.save_state();
        fs.writeFileSync(path, Buffer.from(state));
        await emulator.run();
        note(`  wrote ${(state.byteLength / (1024 * 1024)).toFixed(0)} MB`);
    }, SAVE_AT * 1000);
}


// The keys a script can name. Windows setup is a series of dialogs with a default button, so most
// of driving it is enter and tab; the rest are here because a dialog that needs an arrow or a
// space is not worth a whole code change to reach.
const SCANCODES = {
    enter: 0x1c, tab: 0x0f, space: 0x39, esc: 0x01, backspace: 0x0e,
    up: 0xe048, down: 0xe050, left: 0xe04b, right: 0xe04d,
    home: 0xe047, end: 0xe04f, del: 0xe053,
    a: 0x1e, c: 0x2e, d: 0x20, i: 0x17, n: 0x31, u: 0x16, y: 0x15,
};

// alt is held across the key when a name is written alt+x, which is how a dialog's accelerators
// are reached - windows setup's licence page accepts with alt+a.
function scancodes_for(name)
{
    let alt = false;
    if(name.startsWith("alt+")) { alt = true; name = name.slice(4); }
    const code = SCANCODES[name];
    if(code === undefined) return null;
    const down = code > 0xFF ? [code >> 8, code & 0xFF] : [code];
    const up = code > 0xFF ? [code >> 8, (code & 0xFF) | 0x80] : [code | 0x80];
    return alt ? [0x38, ...down, ...up, 0xb8] : [...down, ...up];
}

function press_enter()
{
    note(`[${stamp()}s] ** pressing enter`);
    emulator.keyboard_send_scancodes([0x1c, 0x9c]);
}

function press_named(name)
{
    const codes = scancodes_for(name);
    if(!codes)
    {
        note(`[${stamp()}s] ** no scancode for '${name}', skipped`);
        return;
    }
    note(`[${stamp()}s] ** pressing ${name}`);
    emulator.keyboard_send_scancodes(codes);
}

// A deterministic run schedules everything on the guest's clock. That is the point of the exercise:
// on a busy host a real-time timer fires minutes late in guest terms, so a keypress meant for the
// boot menu arrives somewhere else entirely and the run says nothing. On the virtual clock it
// arrives at the same instruction every time.
const virtual_pending = KEYS_AT.slice().sort((a, b) => a - b);
let virtual_every_next = KEYS_EVERY;

// A script is a list of time:key pairs on the same clock, which is how a dialog driven guest is
// told what to do: `SCRIPT=2400:enter,2412:enter,2425:alt+a,2430:enter`. Times are seconds, and
// the whole point of putting them on the virtual clock is that the same script reaches the same
// dialog on a busy host as on a quiet one.
const script_pending = (process.env.SCRIPT || "")
    .split(",")
    .filter(Boolean)
    .map(entry => {
        const [at, key] = entry.split(":");
        return { at: +at, key: (key || "enter").trim() };
    })
    .sort((a, b) => a.at - b.at);

function virtual_schedule()
{
    const now = virtual_ms() / 1000;
    while(virtual_pending.length && virtual_pending[0] <= now) { virtual_pending.shift(); press_enter(); }
    while(script_pending.length && script_pending[0].at <= now) { press_named(script_pending.shift().key); }
    if(KEYS_EVERY && now >= virtual_every_next) { virtual_every_next += KEYS_EVERY; press_enter(); }
    if(now >= run_seconds) finish();
}

if(!DETERMINISTIC)
{
    for(const at of KEYS_AT) setTimeout(press_enter, at * 1000);
    for(const step of script_pending) setTimeout(() => press_named(step.key), step.at * 1000);
    if(KEYS_EVERY) setInterval(press_enter, KEYS_EVERY * 1000);
}

function finish() {
    clearInterval(sampler);
    clearInterval(shooter);
    screenshot("final");

    // A run that ends without the guest resetting never passes through the reboot hook, so ask the
    // emulator for whatever trace it is keeping here as well. A wedge produces no reset and is
    // exactly the case where the trace is wanted.
    try { clock_cpu && clock_cpu.wm.exports["xdump_trace"] && clock_cpu.wm.exports["xdump_trace"](); }
    catch(e) { note("  could not dump the trace: " + e); }

    const ranked = [...hot].sort((a, b) => b[1] - a[1]).slice(0, 15);
    const total = [...hot.values()].reduce((a, b) => a + b, 0);
    note("\n== where the run spent its samples" + (HOT_FROM ? ` after ${HOT_FROM}s` : "") + " (" + total + " samples, " + hot.size + " distinct eips)");
    for(const [eip, n] of ranked)
    {
        note(`  ${(100 * n / total).toFixed(1).padStart(5)}%  ${n.toString().padStart(5)}  eip=${eip}`);
    }
    // The verdict, when the run was asked to look for something. Everything above is description;
    // this is the one line that says whether what was asked for happened.
    if(SERIAL_EXPECT)
    {
        note("\n== verdict");
        if(serial_seen_at !== null)
        {
            note(`  PASS: the guest reached a logged in desktop and spoke at ${serial_seen_at}s`);
            note(`  resets along the way: ${reboots}` +
                 (reboots ? " (an installation reboots itself several times)" : ""));
        }
        else
        {
            note(`  FAIL: '${SERIAL_EXPECT}' never came out of the serial port`);
            note(`  resets: ${reboots}; last screen is ${OUT}/screen-final.png`);
            note("  Nothing was heard from the guest, so it did not finish installing, did not");
            note("  log in, or could not open the port. The screenshots say which.");
            process.exitCode = 1;
        }
    }

    const clock_ms = virtual_ms();
    if(clock_ms > 0)
    {
        const share = 100 * halted_ms / clock_ms;
        note(`\n== clock: ${(clock_ms / 1000).toFixed(0)}s, of which ${(halted_ms / 1000).toFixed(0)}s (${share.toFixed(0)}%) came from halts`);
        if(share > 50)
        {
            note("  More than half the clock is idle time measured against the host, so where the");
            note("  timer interrupts landed depended on how busy this machine was. Compare with a");
            note("  run made on a quiet host before concluding anything from where this one got to.");
        }
    }

    const mode_total = [...modes.values()].reduce((a, b) => a + b, 0);
    note("\n== where the samples were, and whether interrupts were open");
    for(const [name, n] of [...modes].sort((a, b) => b[1] - a[1]))
    {
        note(`  ${(100 * n / mode_total).toFixed(1).padStart(5)}%  ${name}`);
    }

    note("\n== resets: " + reboots);
    note("== bda tick count: " + last_tick + ", changed " + ticks_seen + " times");
    note("\n== milestones reached: " + (seen.size ? [...seen].join(", ") : "none"));
    note("\n== final state\n  " + JSON.stringify(state(), null, 2).replace(/\n/g, "\n  "));

    log_file.end();
    emulator.destroy();
    // Exit with whatever the verdict decided, not with success regardless. A test that always
    // reports success is not a test.
    process.exit(process.exitCode || 0);
}

// The wall clock still ends a run that is not deterministic, and backstops one that is: if the
// guest wedges and stops retiring instructions, its clock stops with it and would never get here.
// A backstop in real time, in case the virtual clock stops moving: a guest that never retires
// another instruction never reaches its own deadline. Under DETERMINISTIC the guest's clock can
// legitimately run far behind the host's, so the backstop is given room.
//
// Clamped, because setTimeout takes a 32-bit millisecond count and node silently turns anything
// larger into one millisecond - which fires `finish` before the emulator has been built, and ends
// a run that was meant to last hours in under a second.
const BACKSTOP_LIMIT = 2147483647;
setTimeout(finish, Math.min(run_seconds * 1000 * (DETERMINISTIC ? 8 : 1), BACKSTOP_LIMIT));
