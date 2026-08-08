#[allow(non_camel_case_types)]
pub enum stat {
    COMPILE,
    COMPILE_SKIPPED_NO_NEW_ENTRY_POINTS,
    COMPILE_WRONG_ADDRESS_SPACE,
    COMPILE_CUT_OFF_AT_END_OF_PAGE,
    COMPILE_WITH_LOOP_SAFETY,
    COMPILE_PAGE,
    COMPILE_BASIC_BLOCK,
    COMPILE_DUPLICATED_BASIC_BLOCK,
    COMPILE_WASM_BLOCK,
    COMPILE_WASM_LOOP,
    COMPILE_DISPATCHER,
    COMPILE_ENTRY_POINT,
    COMPILE_WASM_TOTAL_BYTES,

    RUN_INTERPRETED,
    RUN_INTERPRETED_NEW_PAGE,
    RUN_INTERPRETED_PAGE_HAS_CODE,
    RUN_INTERPRETED_PAGE_HAS_ENTRY_AFTER_PAGE_WALK,
    RUN_INTERPRETED_NEAR_END_OF_PAGE,
    RUN_INTERPRETED_DIFFERENT_STATE,
    RUN_INTERPRETED_DIFFERENT_STATE_CPL3,
    RUN_INTERPRETED_DIFFERENT_STATE_FLAT,
    RUN_INTERPRETED_DIFFERENT_STATE_IS32,
    RUN_INTERPRETED_DIFFERENT_STATE_SS32,
    RUN_INTERPRETED_MISSED_COMPILED_ENTRY_RUN_INTERPRETED,
    RUN_INTERPRETED_STEPS,

    RUN_FROM_CACHE,
    RUN_FROM_CACHE_STEPS,

    DIRECT_EXIT,
    INDIRECT_JUMP,
    INDIRECT_JUMP_NO_ENTRY,
    NORMAL_PAGE_CHANGE,
    NORMAL_FALLTHRU,
    NORMAL_FALLTHRU_WITH_TARGET_BLOCK,
    NORMAL_BRANCH,
    NORMAL_BRANCH_WITH_TARGET_BLOCK,
    CONDITIONAL_JUMP,
    CONDITIONAL_JUMP_PAGE_CHANGE,
    CONDITIONAL_JUMP_EXIT,
    CONDITIONAL_JUMP_FALLTHRU,
    CONDITIONAL_JUMP_FALLTHRU_WITH_TARGET_BLOCK,
    CONDITIONAL_JUMP_BRANCH,
    CONDITIONAL_JUMP_BRANCH_WITH_TARGET_BLOCK,
    DISPATCHER_SMALL,
    DISPATCHER_LARGE,
    LOOP,

    LOOP_SAFETY,

    CONDITION_OPTIMISED,
    CONDITION_UNOPTIMISED,
    CONDITION_UNOPTIMISED_PF,
    CONDITION_UNOPTIMISED_UNHANDLED_L,
    CONDITION_UNOPTIMISED_UNHANDLED_LE,

    FAILED_PAGE_CHANGE,

    SAFE_READ_FAST,
    SAFE_READ_SLOW_PAGE_CROSSED,
    SAFE_READ_SLOW_NOT_VALID,
    SAFE_READ_SLOW_NOT_USER,
    SAFE_READ_SLOW_IN_MAPPED_RANGE,

    SAFE_WRITE_FAST,
    SAFE_WRITE_SLOW_PAGE_CROSSED,
    SAFE_WRITE_SLOW_NOT_VALID,
    SAFE_WRITE_SLOW_NOT_USER,
    SAFE_WRITE_SLOW_IN_MAPPED_RANGE,
    SAFE_WRITE_SLOW_READ_ONLY,
    SAFE_WRITE_SLOW_HAS_CODE,

    SAFE_READ_WRITE_FAST,
    SAFE_READ_WRITE_SLOW_PAGE_CROSSED,
    SAFE_READ_WRITE_SLOW_NOT_VALID,
    SAFE_READ_WRITE_SLOW_NOT_USER,
    SAFE_READ_WRITE_SLOW_IN_MAPPED_RANGE,
    SAFE_READ_WRITE_SLOW_READ_ONLY,
    SAFE_READ_WRITE_SLOW_HAS_CODE,

    PAGE_FAULT,
    TLB_MISS,

    MAIN_LOOP,
    MAIN_LOOP_IDLE,
    DO_MANY_CYCLES,
    CYCLE_INTERNAL,

    INVALIDATE_ALL_MODULES_NO_FREE_WASM_INDICES,
    INVALIDATE_MODULE_WRITTEN_WHILE_COMPILED,
    INVALIDATE_MODULE_UNUSED_AFTER_OVERWRITE,
    INVALIDATE_MODULE_DIRTY_PAGE,

    INVALIDATE_PAGE_HAD_CODE,
    INVALIDATE_PAGE_HAD_ENTRY_POINTS,
    DIRTY_PAGE_DID_NOT_HAVE_CODE,

    RUN_FROM_CACHE_EXIT_SAME_PAGE,
    RUN_FROM_CACHE_EXIT_NEAR_END_OF_PAGE,
    RUN_FROM_CACHE_EXIT_DIFFERENT_PAGE,

    CLEAR_TLB,
    FULL_CLEAR_TLB,
    TLB_FULL,
    TLB_GLOBAL_FULL,

    MODRM_SIMPLE_REG,
    MODRM_SIMPLE_REG_WITH_OFFSET,
    MODRM_SIMPLE_CONST_OFFSET,
    MODRM_COMPLEX,

