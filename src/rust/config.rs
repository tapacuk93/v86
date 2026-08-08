pub const LOG_PAGE_FAULTS: bool = false;

pub const VMWARE_HYPERVISOR_PORT: bool = true;

/// Groundwork for ia-32e mode. Long mode entry and 4-level paging exist, but the decoder, register
/// file and jit are still 32-bit only, so no 64-bit code can actually execute yet. Keep this off
/// until they follow, otherwise guests will see the cpuid long mode bit and try to boot a 64-bit
/// kernel.
pub const ENABLE_LONG_MODE: bool = false;
