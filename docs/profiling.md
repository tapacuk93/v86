v86 has a built-in profiler, which instruments generated code to count certain
events and types of instructions. It can be used by building with `make
debug-with-profiler` and opening debug.html.

The profiler reports three kinds of data, all of which are compiled out of
normal builds.

## Event counts

Counters for things like jit compilations, tlb misses, page faults and how often
each instruction was executed. These say what happened, but not what it cost.

## Time

Wall clock milliseconds, which answer where the emulator itself spends its time:

    Time (ms):
    MAIN_LOOP=4027.4
    IDLE=2.8 (0.1% of MAIN_LOOP)
    COMPILE=449.6 (11.2% of MAIN_LOOP)

`COMPILE` is time spent generating code rather than running it. A large share
here means the jit is churning: either the guest keeps invalidating compiled
pages, or code is being compiled that doesn't run often enough to pay for
itself. Compare it against `INVALIDATE_MODULE_*` and `COMPILE_*` counts to tell
those cases apart.

## Hot guest pages

Which guest code the time actually goes into, and whether that code is running
compiled or interpreted:

    Hottest guest pages (470 total, showing 30):
    ADDRESS     CPL STEPS       SHARE   JIT%   ENTRIES
    0x00314000  0   62137586    43.3%   96%    244
    0xc019d000  0   627877      0.4%    3%     15445

`STEPS` is instructions executed in that page, `JIT%` the fraction that ran
compiled, and `ENTRIES` how many times execution entered the page. Pages high in
the list with a low `JIT%` are the ones worth looking at first: they are hot code
the jit isn't covering. A high `ENTRIES` relative to `STEPS` means execution
keeps leaving and re-entering the page, so the blocks being compiled are short.

Addresses are guest virtual, and the `CPL` column separates ring 0 from ring 3
code at the same address. Aggregating per 4 KiB page rather than per instruction
is what keeps this cheap enough to leave enabled.

For debugging networking, packet logging is available in the UI in both debug
and release builds. The resulting `traffic.hex` file can be loaded in Wireshark
using file -> import from hex -> tick direction indication, timestamp %s.%f.
