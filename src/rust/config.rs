pub const LOG_PAGE_FAULTS: bool = false;

pub const VMWARE_HYPERVISOR_PORT: bool = true;

/// ia-32e mode. Long mode entry, 4-level paging, the 64-bit register file and a hand written
/// 64-bit decoder exist, but only the subset of the instruction set that guests have asked for so
/// far, and the jit stays out of 64-bit code entirely. Anything missing traps by name rather than
/// running the wrong thing, so a guest that reaches an unimplemented instruction says so.
///
/// Off by default because enabling it sets the cpuid long mode bit, and a guest that sees it will
/// commit to a 64-bit kernel it cannot yet finish booting — a working 32-bit boot would turn into
/// a failing 64-bit one. Build with `--features long_mode` to work on it.
pub const ENABLE_LONG_MODE: bool = cfg!(feature = "long_mode");