    SEG_OFFSET_OPTIMISED,
    SEG_OFFSET_NOT_OPTIMISED,
    SEG_OFFSET_NOT_OPTIMISED_ES,
    SEG_OFFSET_NOT_OPTIMISED_FS,
    SEG_OFFSET_NOT_OPTIMISED_GS,
    SEG_OFFSET_NOT_OPTIMISED_NOT_FLAT,
}

#[allow(non_upper_case_globals)]
pub static mut stat_array: [u64; 500] = [0; 500];

pub fn stat_increment(stat: stat) { stat_increment_by(stat, 1); }

pub fn stat_increment_by(stat: stat, by: u64) {
    if cfg!(feature = "profiler") {
        unsafe { stat_array[stat as usize] += by }
    }
}

#[no_mangle]
pub fn profiler_init() {
    unsafe {
        #[allow(static_mut_refs)]
        for x in stat_array.iter_mut() {
            *x = 0
        }
        #[allow(static_mut_refs)]
        for x in timer_array.iter_mut() {
            *x = 0.0
        }
    }
    profiler_hot_pages_clear();
}

#[no_mangle]
pub fn profiler_stat_get(stat: stat) -> f64 {
    if cfg!(feature = "profiler") {
        unsafe { stat_array[stat as usize] as f64 }
    }
    else {
        0.0
    }
}

#[no_mangle]
pub fn profiler_is_enabled() -> bool { cfg!(feature = "profiler") }

// Timing and hot spot tracing. Everything here is compiled out unless the profiler feature is
// enabled, since it costs a call into javascript per measurement and a hash lookup per basic
// block.

#[allow(non_camel_case_types)]
#[derive(Copy, Clone)]
pub enum timer {
    MAIN_LOOP,
    IDLE,
    COMPILE,
    LAST,
}

#[allow(non_upper_case_globals)]
pub static mut timer_array: [f64; timer::LAST as usize] = [0.0; timer::LAST as usize];

/// Milliseconds since an arbitrary origin, or 0 when the profiler is disabled. Note that this
/// calls into javascript, so it must not be used per instruction.
pub fn time_now() -> f64 {
    if cfg!(feature = "profiler") {
        unsafe { crate::cpu::cpu::js::microtick() }
    }
    else {
        0.0
    }
}

pub fn time_add(t: timer, start: f64) {
    if cfg!(feature = "profiler") {
        unsafe { timer_array[t as usize] += time_now() - start }
    }
}

#[no_mangle]
pub fn profiler_timer_get(t: u32) -> f64 {
    if cfg!(feature = "profiler") && (t as usize) < timer::LAST as usize {
        unsafe { timer_array[t as usize] }
    }
    else {
        0.0
    }
}

/// How much of the guest's time is spent in one page of its code, and whether that time is spent
/// in compiled code or in the interpreter. Aggregating per page rather than per instruction keeps
/// this cheap enough to leave on, and matches the granularity the jit itself works at.
#[derive(Default, Clone)]
pub struct HotPage {
    pub entries: u64,
    pub compiled_steps: u64,
    pub interpreted_steps: u64,
}

#[allow(non_upper_case_globals)]
pub static mut hot_pages: Option<std::collections::HashMap<u32, HotPage>> = None;

/// Sorted snapshot of hot_pages, produced by profiler_hot_pages_sort and read out one field at a
/// time by javascript
#[allow(non_upper_case_globals)]
pub static mut hot_pages_sorted: Vec<(u32, HotPage)> = Vec::new();

/// `page` is the guest virtual page the block started in, with bit 0 holding cpl3 so that kernel
/// and user code at the same address stay distinguishable
pub fn record_block(page: u32, cpl3: bool, steps: u64, compiled: bool) {
    if !cfg!(feature = "profiler") {
        return;
    }
    unsafe {
        #[allow(static_mut_refs)]
        let map = hot_pages.get_or_insert_with(Default::default);
        let entry = map.entry(page << 1 | cpl3 as u32).or_default();
        entry.entries += 1;
        if compiled {
            entry.compiled_steps += steps;
        }
        else {
            entry.interpreted_steps += steps;
        }
    }
}

#[no_mangle]
pub fn profiler_hot_pages_sort() -> u32 {
    if !cfg!(feature = "profiler") {
        return 0;
    }
    unsafe {
        #[allow(static_mut_refs)]
        let map = hot_pages.get_or_insert_with(Default::default);
        #[allow(static_mut_refs)]
        {
            hot_pages_sorted = map.iter().map(|(k, v)| (*k, v.clone())).collect();
            hot_pages_sorted.sort_unstable_by_key(|(_, v)| {
                std::cmp::Reverse(v.compiled_steps + v.interpreted_steps)
            });
            hot_pages_sorted.len() as u32
        }
    }
}

/// field: 0 address, 1 cpl3, 2 entries, 3 compiled steps, 4 interpreted steps
#[no_mangle]
pub fn profiler_hot_pages_get(index: u32, field: u32) -> f64 {
    if !cfg!(feature = "profiler") {
        return 0.0;
    }
    unsafe {
        #[allow(static_mut_refs)]
        match hot_pages_sorted.get(index as usize) {
            None => 0.0,
            Some((key, v)) => match field {
                0 => ((key >> 1) << 12) as f64,
                1 => (key & 1) as f64,
                2 => v.entries as f64,
                3 => v.compiled_steps as f64,
                4 => v.interpreted_steps as f64,
                _ => 0.0,
            },
        }
    }
}

#[no_mangle]
pub fn profiler_hot_pages_clear() {
    unsafe {
        hot_pages = None;
        #[allow(static_mut_refs)]
        hot_pages_sorted.clear();
    }
}
