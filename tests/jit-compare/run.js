#!/usr/bin/env node
// Run a flat binary twice, once interpreted and once compiled, and compare the resulting registers.
// Differential coverage for the code generator without needing an x86 host, which is what the nasm
// tests require.
//
// Two things make a comparison like this quietly vacuous, and both are checked rather than assumed:
//
// - jit_force_generate is asynchronous, since it hands the module to WebAssembly.instantiate. The
//   run has to wait for test_hook_did_finalize_wasm, or the block is still interpreted.
// - the counters that would report whether anything ran compiled only exist in a profiler build,
//   so this must be run against `make debug-with-profiler`. Without it the run reports nothing
//   compiled and exits rather than claiming a match it didn't test.
//
// Usage: make debug-with-profiler && ./tests/jit-compare/run.js tests/jit-compare/build/foo.bin

import fs from "node:fs";
import url from "node:url";
const __dirname = url.fileURLToPath(new URL(".", import.meta.url));
const { V86 } = await import(__dirname + "../../src/main.js");

const executable = new Uint8Array(fs.readFileSync(process.argv[2]));
const START = 0x1000;
const XMM0 = [0x807f01ff, 0xfffe0102, 0x7f7f7f7f, 0x00ff00ff];
const XMM1 = [0x01018002, 0x000201fe, 0x01010101, 0x01010101];

function run(use_jit) {
    return new Promise(resolve => {
        const emulator = new V86({
            wasm_path: __dirname + "../../build/v86-debug.wasm",
            bios: { url: __dirname + "../../bios/seabios.bin" },
            autostart: false, memory_size: 8 * 1024 * 1024,
            disable_jit: use_jit ? 0 : 1, log_level: +process.env.LOG_LEVEL || 0,
        });
        emulator.add_listener("emulator-loaded", function() {
            const cpu = emulator.v86.cpu;
            cpu.reset_cpu();
            cpu.is_32[0] = true;
            cpu.stack_size_32[0] = true;
            cpu.mem8.set(executable, START);
            const xmm = new Int32Array(cpu.wasm_memory.buffer, 832, 32);
            for(let r = 0; r < 8; r++)
                for(let i = 0; i < 4; i++)
                    xmm[r * 4 + i] = (XMM0[i] ^ (r * 0x11111111)) | 0;
            for(let i = 0; i < 4; i++) xmm[4 + i] = XMM1[i];
            cpu.instruction_pointer[0] = START;
            cpu.update_state_flags();

            const execute = () => {
                for(let i = 0; i < 200 && !cpu.in_hlt[0]; i++) cpu.main_loop();
                const out = [];
                for(let i = 0; i < 32; i++) out.push(xmm[i] >>> 0);
                // the general purpose registers, 16 of them, 64 bits each
                const gpr = new Int32Array(cpu.wasm_memory.buffer, 128, 32);
                for(let i = 0; i < 32; i++) out.push(gpr[i] >>> 0);
                // hot page tracing reports steps split by compiled vs interpreted, which is a
                // direct answer to "did the jit actually execute this"
                const n = cpu.wm.exports["profiler_hot_pages_sort"]();
                let compiled = 0, interp = 0;
                for(let i = 0; i < n; i++) {
                    compiled += cpu.wm.exports["profiler_hot_pages_get"](i, 3);
                    interp += cpu.wm.exports["profiler_hot_pages_get"](i, 4);
                }
                resolve({
                    regs: out,
                    cache: cpu.wm.exports["jit_get_cache_size"](),
                    compiled, interp,
                    is_64: Boolean(cpu.is_64[0]),
                });
            };

            if(use_jit) {
                cpu.test_hook_did_finalize_wasm = function() {
                    cpu.test_hook_did_finalize_wasm = null;
                    setTimeout(execute, 0);
                };
                cpu.jit_force_generate(START);
            }
            else execute();
        });
    });
}

const a = await run(false);
const b = await run(true);
console.log(`interpreter run: compiled=${a.compiled} interpreted=${a.interp}`);
console.log(`jit run        : compiled=${b.compiled} interpreted=${b.interp} cache=${b.cache}`);
if(b.is_64) console.log("reached 64-bit mode");
if(!b.compiled) { console.log("NOTHING RAN COMPILED - comparison is vacuous"); process.exit(2); }
let ok = true;
for(let i = 0; i < a.regs.length; i++)
    if(a.regs[i] !== b.regs[i]) {
        const name = i < 32 ? `xmm${i >> 2}[${i & 3}]` : `r${(i - 32) >> 1}.dword${(i - 32) & 1}`;
        console.log(`MISMATCH ${name}: interp=${a.regs[i].toString(16)} jit=${b.regs[i].toString(16)}`);
        ok = false;
    }
console.log(ok ? "MATCH" : "DIFFERENT");
process.exit(ok ? 0 : 1);
