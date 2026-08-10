#!/usr/bin/env node
// Check a flat binary's registers against expected values.
//
// run.js compares an interpreted run against a compiled one, which catches code generator bugs but
// says nothing about whether either run is right. For the long mode fixtures it says even less:
// the jit stays out of 64-bit mode, so both halves interpret the same code and agree trivially. A
// wrong result there is invisible.
//
// This runs the binary once, interpreted, and compares the general purpose registers against a
// .expected file sitting next to the .asm. Only the registers named there are checked, so a
// fixture can assert the few values it is actually about and ignore its own scratch.
//
// Usage: ./tests/jit-compare/regcheck.js tests/jit-compare/build/long-mode-movsxd.bin

import fs from "node:fs";
import path from "node:path";
import url from "node:url";
const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const { V86 } = await import(__dirname + "../../src/main.js");

const NAMES = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
               "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"];

const binary = process.argv[2];
if(!binary) {
    console.error("usage: regcheck.js <binary>");
    process.exit(2);
}

// The expectations live with the source, not with the build output
const expected_file = path.join(__dirname, path.basename(binary).replace(/\.bin$/, "") + ".expected");
if(!fs.existsSync(expected_file)) {
    console.log(`no ${path.basename(expected_file)}, nothing to check`);
    process.exit(0);
}

const expected = new Map();
for(const raw of fs.readFileSync(expected_file, "utf8").split("\n")) {
    const line = raw.replace(/[;#].*$/, "").trim();
    if(!line) continue;
    const m = /^(\w+)\s*=\s*(?:0x)?([0-9a-fA-F]+)$/.exec(line);
    if(!m) {
        console.error(`${path.basename(expected_file)}: cannot parse ${JSON.stringify(raw)}`);
        process.exit(2);
    }
    if(!NAMES.includes(m[1])) {
        console.error(`${path.basename(expected_file)}: ${m[1]} is not a register`);
        process.exit(2);
    }
    expected.set(m[1], m[2].toLowerCase().padStart(16, "0"));
}

const executable = new Uint8Array(fs.readFileSync(binary));
const START = 0x1000;

const emulator = new V86({
    wasm_path: __dirname + "../../build/v86-debug.wasm",
    bios: { url: __dirname + "../../bios/seabios.bin" },
    autostart: false,
    memory_size: 8 * 1024 * 1024,
    disable_jit: 1,
    log_level: +process.env.LOG_LEVEL || 0,
});

emulator.add_listener("emulator-loaded", function() {
    const cpu = emulator.v86.cpu;
    cpu.reset_cpu();
    cpu.is_32[0] = true;
    cpu.stack_size_32[0] = true;
    cpu.mem8.set(executable, START);
    cpu.instruction_pointer[0] = START;
    cpu.update_state_flags();

    for(let i = 0; i < 2000 && !cpu.in_hlt[0]; i++) cpu.main_loop();

    // A fixture that never halted did not reach its end, so its registers mean nothing
    if(!cpu.in_hlt[0]) {
        console.log("FAILED: did not reach hlt");
        process.exit(1);
    }

    const regs = new Int32Array(cpu.wasm_memory.buffer, 128, 32);
    const actual = name => {
        const i = NAMES.indexOf(name);
        const lo = regs[i * 2] >>> 0, hi = regs[i * 2 + 1] >>> 0;
        return hi.toString(16).padStart(8, "0") + lo.toString(16).padStart(8, "0");
    };

    let ok = true;
    for(const [name, want] of expected) {
        const got = actual(name);
        if(got !== want) {
            console.log(`MISMATCH ${name}: expected 0x${want}, got 0x${got}`);
            ok = false;
        }
    }

    console.log(ok ? `values ok (${expected.size} registers checked)` : "VALUES DIFFERENT");
    process.exit(ok ? 0 : 1);
});
