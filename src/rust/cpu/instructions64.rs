//! Instructions as they behave in 64-bit mode.
//!
//! These are hand written rather than generated, because only a small subset exists so far and the
//! generator's 16/32 operand size split doesn't extend to a third variant without reworking the
//! whole table. Anything not implemented traps by name, so the guest itself says what to add next.
//!
//! Addresses are still i32 throughout v86, and its tlb is a flat array indexed by page number, so
//! only the low 4 GiB of the virtual address space can be represented. Early 64-bit boot code runs
//! identity mapped down there, which is enough to make progress; an address above 4 GiB traps
//! rather than silently wrapping. Lifting that needs the tlb to become associative, which is a
//! separate and much larger change.

#![allow(non_snake_case)]

use crate::cpu::arith;
use crate::cpu::cpu::*;
use crate::cpu::global_pointers::*;
use crate::cpu::memory;
use crate::cpu::misc_instr::{getaf, getcf, getof, getpf, getsf, getzf};
use crate::paging::OrPageFault;

/// Narrow an address that v86 still keeps in 32 bits.
///
/// Data addressing is no longer limited this way - the tlb and the memory funnels take a full
/// width virtual address. What is left are the instruction pointer and the segment base registers,
/// which are i32 arrays shared with the jit and with the 16- and 32-bit instruction tables, so a
/// value above 4 GiB has nowhere to go. Reaching those needs the jit's view of the instruction
/// pointer widened as well, which is a change of its own.
fn truncate_address(addr: i64) -> OrPageFault<i32> {
    if addr as u64 >> 32 != 0 {
        dbg_log!("Unsupported: code or segment base {:x} above 4 GiB", addr);
        dbg_assert!(false, "Unsupported: code or segment base above 4 GiB");
        return Err(());
    }
    Ok(addr as i32)
}


/// Narrow a value to the operand size, sign extended so the flag computation finds the sign bit
/// where that size puts it. `osize` is 16, 32 or 64.
fn sized(value: i64, osize: i32) -> i64 {
    match osize {
        8 => value as i8 as i64,
        16 => value as i16 as i64,
        32 => value as i32 as i64,
        _ => value,
    }
}

/// The immediate of an instruction whose operand size can vary: two bytes at 16, otherwise four,
/// which rex.w sign extends rather than widening
unsafe fn read_imm_osize(osize: i32) -> OrPageFault<i64> {
    if osize == 16 {
        Ok(read_imm16()? as i16 as i64)
    }
    else {
        Ok(read_imm32s()? as i64)
    }
}

unsafe fn rex_bit(bit: u8) -> i32 {
    if 0 != *rex & bit {
        8
    }
    else {
        0
    }
}

/// The register in the reg field of a modrm byte, extended by rex.r
unsafe fn modrm_reg(modrm_byte: i32) -> i32 { (modrm_byte >> 3 & 7) | rex_bit(REX_R) }

/// The register in the rm field of a modrm byte, extended by rex.b
unsafe fn modrm_rm(modrm_byte: i32) -> i32 { (modrm_byte & 7) | rex_bit(REX_B) }

/// Resolve the memory operand of a modrm byte using 64-bit addressing: the base and index are full
/// registers, rm=101 with mod=00 is rip relative rather than an absolute disp32, and there is no
/// 16-bit form.
unsafe fn resolve_modrm64(modrm_byte: i32) -> OrPageFault<i64> {
    resolve_modrm64_imm(modrm_byte, 0)
}

/// As resolve_modrm64, for an instruction that carries `imm_bytes` of immediate after the modrm.
/// Only rip relative addressing cares: it counts from the end of the whole instruction, and the
/// immediate has not been read yet at the point the modrm is resolved.
unsafe fn resolve_modrm64_imm(modrm_byte: i32, imm_bytes: i32) -> OrPageFault<i64> {
    resolve_modrm64_address_imm(modrm_byte, imm_bytes)
}

/// The effective address a modrm byte describes, without checking whether v86 can reach it.
///
/// lea wants this: it computes an address and puts it in a register without touching memory, so
/// neither the 4 GiB limit nor a fault applies to it. Everything that does access memory goes
/// through resolve_modrm64, which checks.
unsafe fn resolve_modrm64_address(modrm_byte: i32) -> OrPageFault<i64> {
    resolve_modrm64_address_imm(modrm_byte, 0)
}

unsafe fn resolve_modrm64_address_imm(modrm_byte: i32, imm_bytes: i32) -> OrPageFault<i64> {
    dbg_assert!(modrm_byte < 0xC0);

    let m = modrm_byte >> 6 & 3;
    let rm = modrm_byte & 7;

    let mut addr: i64 = if rm == 4 {
        // sib byte
        let sib = read_imm8()?;
        let scale = sib >> 6 & 3;
        let index = (sib >> 3 & 7) | rex_bit(REX_X);
        let base_reg = (sib & 7) | rex_bit(REX_B);

        // index == 4 without rex.x means no index register
        let index_value = if index == 4 { 0 } else { read_reg64(index) << scale };

        let base_value = if (sib & 7) == 5 && m == 0 {
            // no base, disp32 follows
            0
        }
        else {
            read_reg64(base_reg)
        };

        if (sib & 7) == 5 && m == 0 {
            index_value + read_imm32s()? as i64
        }
        else {
            base_value + index_value
        }
    }
    else if rm == 5 && m == 0 {
        // rip relative: the displacement counts from the address of the *next* instruction, which
        // is past any immediate this one carries. The immediate has not been read yet here, so its
        // length is passed in and added; getting this wrong puts every rip relative access that
        // has an immediate imm_bytes too low.
        let disp = read_imm32s()? as i64;
        *instruction_pointer as i64 + imm_bytes as i64 + disp
    }
    else {
        read_reg64(modrm_rm(modrm_byte))
    };

    if m == 1 {
        addr += read_imm8s()? as i64;
    }
    else if m == 2 {
        addr += read_imm32s()? as i64;
    }

    Ok(addr)
}

/// Push in 64-bit mode, where the stack is always 64 bits wide and the stack segment has no base
unsafe fn push64(value: i64) -> OrPageFault<()> {
    let new_rsp = read_reg64(ESP) - 8;
    safe_write64_64(new_rsp, value as u64)?;
    write_reg64(ESP, new_rsp);
    Ok(())
}

unsafe fn pop64() -> OrPageFault<i64> {
    let rsp = read_reg64(ESP);
    let value = safe_read64s_64(rsp)? as i64;
    write_reg64(ESP, rsp + 8);
    Ok(value)
}

/// Read the r/m operand at the current operand size
unsafe fn read_rm(modrm_byte: i32, osize: i32) -> OrPageFault<i64> {
    read_rm_imm(modrm_byte, osize, 0)
}

unsafe fn read_rm_imm(modrm_byte: i32, osize: i32, imm_bytes: i32) -> OrPageFault<i64> {
    if modrm_byte >= 0xC0 {
        let v = read_reg64(modrm_rm(modrm_byte));
        Ok(match osize {
            16 => v as u16 as i64,
            32 => v as u32 as i64,
            _ => v,
        })
    }
    else {
        let addr = resolve_modrm64_imm(modrm_byte, imm_bytes)?;
        Ok(match osize {
            16 => safe_read16_64(addr)? as i64,
            32 => safe_read32s_64(addr)? as u32 as i64,
            _ => safe_read64s_64(addr)? as i64,
        })
    }
}

/// Write a general purpose register at an operand size. A 32-bit write zero extends into the full
/// register, which is what makes `sub eax, eax` a valid way to clear rax; a 16-bit one leaves
/// everything above bit 15 as it was.
unsafe fn write_reg_sized(reg: i32, value: i64, osize: i32) {
    match osize {
        16 => write_reg64(reg, read_reg64(reg) & !0xFFFF | value & 0xFFFF),
        32 => write_reg64(reg, value as u32 as i64),
        _ => write_reg64(reg, value),
    }
}

unsafe fn write_rm(modrm_byte: i32, value: i64, osize: i32) -> OrPageFault<()> {
    write_rm_imm(modrm_byte, value, osize, 0)
}

unsafe fn write_rm_imm(modrm_byte: i32, value: i64, osize: i32, imm_bytes: i32) -> OrPageFault<()> {
    if modrm_byte >= 0xC0 {
        write_reg_sized(modrm_rm(modrm_byte), value, osize);
        Ok(())
    }
    else {
        let addr = resolve_modrm64_imm(modrm_byte, imm_bytes)?;
        match osize {
            16 => safe_write16_64(addr, value as i32 & 0xFFFF),
            32 => safe_write32_64(addr, value as i32),
            _ => safe_write64_64(addr, value as u64),
        }
    }
}

/// Set the arithmetic flags from a 64-bit result.
///
/// v86 normally defers flag computation, keeping the operands in last_op1/last_result, which are
/// 32 bits wide and read by generated code. Rather than widen that and every site that touches it,
/// 64-bit operations compute their flags up front and clear flags_changed, so the getters read the
/// flags register directly. This costs 64-bit arithmetic the lazy path but leaves the 32-bit hot
/// path and the jit completely untouched.
unsafe fn set_flags64(op1: i64, op2: i64, result: i64, is_sub: bool) {
    // Sign extension preserves unsigned order between the two halves of the range, so comparing
    // the extended values gives the same carry as comparing at the original width
    let cf = if is_sub { (op1 as u64) < (op2 as u64) } else { (result as u64) < (op1 as u64) };
    let af = 0 != (op1 ^ op2 ^ result) & 0x10;
    let zf = result == 0;
    let sf = result < 0;
    let of =
        if is_sub { (op1 ^ op2) & (op1 ^ result) < 0 } else { (op1 ^ result) & (op2 ^ result) < 0 };
    // parity is computed over the low byte only, as on 32-bit
    let pf = (result as u8).count_ones() % 2 == 0;

    *flags = *flags & !FLAGS_ALL
        | if cf { FLAG_CARRY } else { 0 }
        | if pf { FLAG_PARITY } else { 0 }
        | if af { FLAG_ADJUST } else { 0 }
        | if zf { FLAG_ZERO } else { 0 }
        | if sf { FLAG_SIGN } else { 0 }
        | if of { FLAG_OVERFLOW } else { 0 };
    *flags_changed = 0;
}

/// Set the flags of a logical operation, which always clear carry and overflow
unsafe fn set_flags64_logical(result: i64) {
    let pf = (result as u8).count_ones() % 2 == 0;
    *flags = *flags & !FLAGS_ALL
        | if pf { FLAG_PARITY } else { 0 }
        | if result == 0 { FLAG_ZERO } else { 0 }
        | if result < 0 { FLAG_SIGN } else { 0 };
    *flags_changed = 0;
}

/// One of the eight operations of the 0x80/0x81/0x83 group, and of the eight `op r/m, r` /
/// `op r, r/m` pairs. Returns the result to write back, or None for cmp and test which discard it.
unsafe fn group1_op(op: i32, dst: i64, src: i64, osize: i32) -> Option<i64> {
    // At the full width the flags stay lazy, the same as every other operand size, so that
    // generated code can defer them too. Narrower operations still go through the 32-bit path,
    // where the operands must be brought back to their own width first: otherwise the sign bit is
    // looked for at bit 63, and a result of 0x1_0000_0000 would not count as zero.
    if osize == 64 {
        return match op {
            0 => {
                let r = arith::add64(dst, src);
                check_lazy_flags64(dst, src, r, false);
                Some(r)
            },
            1 => Some(arith::logical64(dst | src)),
            4 => Some(arith::logical64(dst & src)),
            5 => {
                let r = arith::sub64(dst, src);
                check_lazy_flags64(dst, src, r, true);
                Some(r)
            },
            6 => Some(arith::logical64(dst ^ src)),
            7 => {
                let r = arith::sub64(dst, src);
                check_lazy_flags64(dst, src, r, true);
                None
            },
            2 => Some(adc_sbb(dst, src, osize, false)),
            3 => Some(adc_sbb(dst, src, osize, true)),
            _ => None,
        };
    }
    match op {
        0 => {
            let r = sized(dst.wrapping_add(src), osize);
            set_flags64(dst, src, r, false);
            Some(r)
        },
        1 => {
            let r = sized(dst | src, osize);
            set_flags64_logical(r);
            Some(r)
        },
        4 => {
            let r = sized(dst & src, osize);
            set_flags64_logical(r);
            Some(r)
        },
        5 => {
            let r = sized(dst.wrapping_sub(src), osize);
            set_flags64(dst, src, r, true);
            Some(r)
        },
        6 => {
            let r = sized(dst ^ src, osize);
            set_flags64_logical(r);
            Some(r)
        },
        7 => {
            // cmp: subtract and discard
            let r = sized(dst.wrapping_sub(src), osize);
            set_flags64(dst, src, r, true);
            None
        },
        2 => Some(adc_sbb(dst, src, osize, false)),
        3 => Some(adc_sbb(dst, src, osize, true)),
        _ => None,
    }
}

/// The condition encoded in the low nibble of a jcc, setcc or cmovcc opcode
unsafe fn test_condition(condition: i32) -> bool {
    use crate::cpu::misc_instr::*;
    let result = match condition >> 1 {
        0 => test_o(),
        1 => test_b(),
        2 => test_z(),
        3 => test_be(),
        4 => test_s(),
        5 => test_p(),
        6 => test_l(),
        _ => test_le(),
    };
    // odd encodings are the negation
    result != (0 != condition & 1)
}

/// Narrow a result to its operand width, sign extended, so the flags are read at the right bit
fn narrow(value: i64, byte_op: bool, osize: i32) -> i64 {
    if byte_op {
        value as i8 as i64
    }
    else {
        sized(value, osize)
    }
}

unsafe fn read_rm8(modrm_byte: i32) -> OrPageFault<i32> {
    read_rm8_imm(modrm_byte, 0)
}

unsafe fn read_rm8_imm(modrm_byte: i32, imm_bytes: i32) -> OrPageFault<i32> {
    if modrm_byte >= 0xC0 {
        Ok(read_reg8(modrm_rm(modrm_byte)))
    }
    else {
        safe_read8_64(resolve_modrm64_imm(modrm_byte, imm_bytes)?)
    }
}

unsafe fn write_rm8(modrm_byte: i32, value: i32) -> OrPageFault<()> {
    if modrm_byte >= 0xC0 {
        write_reg8(modrm_rm(modrm_byte), value);
        Ok(())
    }
    else {
        safe_write8_64(resolve_modrm64(modrm_byte)?, value)
    }
}

/// Cross check the lazy flags against a direct computation.
///
/// The lazy path stores the operands and works each flag out when it is read, which is the form
/// generated code needs. This is the obvious version, and in debug builds every 64-bit add and
/// sub is checked against it. Only the interpreter runs 64-bit code today, so there is no
/// interpreter-versus-jit comparison to catch a mistake here yet.
#[inline(always)]
unsafe fn check_lazy_flags64(op1: i64, op2: i64, result: i64, is_sub: bool) {
    if !cfg!(debug_assertions) {
        return;
    }
    let cf = if is_sub { (op1 as u64) < (op2 as u64) } else { (result as u64) < (op1 as u64) };
    let af = 0 != (op1 ^ op2 ^ result) & 0x10;
    let of =
        if is_sub { (op1 ^ op2) & (op1 ^ result) < 0 } else { (op1 ^ result) & (op2 ^ result) < 0 };
    let pf = (result as u8).count_ones() % 2 == 0;
    dbg_assert!(getcf() == cf, "64-bit cf");
    dbg_assert!(getaf() == af, "64-bit af");
    dbg_assert!(getof() == of, "64-bit of");
    dbg_assert!(getpf() == pf, "64-bit pf");
    dbg_assert!(getzf() == (result == 0), "64-bit zf");
    dbg_assert!(getsf() == (result < 0), "64-bit sf");
}

/// Load cs from a descriptor while in long mode.
///
/// A 64-bit code segment is flat and unlimited, so there is no base or limit to load, and the
/// checks the 32-bit path makes about them do not apply. Returns false if a fault was raised.
unsafe fn switch_seg_64_code(selector: i32) -> bool {
    let sel = SegmentSelector::of_u16(selector as u16);
    let (descriptor, _) = match lookup_segment_selector(sel) {
        Ok(Ok(d)) => d,
        Ok(Err(_)) | Err(()) => {
            dbg_log!("#gp far return with invalid cs {:x}", selector);
            trigger_gp(selector & !3);
            return false;
        },
    };

    if !descriptor.is_present() {
        dbg_log!("#np far return to not present cs {:x}", selector);
        trigger_np(selector & !3);
        return false;
    }
    if !descriptor.is_executable() {
        dbg_log!("#gp far return to non-executable cs {:x}", selector);
        trigger_gp(selector & !3);
        return false;
    }

    let is_long = descriptor.is_long();
    *segment_is_null.offset(CS as isize) = false;
    *segment_limits.offset(CS as isize) =
        if is_long { 0xFFFFFFFF } else { descriptor.effective_limit() };
    *segment_offsets.offset(CS as isize) = if is_long { 0 } else { descriptor.base() };
    *segment_access_bytes.offset(CS as isize) = descriptor.access_byte();
    *sreg.offset(CS as isize) = selector as u16 & !3 | *cpl as u16;

    update_cs_size(descriptor.is_32() && !is_long);
    set_cs_is_64(is_long);
    update_state_flags();
    true
}

/// shl, shr and sar at any operand size.
///
/// Carry and overflow are worked out here and stored, the way the 32-bit shifts do it, while sign,
/// zero and parity are left to be derived from the result. A count of zero changes no flags at all.
/// The rotates share these opcodes but are not implemented, and are refused rather than guessed at.
/// The rotates of the shift group, ops 0 to 3, with `count` already masked and known non-zero.
///
/// These only affect cf and of - sf, zf and pf keep whatever the last flag producing instruction
/// left behind - so they clear just those two bits of `flags_changed` and never publish a
/// `last_result`, which is what separates them from the shifts.
///
/// rol and ror take the count modulo the operand width. rcl and rcr rotate through cf, so their
/// cycle is one bit longer than the operand; they are done in u128 to keep the odd width, where a
/// count equal to the operand width would otherwise shift a u64 by its full width. of is
/// architecturally defined only for a count of one, and is computed here the way the existing
/// 8/16/32-bit rotates do it.
unsafe fn rotate_op(op: i32, value: i64, count: i32, osize: i32) -> Option<i64> {
    let width = osize as u32;
    let unsigned = match osize {
        8 => value as u8 as u64,
        16 => value as u16 as u64,
        32 => value as u32 as u64,
        _ => value as u64,
    };
    let mask = if width == 64 { !0u64 } else { (1u64 << width) - 1 };

    let (result, cf) = match op {
        // rol and ror, a cycle exactly as wide as the operand. A count that is a whole number of
        // turns leaves the value alone but still reports a bit in cf.
        0 | 1 => {
            let n = count as u32 % width;
            if n == 0 {
                let cf = if op == 0 { unsigned & 1 } else { unsigned >> (width - 1) & 1 };
                (unsigned, cf)
            }
            else if op == 0 {
                let r = (unsigned << n | unsigned >> (width - n)) & mask;
                (r, r & 1)
            }
            else {
                let r = (unsigned >> n | unsigned << (width - n)) & mask;
                (r, r >> (width - 1) & 1)
            }
        },
        // rcl and rcr, where cf sits above the operand as one extra bit of the cycle
        _ => {
            let cycle = width + 1;
            let n = count as u32 % cycle;
            if n == 0 {
                return Some(value);
            }
            let v = unsigned as u128 | (getcf() as u128) << width;
            let vmask = (1u128 << cycle) - 1;
            let r = if op == 2 {
                (v << n | v >> (cycle - n)) & vmask
            }
            else {
                (v >> n | v << (cycle - n)) & vmask
            };
            ((r as u64) & mask, (r >> width) as u64 & 1)
        },
    };

    // rotating left puts the bit that left the top into cf, so overflow compares the two; rotating
    // right puts it into the top, so overflow compares the top two bits of the result
    let of = if op == 0 || op == 2 {
        (result >> (width - 1) & 1) ^ cf
    }
    else {
        (result >> (width - 1) & 1) ^ (result >> (width - 2) & 1)
    };

    *flags_changed &= !FLAG_CARRY & !FLAG_OVERFLOW;
    *flags = *flags & !FLAG_CARRY & !FLAG_OVERFLOW
        | (cf as i32) & FLAG_CARRY
        | ((of as i32) << 11) & FLAG_OVERFLOW;

    Some(sized(result as i64, osize))
}

/// The widening multiplies and the divides of the shift group's neighbour, ops 4 to 7 of 0xf6/0xf7,
/// with `src` the sign extended r/m operand and `w` the operand width in bits.
///
/// All four work on an operand twice the width of the one encoded. At byte width that pair is just
/// ax; at every other width it is dx:ax. Doing the arithmetic in 128 bits covers the widest case
/// without splitting it, since a 64-bit multiply produces 128 bits and a 64-bit divide consumes
/// them.
///
/// The multiplies report in cf and of whether the upper half carries anything the lower half does
/// not already say, and leave sf, zf and pf derived from the lower half. The divides define no
/// flags at all, and raise #de rather than truncating when the quotient does not fit.
unsafe fn mul_div_op(op: i32, src: i64, w: i32) {
    let bits = w as u32;
    let low_mask: u64 = if w == 64 { !0 } else { (1u64 << bits) - 1 };
    let unsigned = |v: i64| (v as u64) & low_mask;

    // ax and dx at this width, zero extended and sign extended respectively
    let ax_u = unsigned(read_reg64(EAX));
    let dx_u = unsigned(read_reg64(EDX));
    let ax_s = sized(read_reg64(EAX), w);
    let dx_s = sized(read_reg64(EDX), w);

    // the byte forms keep both halves in ax, so writing back is one 16-bit write rather than two
    let write_pair = |low: u64, high: u64| {
        if w == 8 {
            write_reg_sized(EAX, (low & 0xFF | (high & 0xFF) << 8) as i64, 16);
        }
        else {
            write_reg_sized(EAX, low as i64, w);
            write_reg_sized(EDX, high as i64, w);
        }
    };

    match op {
        // mul and imul
        4 | 5 => {
            let (low, high) = if op == 4 {
                let r = ax_u as u128 * unsigned(src) as u128;
                (r as u64 & low_mask, (r >> bits) as u64 & low_mask)
            }
            else {
                let r = ax_s as i128 * src as i128;
                (r as u64 & low_mask, (r >> bits) as u64 & low_mask)
            };
            write_pair(low, high);

            // mul overflows when the upper half holds anything; imul when it holds anything other
            // than the sign the lower half already implies
            let overflow = if op == 4 {
                high != 0
            }
            else {
                sized(high as i64, w) != sized(low as i64, w) >> (bits - 1)
            };

            let low_s = sized(low as i64, w);
            if w == 64 {
                *last_result_64 = low_s;
            }
            else {
                *last_result = low_s as i32;
            }
            *last_op_size = match w {
                64 => OPSIZE_64,
                32 => OPSIZE_32,
                16 => OPSIZE_16,
                _ => OPSIZE_8,
            };
            *flags_changed = FLAGS_ALL & !FLAG_CARRY & !FLAG_OVERFLOW;
            *flags = *flags & !FLAG_CARRY & !FLAG_OVERFLOW
                | if overflow { FLAG_CARRY | FLAG_OVERFLOW } else { 0 };
        },
        // div
        6 => {
            let divisor = unsigned(src) as u128;
            if divisor == 0 {
                trigger_de();
                return;
            }
            let dividend = if w == 8 {
                read_reg64(EAX) as u64 as u128 & 0xFFFF
            }
            else {
                (dx_u as u128) << bits | ax_u as u128
            };
            let quotient = dividend / divisor;
            if quotient > low_mask as u128 {
                trigger_de();
                return;
            }
            write_pair(quotient as u64, (dividend % divisor) as u64);
        },
        // idiv
        _ => {
            let divisor = src as i128;
            if divisor == 0 {
                trigger_de();
                return;
            }
            let dividend = if w == 8 {
                read_reg64(EAX) as i16 as i128
            }
            else {
                (dx_s as i128) << bits | ax_u as i128
            };
            // the quotient can be one step outside i128 when dividing the most negative value by
            // -1, so the division itself has to be checked before its result is range checked
            let quotient = match dividend.checked_div(divisor) {
                Some(q) => q,
                None => {
                    trigger_de();
                    return;
                },
            };
            let limit = 1i128 << (bits - 1);
            if quotient < -limit || quotient >= limit {
                trigger_de();
                return;
            }
            write_pair(quotient as u64, (dividend % divisor) as u64);
        },
    }
}

/// The string instructions - movs, cmps, stos, lods and scas - in 64-bit mode.
///
/// Much simpler than their 16- and 32-bit forms, which is why they are here rather than delegated:
/// the address size is 64 rather than 16 or 32, and every segment base is zero, so rsi and rdi are
/// the addresses. Direction still comes from df, and the rep prefixes still count rcx down.
///
/// Both addresses are at full width, which matters because windows clears kernel structures with
/// `rep stos` through addresses well above 4 GiB.
///
/// A fault partway through leaves rsi, rdi and rcx where the faulting iteration found them, which
/// is what makes these restartable - so they are written back each time round rather than at the
/// end.
unsafe fn string_op(opcode: i32, osize: i32) -> bool {
    let width = if opcode & 1 == 0 { 8 } else { osize };
    let bytes = (width / 8) as i64;
    let step = if 0 != *flags & FLAG_DIRECTION { -bytes } else { bytes };

    let repz = 0 != *prefixes & crate::prefix::PREFIX_F3;
    let repnz = 0 != *prefixes & crate::prefix::PREFIX_F2;
    let rep = repz || repnz;
    // only cmps and scas consult zf to decide whether to keep going; for the rest any rep is
    // simply a count
    let compares = matches!(opcode, 0xA6 | 0xA7 | 0xAE | 0xAF);

    unsafe fn read_at(addr: i64, width: i32) -> OrPageFault<i64> {
        Ok(match width {
            8 => safe_read8_64(addr)? as i64,
            16 => safe_read16_64(addr)? as i64,
            32 => safe_read32s_64(addr)? as u32 as i64,
            _ => safe_read64s_64(addr)? as i64,
        })
    }
    unsafe fn write_at(addr: i64, value: i64, width: i32) -> OrPageFault<()> {
        match width {
            8 => safe_write8_64(addr, value as i32 & 0xFF),
            16 => safe_write16_64(addr, value as i32 & 0xFFFF),
            32 => safe_write32_64(addr, value as i32),
            _ => safe_write64_64(addr, value as u64),
        }
    }

    loop {
        if rep && read_reg64(ECX) == 0 {
            break;
        }

        let rsi = read_reg64(ESI);
        let rdi = read_reg64(EDI);

        let result = (|| -> OrPageFault<()> {
            match opcode {
                // movs
                0xA4 | 0xA5 => {
                    let v = read_at(rsi, width)?;
                    write_at(rdi, v, width)?;
                    write_reg64(ESI, rsi + step);
                    write_reg64(EDI, rdi + step);
                },
                // cmps, which subtracts the destination from the source
                0xA6 | 0xA7 => {
                    let a = sized(read_at(rsi, width)?, width);
                    let b = sized(read_at(rdi, width)?, width);
                    set_flags64(a, b, sized(a.wrapping_sub(b), width), true);
                    write_reg64(ESI, rsi + step);
                    write_reg64(EDI, rdi + step);
                },
                // stos
                0xAA | 0xAB => {
                    write_at(rdi, read_reg64(EAX), width)?;
                    write_reg64(EDI, rdi + step);
                },
                // lods
                0xAC | 0xAD => {
                    let v = read_at(rsi, width)?;
                    write_reg_sized(EAX, v, width);
                    write_reg64(ESI, rsi + step);
                },
                // scas, which subtracts the destination from the accumulator
                _ => {
                    let a = sized(read_reg64(EAX), width);
                    let b = sized(read_at(rdi, width)?, width);
                    set_flags64(a, b, sized(a.wrapping_sub(b), width), true);
                    write_reg64(EDI, rdi + step);
                },
            }
            Ok(())
        })();

        if result.is_err() {
            return true;
        }

        if !rep {
            break;
        }
        write_reg64(ECX, read_reg64(ECX) - 1);
        if compares && getzf() != repz {
            break;
        }
    }
    true
}

unsafe fn shift_op(op: i32, value: i64, raw_count: i32, osize: i32) -> Option<i64> {
    let count = raw_count & if osize == 64 { 63 } else { 31 };
    if count == 0 {
        return Some(value);
    }

    let (result, cf, of) = match op {
        // shl
        4 | 6 => {
            let result = sized(value.wrapping_shl(count as u32), osize);
            let cf = value.wrapping_shr((osize - count) as u32) & 1;
            let sign = (result >> (osize - 1)) & 1;
            (result, cf, cf ^ sign)
        },
        // shr, which is logical and so needs the value zero extended to its own width first
        5 => {
            let unsigned = match osize {
                8 => value as u8 as u64,
                16 => value as u16 as u64,
                32 => value as u32 as u64,
                _ => value as u64,
            };
            let result = sized((unsigned >> count) as i64, osize);
            let cf = ((unsigned >> (count - 1)) & 1) as i64;
            // overflow is the sign of the original operand
            let of = (value >> (osize - 1)) & 1;
            (result, cf, of)
        },
        // sar, arithmetic, so the operand keeps its sign
        7 => {
            let signed = sized(value, osize);
            let result = sized(signed >> count, osize);
            let cf = (signed >> (count - 1)) & 1;
            (result, cf, 0)
        },
        // the rotates leave sf, zf and pf alone, so they cannot share the tail below
        0..=3 => return rotate_op(op, value, count, osize),
        _ => {
            dbg_log!("Unimplemented: 64-bit shift group op {}", op);
            return None;
        },
    };

    if osize == 64 {
        *last_result_64 = result;
    }
    else {
        *last_result = result as i32;
    }
    *last_op_size = match osize {
        64 => OPSIZE_64,
        32 => OPSIZE_32,
        16 => OPSIZE_16,
        _ => OPSIZE_8,
    };
    *flags_changed = FLAGS_ALL & !FLAG_CARRY & !FLAG_OVERFLOW;
    *flags = *flags & !FLAG_CARRY & !FLAG_OVERFLOW
        | (cf as i32) & FLAG_CARRY
        | ((of as i32) << 11) & FLAG_OVERFLOW;

    Some(result)
}

/// An sse instruction whose behaviour is identical in 64-bit mode, delegated to its existing
/// implementation. rex.r and rex.b extend the register fields to xmm8-15.
unsafe fn sse_delegate(
    modrm_byte: i32,
    reg_fn: unsafe fn(i32, i32),
    mem_fn: unsafe fn(i32, i32),
) -> bool {
    let r = modrm_reg(modrm_byte);
    if modrm_byte >= 0xC0 {
        reg_fn(modrm_rm(modrm_byte), r);
    }
    else {
        match resolve_modrm64(modrm_byte) {
            Ok(addr) => match truncate_address(addr) {
                Ok(addr) => mem_fn(addr, r),
                Err(()) => {},
            },
            Err(()) => {},
        }
    }
    true
}

/// adc and sbb at any operand size. They need the incoming carry, so carry, adjust and overflow
/// are worked out here, as the 32-bit versions do, and sign, zero and parity are left lazy.
unsafe fn adc_sbb(dst: i64, src: i64, osize: i32, is_sub: bool) -> i64 {
    let cf = getcf() as i64;
    let result = if is_sub {
        sized(dst.wrapping_sub(src).wrapping_sub(cf), osize)
    }
    else {
        sized(dst.wrapping_add(src).wrapping_add(cf), osize)
    };

    // With the carry folded in, comparing the operands no longer answers the question, so carry
    // and overflow come from the sign algebra. The two are not symmetric: see adc and sbb in
    // arith.rs, whose formulas these mirror.
    let sign = osize - 1;
    let (carry, overflow) = if is_sub {
        (
            ((result ^ ((result ^ src) & (src ^ dst))) >> sign) & 1,
            (((src ^ dst) & (result ^ dst)) >> sign) & 1,
        )
    }
    else {
        (
            ((dst ^ ((dst ^ src) & (src ^ result))) >> sign) & 1,
            (((src ^ result) & (dst ^ result)) >> sign) & 1,
        )
    };
    let adjust = (dst ^ src ^ result) & FLAG_ADJUST as i64;

    if osize == 64 {
        *last_op1_64 = dst;
        *last_result_64 = result;
        *last_op_size = OPSIZE_64;
    }
    else {
        *last_op1 = dst as i32;
        *last_result = result as i32;
        *last_op_size = match osize {
            8 => OPSIZE_8,
            16 => OPSIZE_16,
            _ => OPSIZE_32,
        };
    }
    *flags_changed =
        FLAGS_ALL & !FLAG_CARRY & !FLAG_ADJUST & !FLAG_OVERFLOW | if is_sub { FLAG_SUB } else { 0 };
    *flags = *flags & !FLAG_CARRY & !FLAG_ADJUST & !FLAG_OVERFLOW
        | (carry as i32) & FLAG_CARRY
        | (adjust as i32) & FLAG_ADJUST
        | ((overflow as i32) << 11) & FLAG_OVERFLOW;
    result
}

/// Read the r/m operand and keep the address it resolved to.
///
/// The displacement is consumed while resolving, so an instruction that writes the operand back
/// must reuse this address rather than resolve the modrm a second time. Doing that reads further
/// bytes as a displacement and leaves the decoder pointing into the middle of the next
/// instruction. `None` means the operand was a register.
unsafe fn read_rm_keep_addr(modrm_byte: i32, osize: i32) -> OrPageFault<(i64, Option<i64>)> {
    read_rm_keep_addr_imm(modrm_byte, osize, 0)
}

unsafe fn read_rm_keep_addr_imm(
    modrm_byte: i32,
    osize: i32,
    imm_bytes: i32,
) -> OrPageFault<(i64, Option<i64>)> {
    if modrm_byte >= 0xC0 {
        // read_rm has no byte case and would hand back the whole register, so the byte operand is
        // read here. The memory path below does handle 8, so only this side was missing it.
        let value = if osize == 8 {
            read_reg8(modrm_rm(modrm_byte)) as i64
        }
        else {
            read_rm_imm(modrm_byte, osize, imm_bytes)?
        };
        Ok((value, None))
    }
    else {
        let addr = resolve_modrm64_imm(modrm_byte, imm_bytes)?;
        let value = match osize {
            8 => safe_read8_64(addr)? as i64,
            16 => safe_read16_64(addr)? as i64,
            32 => safe_read32s_64(addr)? as u32 as i64,
            _ => safe_read64s_64(addr)? as i64,
        };
        Ok((value, Some(addr)))
    }
}

/// Write back to the operand `read_rm_keep_addr` returned
unsafe fn write_rm_keep_addr(
    modrm_byte: i32,
    addr: Option<i64>,
    value: i64,
    osize: i32,
) -> OrPageFault<()> {
    match addr {
        None => {
            if osize == 8 {
                write_reg8(modrm_rm(modrm_byte), value as i32);
            }
            else {
                write_reg_sized(modrm_rm(modrm_byte), value, osize);
            }
            Ok(())
        },
        Some(a) => match osize {
            8 => safe_write8_64(a, value as i32 & 0xFF),
            16 => safe_write16_64(a, value as i32 & 0xFFFF),
            32 => safe_write32_64(a, value as i32),
            _ => safe_write64_64(a, value as u64),
        },
    }
}

/// bt, bts, btr and btc.
///
/// Carry takes the bit as it was; the other arithmetic flags are undefined, so they are left. The
/// bit index is taken modulo the operand size here, which is what the immediate form does. The
/// register-index form addressing memory can reach outside the operand, and is handled separately.
unsafe fn bit_test_op(op: i32, value: i64, bit: i32, osize: i32) -> Option<i64> {
    let index = bit & (osize - 1);
    let mask = 1i64 << index;
    let old = 0 != value & mask;

    *flags_changed &= !FLAG_CARRY;
    *flags = *flags & !FLAG_CARRY | if old { FLAG_CARRY } else { 0 };

    match op {
        4 => None,                // bt, which only reads
        5 => Some(value | mask),  // bts
        6 => Some(value & !mask), // btr
        7 => Some(value ^ mask),  // btc
        _ => None,
    }
}

/// lldt in long mode. The descriptor is sixteen bytes, so the base can be anywhere; v86 keeps a
/// 32-bit one, so a base above 4 GiB is refused rather than truncated into something wrong.
unsafe fn load_ldt_64(selector: i32) -> bool {
    let sel = SegmentSelector::of_u16(selector as u16);
    if sel.is_null() {
        *segment_limits.offset(LDTR as isize) = 0;
        *segment_offsets.offset(LDTR as isize) = 0;
        *sreg.offset(LDTR as isize) = selector as u16;
        return true;
    }
    let (descriptor, base, _) = match lookup_system_descriptor_64(sel) {
        Ok(Ok(v)) => v,
        _ => {
            dbg_log!("#gp lldt with invalid selector {:x}", selector);
            trigger_gp(selector & !3);
            return true;
        },
    };
    // 2 is the ldt type, the only one lldt accepts
    if !descriptor.is_system() || descriptor.system_type() != 2 {
        dbg_log!("#gp lldt with type {:x}", descriptor.system_type());
        trigger_gp(selector & !3);
        return true;
    }
    if !descriptor.is_present() {
        trigger_np(selector & !3);
        return true;
    }
    let base = match truncate_address(base) {
        Ok(b) => b,
        Err(()) => return true,
    };
    *segment_limits.offset(LDTR as isize) = descriptor.effective_limit();
    *segment_offsets.offset(LDTR as isize) = base;
    *sreg.offset(LDTR as isize) = selector as u16;
    true
}

/// ltr in long mode. Type 9 is the only tss form here, the 16-bit ones not existing.
unsafe fn load_tr_64(selector: i32) -> bool {
    let sel = SegmentSelector::of_u16(selector as u16);
    let (descriptor, base, address) = match lookup_system_descriptor_64(sel) {
        Ok(Ok(v)) => v,
        _ => {
            dbg_log!("#gp ltr with invalid selector {:x}", selector);
            trigger_gp(selector & !3);
            return true;
        },
    };
    if !descriptor.is_system() || descriptor.system_type() != 9 {
        dbg_log!("#gp ltr with type {:x}", descriptor.system_type());
        trigger_gp(selector & !3);
        return true;
    }
    if !descriptor.is_present() {
        trigger_np(selector & !3);
        return true;
    }
    let base = match truncate_address(base) {
        Ok(b) => b,
        Err(()) => return true,
    };
    *tss_size_32 = true;
    *segment_limits.offset(TR as isize) = descriptor.effective_limit();
    *segment_offsets.offset(TR as isize) = base;
    *sreg.offset(TR as isize) = selector as u16;

    // mark the task busy, as the 32-bit path does
    match translate_address_system_write(address + 5) {
        Ok(a) => memory::write8(a, descriptor.set_busy().access_byte() as i32),
        Err(()) => {},
    }
    true
}

/// Dispatch one instruction in 64-bit mode. `rex` has already been consumed. Returns false if the
/// opcode isn't implemented yet, in which case the caller reports it.
pub unsafe fn run(opcode: i32) -> bool {
    // rex.w selects 64, a 0x66 prefix selects 16, and rex.w wins over it. Getting this wrong is
    // not merely a wrong value: the immediate's length depends on it, so a wrong width desynchronises
    // the decoder and everything after it is garbage.
    let osize = if 0 != *rex & REX_W {
        64
    }
    else if 0 != *prefixes & crate::prefix::PREFIX_66 {
        16
    }
    else {
        32
    };

    match opcode {
        // `op r/m, r` for add/or/and/sub/xor/cmp. The operation is bits 5:3 of the opcode.
        0x01 | 0x09 | 0x21 | 0x29 | 0x31 | 0x39 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let src = sized(read_reg64(modrm_reg(modrm_byte)), osize);
            let (raw, addr) = match read_rm_keep_addr(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(raw, osize);
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, src, osize) {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
            }
            true
        },

        // `op r, r/m` for the same set
        0x03 | 0x0B | 0x23 | 0x2B | 0x33 | 0x3B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let src = match read_rm(modrm_byte, osize) {
                Ok(v) => sized(v, osize),
                Err(()) => return true,
            };
            let dst = sized(read_reg64(reg), osize);
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, src, osize) {
                write_reg_sized(reg, result, osize);
            }
            true
        },

        // byte forms of `op r/m8, r8` and `op r8, r/m8`
        0x00 | 0x08 | 0x10 | 0x18 | 0x20 | 0x28 | 0x30 | 0x38 | 0x02 | 0x0A | 0x12 | 0x1A
        | 0x22 | 0x2A | 0x32 | 0x3A => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            // The address is kept from the read rather than resolved a second time for the write.
            // Resolving twice re-reads the sib byte and displacement from the instruction stream,
            // which consumes them twice and leaves decoding to carry on mid-instruction.
            let (rm, addr) = match read_rm_keep_addr(modrm_byte, 8) {
                Ok((v, a)) => (v as i8 as i64, a),
                Err(()) => return true,
            };
            let r = read_reg8(reg) as i8 as i64;
            // bit 1 of the opcode picks the direction
            let to_reg = 0 != opcode & 2;
            let (dst, src) = if to_reg { (r, rm) } else { (rm, r) };
            match group1_op(opcode >> 3 & 7, dst, src, 8) {
                Some(result) => {
                    if to_reg {
                        write_reg8(reg, result as i32);
                    }
                    else {
                        let _ = write_rm_keep_addr(modrm_byte, addr, result, 8);
                    }
                },
                None => {},
            }
            true
        },

        // group1 with a byte operand and a byte immediate
        0x80 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            // one byte of immediate follows, which rip relative addressing has to count past. The
            // address is kept from the read for the same reason as the group above: resolving it
            // again would consume the sib byte and displacement a second time.
            let (dst, addr) = match read_rm_keep_addr_imm(modrm_byte, 8, 1) {
                Ok((v, a)) => (v as i8 as i64, a),
                Err(()) => return true,
            };
            let imm = match read_imm8s() {
                Ok(v) => v as i64,
                Err(()) => return true,
            };
            match group1_op(modrm_byte >> 3 & 7, dst, imm, 8) {
                Some(result) => {
                    let _ = write_rm_keep_addr(modrm_byte, addr, result, 8);
                },
                None => {},
            }
            true
        },

        // `op AL, imm8`, the byte accumulator forms
        0x04 | 0x0C | 0x14 | 0x1C | 0x24 | 0x2C | 0x34 | 0x3C => {
            let imm = match read_imm8s() {
                Ok(v) => v as i64,
                Err(()) => return true,
            };
            let dst = read_reg8(0) as i8 as i64;
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, imm, 8) {
                write_reg8(0, result as i32);
            }
            true
        },

        // xchg r/m, r. A read modify write, so the modrm is resolved once and the address kept:
        // resolving it a second time to write back would consume the displacement twice and
        // desynchronise everything after it.
        //
        // A memory operand is locked implicitly, which matters on hardware and not here, where
        // nothing can observe the halfway state.
        0x86 | 0x87 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let size = if opcode == 0x86 { 8 } else { osize };
            let reg = modrm_reg(modrm_byte);
            let (dst, addr) = match read_rm_keep_addr(modrm_byte, size) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let src = if size == 8 { read_reg8(reg) as i64 } else { sized(read_reg64(reg), size) };
            if write_rm_keep_addr(modrm_byte, addr, src, size).is_err() {
                return true;
            }
            if size == 8 {
                write_reg8(reg, dst as i32);
            }
            else {
                write_reg_sized(reg, dst, size);
            }
            true
        },

        // pushfq and popfq, which bracket anything that has to leave the interrupt flag as it found
        // it, so system code reaches for them constantly. The image is eight bytes because the
        // stack is always that wide here; the upper half of rflags is reserved and reads as zero.
        //
        // The 32-bit paths guard against a vm86 monitor trap first. That cannot happen in long
        // mode, where the vm flag cannot be set, so the check is not repeated.
        //
        // Like push and pop, these default to the full width in long mode and rex.w says nothing:
        // only a 0x66 prefix narrows them, so the check is against 16 rather than for 64. The
        // 16-bit form moves the stack pointer by two rather than eight, which needs its own narrow
        // push and pop, and nothing has asked for it.
        0x9C => {
            if osize == 16 {
                dbg_log!("Unimplemented: pushfw");
                return false;
            }
            // vm and rf are cleared in the image that reaches the stack
            let _ = push64((get_eflags() & 0xFCFFFF) as i64);
            true
        },
        0x9D => {
            if osize == 16 {
                dbg_log!("Unimplemented: popfw");
                return false;
            }
            let old_flags = *flags;
            match pop64() {
                // only the low half is defined; update_eflags applies the writable subset of it,
                // including the privilege rules for iopl and the interrupt flag
                Ok(v) => update_eflags(v as i32),
                Err(()) => return true,
            }
            // enabling interrupts here has to let anything already pending through
            if old_flags & FLAG_INTERRUPT == 0 && *flags & FLAG_INTERRUPT != 0 {
                handle_irqs();
            }
            true
        },

        // imul r, r/m, imm: the three operand form, which is how a signed index gets scaled by a
        // structure size, so it sits next to movsxd in array addressing. 0x69 takes the immediate
        // at the operand size, 0x6B a sign extended byte.
        //
        // The flags are the same story as the two operand form at 0f af: carry and overflow say
        // the product did not fit in the destination, and the rest are undefined and left alone.
        0x69 | 0x6B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            // 0x6b takes a byte of immediate, 0x69 one at the operand size
            let imm_bytes = if opcode == 0x6B {
                1
            }
            else if osize == 16 {
                2
            }
            else {
                4
            };
            let src = match read_rm_imm(modrm_byte, osize, imm_bytes) {
                Ok(v) => sized(v, osize),
                Err(()) => return true,
            };
            // the immediate follows the modrm and any displacement, so it is read after read_rm
            let imm = if opcode == 0x6B {
                match read_imm8s() {
                    Ok(v) => v as i64,
                    Err(()) => return true,
                }
            }
            else {
                match read_imm_osize(osize) {
                    Ok(v) => v,
                    Err(()) => return true,
                }
            };
            let wide = (src as i128) * (imm as i128);
            let result = sized(wide as i64, osize);
            let overflowed = wide != result as i128;

            *flags_changed &= !(FLAG_CARRY | FLAG_OVERFLOW);
            *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW)
                | if overflowed { FLAG_CARRY | FLAG_OVERFLOW } else { 0 };
            write_reg_sized(reg, result, osize);
            true
        },

        // test al, imm8 and test rax/eax/ax, imm. test is and with the result thrown away, so only
        // the flags survive; the wider form's immediate is sign extended like every other one here.
        0xA8 => {
            let imm = match read_imm8() {
                Ok(v) => v as i64,
                Err(()) => return true,
            };
            let dst = read_reg8(0) as i8 as i64;
            set_flags64_logical((dst & imm) as i8 as i64);
            true
        },
        0xA9 => {
            let imm = match read_imm_osize(osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(read_reg64(EAX), osize);
            if osize == 64 {
                arith::logical64(dst & imm);
            }
            else {
                set_flags64_logical(sized(dst & imm, osize));
            }
            true
        },

        // adc and sbb at the wider sizes, which share the group1 encodings
        0x11 | 0x19 | 0x13 | 0x1B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let to_reg = 0 != opcode & 2;
            let reg = modrm_reg(modrm_byte);
            let (raw, addr) = match read_rm_keep_addr(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let rm = sized(raw, osize);
            let r = sized(read_reg64(reg), osize);
            let (dst, src) = if to_reg { (r, rm) } else { (rm, r) };
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, src, osize) {
                if to_reg {
                    write_reg_sized(reg, result, osize);
                }
                else {
                    let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
                }
            }
            true
        },

        // `op eAX, imm`, the accumulator short forms. The operation is bits 5:3, as elsewhere.
        0x05 | 0x0D | 0x15 | 0x1D | 0x25 | 0x2D | 0x35 | 0x3D => {
            let imm = match read_imm_osize(osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(read_reg64(EAX), osize);
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, sized(imm, osize), osize) {
                write_reg_sized(EAX, result, osize);
            }
            true
        },

        // group1: op r/m, imm32 (0x81) or sign extended imm8 (0x83)
        0x81 | 0x83 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            // 0x83 takes a byte of immediate, 0x81 one at the operand size
            let imm_bytes = if opcode == 0x83 {
                1
            }
            else if osize == 16 {
                2
            }
            else {
                4
            };
            let (raw, addr) = match read_rm_keep_addr_imm(modrm_byte, osize, imm_bytes) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(raw, osize);
            let imm = if opcode == 0x83 {
                // 0x83 always carries a sign extended byte, whatever the operand size
                match read_imm8s() {
                    Ok(v) => v as i64,
                    Err(()) => return true,
                }
            }
            else {
                match read_imm_osize(osize) {
                    Ok(v) => v,
                    Err(()) => return true,
                }
            };
            if let Some(result) = group1_op(modrm_byte >> 3 & 7, dst, sized(imm, osize), osize) {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
            }
            true
        },

        // shift group with an imm8 count (0xC1) or a count of one (0xD1)
        // the byte forms of the same shifts: by an immediate, by one, and by cl
        0xC0 | 0xD0 | 0xD2 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let imm_bytes = if opcode == 0xC0 { 1 } else { 0 };
            let (value, addr) = match read_rm_keep_addr_imm(modrm_byte, 8, imm_bytes) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let count = match opcode {
                0xD0 => 1,
                0xD2 => read_reg8(1 /* cl */),
                _ => match read_imm8() {
                    Ok(v) => v,
                    Err(()) => return true,
                },
            };
            match shift_op(modrm_byte >> 3 & 7, value, count, 8) {
                Some(result) => {
                    let _ = write_rm_keep_addr(modrm_byte, addr, result, 8);
                    true
                },
                None => false,
            }
        },

        0xC1 | 0xD1 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            // 0xc1 takes a byte of immediate, 0xd1 shifts by one and takes none
            let imm_bytes = if opcode == 0xC1 { 1 } else { 0 };
            let (value, addr) = match read_rm_keep_addr_imm(modrm_byte, osize, imm_bytes) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let count = if opcode == 0xD1 {
                1
            }
            else {
                match read_imm8() {
                    Ok(v) => v,
                    Err(()) => return true,
                }
            };
            match shift_op(modrm_byte >> 3 & 7, value, count, osize) {
                Some(result) => {
                    let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
                    true
                },
                None => false,
            }
        },

        // shift group by cl
        0xD3 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let (value, addr) = match read_rm_keep_addr(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let count = read_reg8(1 /* cl */);
            match shift_op(modrm_byte >> 3 & 7, value, count, osize) {
                Some(result) => {
                    let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
                    true
                },
                None => false,
            }
        },

        // test r/m8, r8
        0x84 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let src = read_reg8(modrm_reg(modrm_byte));
            let dst = match read_rm8(modrm_byte) {
                Ok(v) => v,
                Err(()) => return true,
            };
            set_flags64_logical((dst & src) as i8 as i64);
            true
        },

        // test r/m, r
        0x85 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let src = sized(read_reg64(modrm_reg(modrm_byte)), osize);
            let dst = match read_rm(modrm_byte, osize) {
                Ok(v) => sized(v, osize),
                Err(()) => return true,
            };
            if osize == 64 {
                arith::logical64(dst & src);
            }
            else {
                set_flags64_logical(sized(dst & src, osize));
            }
            true
        },

        // mov r/m, r
        0x89 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let value = read_reg64(modrm_reg(modrm_byte));
            let _ = write_rm(modrm_byte, value, osize);
            true
        },

        // mov r, r/m
        0x8B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            match read_rm(modrm_byte, osize) {
                Ok(v) => write_reg_sized(reg, v, osize),
                Err(()) => {},
            }
            true
        },

        // movsxd r64, r/m32, which is what widens a 32-bit value to an index or a pointer and so
        // appears wherever 64-bit code touches an array. The opcode is only this in 64-bit mode;
        // below it, it is arpl.
        //
        // Only rex.w is implemented. Without it the destination is 32 bits, which makes this a
        // plain mov with a sign extension that is then discarded, and the 16-bit form truncates
        // the source as well; both are documented as discouraged and neither has been asked for,
        // so they trap by name rather than being guessed at.
        0x63 => {
            if osize != 64 {
                dbg_log!("Unimplemented: movsxd with operand size {}", osize);
                return false;
            }
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            match read_rm(modrm_byte, 32) {
                // read_rm zero extends at 32, so the sign extension is done here
                Ok(v) => write_reg64(reg, v as u32 as i32 as i64),
                Err(()) => {},
            }
            true
        },

        // cbw/cwde/cdqe: widen the accumulator in place, keeping its sign. write_reg_sized gives
        // the right discard for each width, since a 32-bit write clears the top half and a 16-bit
        // one leaves it.
        0x98 => {
            let rax = read_reg64(EAX);
            let extended = match osize {
                16 => rax as i8 as i64,
                32 => rax as i16 as i64,
                _ => rax as i32 as i64,
            };
            write_reg_sized(EAX, extended, osize);
            true
        },

        // cwd/cdq/cqo: fill the whole of rdx with the accumulator's sign bit, which is how a
        // signed dividend is widened before idiv.
        0x99 => {
            let rax = read_reg64(EAX);
            let negative = match osize {
                16 => (rax as i16) < 0,
                32 => (rax as i32) < 0,
                _ => rax < 0,
            };
            write_reg_sized(EDX, if negative { -1 } else { 0 }, osize);
            true
        },

        // push r
        0x50..=0x57 => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            let _ = push64(read_reg64(reg));
            true
        },

        // pop r
        0x58..=0x5F => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            match pop64() {
                Ok(v) => write_reg64(reg, v),
                Err(()) => {},
            }
            true
        },

        // push imm8, sign extended to 64 bits
        0x6A => {
            match read_imm8s() {
                Ok(v) => {
                    let _ = push64(v as i64);
                },
                Err(()) => {},
            }
            true
        },

        // push imm32, sign extended to 64 bits
        0x68 => {
            match read_imm32s() {
                Ok(v) => {
                    let _ = push64(v as i64);
                },
                Err(()) => {},
            }
            true
        },

        // mov r8, imm8
        0xB0..=0xB7 => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            match read_imm8() {
                Ok(v) => write_reg8(reg, v),
                Err(()) => {},
            }
            true
        },

        // mov r, imm. The immediate is 64 bits wide only with rex.w
        0xB8..=0xBF => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            if osize == 64 {
                let low = match read_imm32s() {
                    Ok(v) => v as u32 as i64,
                    Err(()) => return true,
                };
                let high = match read_imm32s() {
                    Ok(v) => v as u32 as i64,
                    Err(()) => return true,
                };
                write_reg64(reg, high << 32 | low);
            }
            else {
                match read_imm_osize(osize) {
                    Ok(v) => write_reg_sized(reg, v, osize),
                    Err(()) => {},
                }
            }
            true
        },

        // two byte opcodes
        0x0F => {
            let opcode2 = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            run_0f(opcode2, osize)
        },

        // xchg rax, r, whose 0x90 case is nop.
        //
        // 0x90 is only nop when it names rax twice, which needs rex.b clear: with it set the
        // operand is r8 and the exchange is real. Treating the whole opcode as nop would silently
        // drop that swap, which is why this is not simply `0x90 => true`.
        0x90..=0x97 => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            if reg == 0 {
                // xchg rax, rax, which is the canonical nop and does not narrow the register
                return true;
            }
            let tmp = sized(read_reg64(EAX), osize);
            write_reg_sized(EAX, sized(read_reg64(reg), osize), osize);
            write_reg_sized(reg, tmp, osize);
            true
        },

        // hlt
        0xF4 => {
            crate::cpu::instructions::instr_F4();
            after_block_boundary();
            true
        },

        // mov r/m8, r8 and r8, r/m8
        0x88 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let value = read_reg8(modrm_reg(modrm_byte));
            let _ = write_rm8(modrm_byte, value);
            true
        },
        0x8A => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            match read_rm8(modrm_byte) {
                Ok(v) => write_reg8(reg, v),
                Err(()) => {},
            }
            true
        },

        // clc, stc, cmc, cli, sti, cld, std - identical in 64-bit mode
        0xF8 => {
            crate::cpu::instructions::instr_F8();
            true
        },
        0xF9 => {
            crate::cpu::instructions::instr_F9();
            true
        },
        0xF5 => {
            crate::cpu::instructions::instr_F5();
            true
        },
        0xFA => {
            crate::cpu::instructions::instr_FA();
            true
        },
        0xFB => {
            crate::cpu::instructions::instr_FB();
            true
        },
        0xFC => {
            crate::cpu::instructions::instr_FC();
            true
        },
        0xFD => {
            crate::cpu::instructions::instr_FD();
            true
        },

        // group 3: test/not/neg/mul/imul/div/idiv
        0xF6 | 0xF7 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let byte_op = opcode == 0xF6;
            let op = modrm_byte >> 3 & 7;

            // only the test forms carry an immediate; not, neg, mul and the divides do not, so
            // rip relative addressing counts past one only for those
            let imm_bytes = if op > 1 {
                0
            }
            else if byte_op {
                1
            }
            else if osize == 16 {
                2
            }
            else {
                4
            };
            let (dst, addr) = {
                let width = if byte_op { 8 } else { osize };
                match read_rm_keep_addr_imm(modrm_byte, width, imm_bytes) {
                    Ok((v, a)) => (sized(v, width), a),
                    Err(()) => return true,
                }
            };

            match op {
                // test r/m, imm
                0 | 1 => {
                    let imm = if byte_op {
                        match read_imm8s() {
                            Ok(v) => v as i64,
                            Err(()) => return true,
                        }
                    }
                    else {
                        match read_imm_osize(osize) {
                            Ok(v) => v,
                            Err(()) => return true,
                        }
                    };
                    set_flags64_logical(narrow(dst & imm, byte_op, osize));
                },
                // not: does not affect flags
                2 => {
                    let r = narrow(!dst, byte_op, osize);
                    let _ =
                        write_rm_keep_addr(modrm_byte, addr, r, if byte_op { 8 } else { osize });
                },
                // neg: 0 - dst, with carry set when the operand was non-zero
                3 => {
                    let r = narrow(0i64.wrapping_sub(dst), byte_op, osize);
                    set_flags64(0, dst, r, true);
                    let _ =
                        write_rm_keep_addr(modrm_byte, addr, r, if byte_op { 8 } else { osize });
                },
                // mul, imul, div and idiv. The double width operand is split across dx and ax at
                // every width but byte, where the whole of it fits in ax alone - so the byte forms
                // touch one register where the others touch two.
                _ => {
                    mul_div_op(op, dst, if byte_op { 8 } else { osize });
                },
            }
            true
        },

        // mov r/m, imm32 sign extended (0xC7) or imm8 (0xC6)
        // mov r/m, imm. The immediate follows the modrm, so a rip relative destination has to
        // count past it.
        0xC6 | 0xC7 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            if modrm_byte >> 3 & 7 != 0 {
                return false;
            }
            // The displacement belongs to the modrm encoding and comes before the immediate, so
            // the address has to be resolved first. Resolving it afterwards reads the immediate's
            // bytes as the displacement, and resolving it twice consumes them twice.
            // 0xc6 carries a byte immediate, 0xc7 one at the operand size (four bytes unless the
            // operand size is 16), and rip relative addressing counts from past it.
            let imm_bytes = if opcode == 0xC6 {
                1
            }
            else if osize == 16 {
                2
            }
            else {
                4
            };
            let addr = if modrm_byte >= 0xC0 {
                None
            }
            else {
                match resolve_modrm64_imm(modrm_byte, imm_bytes) {
                    Ok(a) => Some(a),
                    Err(()) => return true,
                }
            };

            if opcode == 0xC6 {
                let imm = match read_imm8() {
                    Ok(v) => v,
                    Err(()) => return true,
                };
                match addr {
                    None => write_reg8(modrm_rm(modrm_byte), imm),
                    Some(a) => {
                        let _ = safe_write8_64(a, imm);
                    },
                }
            }
            else {
                let imm = match read_imm_osize(osize) {
                    Ok(v) => v,
                    Err(()) => return true,
                };
                let value = sized(imm, osize);
                match addr {
                    None => write_reg_sized(modrm_rm(modrm_byte), value, osize),
                    Some(a) => {
                        let _ = match osize {
                            16 => safe_write16_64(a, value as i32 & 0xFFFF),
                            32 => safe_write32_64(a, value as i32),
                            _ => safe_write64_64(a, value as u64),
                        };
                    },
                }
            }
            true
        },

        // jmp rel8 / rel32
        0xEB | 0xE9 => {
            let offset = if opcode == 0xEB { read_imm8s() } else { read_imm32s() };
            match offset {
                Ok(v) => *instruction_pointer = (*instruction_pointer).wrapping_add(v),
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // call rel32. Near calls are always 64 bits wide in long mode
        0xE8 => {
            match read_imm32s() {
                Ok(v) => {
                    let return_address = *instruction_pointer as i64;
                    if push64(return_address).is_ok() {
                        *instruction_pointer = (*instruction_pointer).wrapping_add(v);
                    }
                },
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // retf. The stack slots are the operand size, 32 bits unless rex.w. far_return is not
        // reused: its checks are the 32-bit ones, and a 64-bit code segment has no limit to check
        // and a base that is always zero, so applying them raises a #gp that isn't real.
        0xCB => {
            let rsp = read_reg64(ESP);
            let slot = if osize == 64 { 8 } else { 4 };

            let read_slot = |offset: i64| -> OrPageFault<i64> {
                let addr = rsp + offset;
                if osize == 64 {
                    Ok(safe_read64s_64(addr)? as i64)
                }
                else {
                    Ok(safe_read32s_64(addr)? as u32 as i64)
                }
            };

            let target = match read_slot(0) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let selector = match read_slot(slot) {
                Ok(v) => v as i32 & 0xFFFF,
                Err(()) => return true,
            };

            if !switch_seg_64_code(selector) {
                return true;
            }
            match truncate_address(target) {
                Ok(a) => *instruction_pointer = a,
                Err(()) => return true,
            }
            write_reg64(ESP, rsp + slot * 2);
            after_block_boundary();
            true
        },

        // iret. Pops rip, cs, rflags, rsp and ss, eight bytes each
        0xCF => {
            let rsp = read_reg64(ESP);
            let slot = |i: i64| -> OrPageFault<i64> {
                Ok(safe_read64s_64(rsp + i * 8)? as i64)
            };
            let (rip, cs, rflags, new_rsp, ss) =
                match (|| Ok((slot(0)?, slot(1)?, slot(2)?, slot(3)?, slot(4)?)))() {
                    Ok(v) => v,
                    Err(()) => return true,
                };

            if !switch_seg_64_code(cs as i32 & 0xFFFF) {
                return true;
            }
            match truncate_address(rip) {
                Ok(a) => *instruction_pointer = a,
                Err(()) => return true,
            }
            update_eflags(rflags as i32);
            write_reg64(ESP, new_rsp);
            *sreg.offset(SS as isize) = ss as u16;
            after_block_boundary();
            true
        },

        // ret
        // the string instructions, with or without a rep prefix
        0xA4 | 0xA5 | 0xA6 | 0xA7 | 0xAA | 0xAB | 0xAC | 0xAD | 0xAE | 0xAF => {
            string_op(opcode, osize)
        },

        // inc and dec on a byte operand. The wider forms of these live in 0xff alongside the near
        // call, jump and push; at byte width only inc and dec exist, so the group is smaller.
        0xFE => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let op = modrm_byte >> 3 & 7;
            if op > 1 {
                dbg_log!("Unimplemented: 64-bit fe /{}", op);
                return false;
            }
            let (raw, addr) = match read_rm_keep_addr(modrm_byte, 8) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(raw, 8);
            let carry = getcf();
            let result = if op == 0 {
                group1_op(0, dst, 1, 8)
            }
            else {
                group1_op(5, dst, 1, 8)
            };
            // inc and dec are add and sub that leave carry alone
            *flags_changed &= !FLAG_CARRY;
            *flags = *flags & !FLAG_CARRY | if carry { FLAG_CARRY } else { 0 };
            if let Some(result) = result {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, 8);
            }
            true
        },

        0xC3 => {
            match pop64() {
                Ok(target) => match truncate_address(target) {
                    Ok(a) => *instruction_pointer = a,
                    Err(()) => {},
                },
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // ret imm16, which drops the caller's arguments after taking the return address. The
        // immediate is read before the pop, since a fault in the pop must leave rsp where it was.
        0xC2 => {
            let imm = match read_imm16() {
                Ok(v) => v,
                Err(()) => return true,
            };
            match pop64() {
                Ok(target) => match truncate_address(target) {
                    Ok(a) => {
                        *instruction_pointer = a;
                        write_reg64(ESP, read_reg64(ESP) + imm as i64);
                    },
                    Err(()) => {},
                },
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // jcc rel8
        0x70..=0x7F => {
            match read_imm8s() {
                Ok(offset) => {
                    if test_condition(opcode & 0xF) {
                        *instruction_pointer = (*instruction_pointer).wrapping_add(offset);
                    }
                },
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // lea r, m
        0x8D => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            if modrm_byte >= 0xC0 {
                // lea with a register source is undefined
                return false;
            }
            let reg = modrm_reg(modrm_byte);
            match resolve_modrm64_address(modrm_byte) {
                Ok(addr) => write_reg_sized(reg, addr, osize),
                Err(()) => {},
            }
            true
        },

        // mov r/m16, Sreg
        0x8C => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let value = *sreg.offset((modrm_byte >> 3 & 7) as isize) as i64;
            if modrm_byte >= 0xC0 {
                // to a register the value is zero extended to the operand size
                write_reg_sized(modrm_rm(modrm_byte), value, osize);
            }
            else {
                match resolve_modrm64(modrm_byte) {
                    Ok(addr) => {
                        let _ = safe_write16_64(addr, value as i32);
                    },
                    Err(()) => {},
                }
            }
            true
        },

        // mov Sreg, r/m16
        0x8E => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let seg = modrm_byte >> 3 & 7;
            let value = if modrm_byte >= 0xC0 {
                read_reg64(modrm_rm(modrm_byte)) as i32 & 0xFFFF
            }
            else {
                match resolve_modrm64(modrm_byte) {
                    Ok(addr) => match safe_read16_64(addr) {
                        Ok(v) => v,
                        Err(()) => return true,
                    },
                    Err(()) => return true,
                }
            };
            switch_seg(seg, value);
            after_block_boundary();
            true
        },

        _ => false,
    }
}

/// The 0x0F escaped opcodes
unsafe fn run_0f(opcode: i32, osize: i32) -> bool {
    match opcode {
        // jcc rel32
        0x80..=0x8F => {
            match read_imm32s() {
                Ok(offset) => {
                    if test_condition(opcode & 0xF) {
                        *instruction_pointer = (*instruction_pointer).wrapping_add(offset);
                    }
                },
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // setcc r/m8
        0x90..=0x9F => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let value = test_condition(opcode & 0xF) as i32;
            let _ = write_rm8(modrm_byte, value);
            true
        },

        // cmovcc r, r/m
        0x40..=0x4F => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let src = match read_rm(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            // The destination is written either way: a cmov with a false condition still zero
            // extends a 32-bit destination
            let value = if test_condition(opcode & 0xF) { src } else { read_reg64(reg) };
            write_reg_sized(reg, value, osize);
            true
        },

        // movzx r, r/m8 and r/m16
        // cmpxchg r/m, r: compare the accumulator against the destination and, if they are equal,
        // put the register there; otherwise load the destination into the accumulator. Every
        // interlocked operation is built out of this, so a guest doing any locking wants it.
        //
        // The comparison is exactly cmp accumulator, destination, so it goes through the same
        // group1 path and leaves the same flags behind. Zero is the one the caller branches on,
        // and it is also what decides which way the exchange goes here.
        //
        // A read modify write, so the modrm is resolved once and the address reused. Hardware
        // writes the destination back even when they differ, which matters for the bus lock and
        // is not observable here.
        0xB0 | 0xB1 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let size = if opcode == 0xB0 { 8 } else { osize };
            let reg = modrm_reg(modrm_byte);
            let (dst_raw, addr) = match read_rm_keep_addr(modrm_byte, size) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = if size == 8 { dst_raw as i8 as i64 } else { sized(dst_raw, size) };
            let acc = if size == 8 { read_reg8(0) as i8 as i64 } else { sized(read_reg64(EAX), size) };
            group1_op(7, acc, dst, size);
            if getzf() {
                let src =
                    if size == 8 { read_reg8(reg) as i64 } else { sized(read_reg64(reg), size) };
                if write_rm_keep_addr(modrm_byte, addr, src, size).is_err() {
                    return true;
                }
            }
            else if size == 8 {
                write_reg8(0, dst_raw as i32);
            }
            else {
                write_reg_sized(EAX, dst_raw, size);
            }
            true
        },

        // xadd r/m, r: the destination takes the sum and the register takes what the destination
        // held, which is how an interlocked increment learns the value it incremented past.
        //
        // The flags are an ordinary add's, so group1_op does it. Order matters when both operands
        // name the same register: the destination is written last, so the sum wins, which is what
        // hardware does.
        0xC0 | 0xC1 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let size = if opcode == 0xC0 { 8 } else { osize };
            let reg = modrm_reg(modrm_byte);
            let (dst_raw, addr) = match read_rm_keep_addr(modrm_byte, size) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = if size == 8 { dst_raw as i8 as i64 } else { sized(dst_raw, size) };
            let src = if size == 8 { read_reg8(reg) as i8 as i64 } else { sized(read_reg64(reg), size) };
            let sum = match group1_op(0, dst, src, size) {
                Some(v) => v,
                // add always produces a value; this cannot happen, and guessing would be worse
                None => return false,
            };
            if size == 8 {
                write_reg8(reg, dst_raw as i32);
            }
            else {
                write_reg_sized(reg, dst_raw, size);
            }
            if write_rm_keep_addr(modrm_byte, addr, sum, size).is_err() {
                return true;
            }
            true
        },

        0xB6 | 0xB7 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let value = match read_rm_narrow(modrm_byte, opcode == 0xB7) {
                Ok(v) => v,
                Err(()) => return true,
            };
            write_reg_sized(reg, value as i64, osize);
            true
        },

        // movsx r, r/m8 and r/m16
        0xBE | 0xBF => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let value = match read_rm_narrow(modrm_byte, opcode == 0xBF) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let extended = if opcode == 0xBF { value as i16 as i64 } else { value as i8 as i64 };
            write_reg_sized(reg, extended, osize);
            true
        },

        // sse instructions that behave the same in 64-bit mode
        // movd/movq between an xmm register and a general purpose one or memory, and the movhps
        // pair that sits beside them. Windows zeroes memory with this group: a value is put in an
        // xmm register, spread across both halves, and stored sixteen bytes at a time.
        //
        // rex.w widens 0f 6e and 0f 7e from movd to movq, which the 32-bit implementations cannot
        // express, so those two are done here rather than delegated. The operand width cannot come
        // from osize either: the 0x66 here is the mandatory prefix selecting the sse form, not an
        // operand size override, so without rex.w the operand is 32 bits rather than 16.
        0x6E | 0x7E | 0x16 | 0x17 => {
            use crate::cpu::instructions_0f as i0f;
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let has_66 = 0 != *prefixes & crate::prefix::PREFIX_66;
            let has_f3 = 0 != *prefixes & crate::prefix::PREFIX_F3;
            let width = if 0 != *rex & REX_W { 64 } else { 32 };

            match (opcode, has_66, has_f3) {
                (0x16, false, false) => {
                    sse_delegate(modrm_byte, i0f::instr_0F16_reg, i0f::instr_0F16_mem)
                },
                (0x16, true, false) => {
                    sse_delegate(modrm_byte, i0f::instr_660F16_reg, i0f::instr_660F16_mem)
                },
                (0x17, false, false) => {
                    sse_delegate(modrm_byte, i0f::instr_0F17_reg, i0f::instr_0F17_mem)
                },
                (0x17, true, false) => {
                    sse_delegate(modrm_byte, i0f::instr_660F17_reg, i0f::instr_660F17_mem)
                },
                (0x7E, false, true) => {
                    sse_delegate(modrm_byte, i0f::instr_F30F7E_reg, i0f::instr_F30F7E_mem)
                },
                // movd/movq xmm, r/m: the rest of the register is cleared either way
                (0x6E, true, false) => {
                    let r = modrm_reg(modrm_byte);
                    let value = match read_rm(modrm_byte, width) {
                        Ok(v) => v,
                        Err(()) => return true,
                    };
                    let high = if width == 64 { (value >> 32) as i32 } else { 0 };
                    write_xmm128(r, value as i32, high, 0, 0);
                    true
                },
                // movd/movq r/m, xmm
                (0x7E, true, false) => {
                    let r = modrm_reg(modrm_byte);
                    let value = read_xmm64s(r) as i64;
                    let _ = write_rm(modrm_byte, value, width);
                    true
                },
                _ => {
                    dbg_log!(
                        "Unimplemented 64-bit sse {:02x} 66={} f3={}",
                        opcode,
                        has_66,
                        has_f3
                    );
                    false
                },
            }
        },

        0x10 | 0x11 | 0x28 | 0x29 | 0x57 | 0x6F | 0x7F | 0xEF => {
            use crate::cpu::instructions_0f as i0f;
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let has_66 = 0 != *prefixes & crate::prefix::PREFIX_66;
            let has_f3 = 0 != *prefixes & crate::prefix::PREFIX_F3;

            // A memory operand here is a whole 128-bit access, and windows makes them through
            // kernel addresses - so they are done at full address width rather than delegated to
            // the 32-bit implementations, which take an i32 address. Only the operand differs
            // between these; what each does with it is still the existing implementation, reached
            // through the variants that take a value rather than an address.
            //
            // movss and movsd are deliberately absent: an f3 or f2 prefix on 0x10/0x11 makes the
            // access 32 or 64 bits wide rather than 128, so they are not part of this shape.
            if modrm_byte < 0xC0 && !(has_f3 && (opcode == 0x10 || opcode == 0x11)) {
                let addr = match resolve_modrm64(modrm_byte) {
                    Ok(a) => a,
                    Err(()) => return true,
                };
                let r = modrm_reg(modrm_byte);
                let is_store = opcode == 0x11 || opcode == 0x29 || opcode == 0x7F;
                if is_store {
                    let _ = safe_write128_64(addr, read_xmm128s(r));
                    return true;
                }
                let source = match safe_read128s_64(addr) {
                    Ok(v) => v,
                    Err(()) => return true,
                };
                return match (opcode, has_66, has_f3) {
                    (0x10, false, false) | (0x10, true, false) => {
                        i0f::instr_0F10(source, r);
                        true
                    },
                    (0x28, false, false) | (0x28, true, false) => {
                        i0f::instr_0F28(source, r);
                        true
                    },
                    (0x57, false, false) => {
                        i0f::instr_0F57(source, r);
                        true
                    },
                    (0x6F, true, false) => {
                        i0f::instr_660F6F(source, r);
                        true
                    },
                    (0x6F, false, true) => {
                        i0f::instr_F30F6F(source, r);
                        true
                    },
                    (0xEF, true, false) => {
                        i0f::instr_660FEF(source, r);
                        true
                    },
                    _ => {
                        dbg_log!(
                            "Unimplemented 64-bit sse load {:02x} 66={} f3={}",
                            opcode,
                            has_66,
                            has_f3
                        );
                        false
                    },
                };
            }

            if has_f3 {
                return match opcode {
                    0x10 => sse_delegate(modrm_byte, i0f::instr_F30F10_reg, i0f::instr_F30F10_mem),
                    0x11 => sse_delegate(modrm_byte, i0f::instr_F30F11_reg, i0f::instr_F30F11_mem),
                    0x6F => sse_delegate(modrm_byte, i0f::instr_F30F6F_reg, i0f::instr_F30F6F_mem),
                    0x7F => sse_delegate(modrm_byte, i0f::instr_F30F7F_reg, i0f::instr_F30F7F_mem),
                    _ => {
                        dbg_log!("Unimplemented 64-bit sse f3 {:02x}", opcode);
                        false
                    },
                };
            }
            match (opcode, has_66) {
                (0x10, false) => sse_delegate(modrm_byte, i0f::instr_0F10_reg, i0f::instr_0F10_mem),
                (0x11, false) => sse_delegate(modrm_byte, i0f::instr_0F11_reg, i0f::instr_0F11_mem),
                (0x28, false) => sse_delegate(modrm_byte, i0f::instr_0F28_reg, i0f::instr_0F28_mem),
                (0x29, false) => sse_delegate(modrm_byte, i0f::instr_0F29_reg, i0f::instr_0F29_mem),
                (0x57, false) => sse_delegate(modrm_byte, i0f::instr_0F57_reg, i0f::instr_0F57_mem),
                (0x6F, true) => {
                    sse_delegate(modrm_byte, i0f::instr_660F6F_reg, i0f::instr_660F6F_mem)
                },
                (0x7F, true) => {
                    sse_delegate(modrm_byte, i0f::instr_660F7F_reg, i0f::instr_660F7F_mem)
                },
                (0xEF, true) => {
                    sse_delegate(modrm_byte, i0f::instr_660FEF_reg, i0f::instr_660FEF_mem)
                },
                _ => {
                    dbg_log!("Unimplemented 64-bit sse {:02x} 66={}", opcode, has_66);
                    false
                },
            }
        },

        // group 6: sldt, str, lldt, ltr, verr, verw. The loads take a system descriptor, which is
        // sixteen bytes in long mode rather than eight, with a 64-bit base; the 32-bit paths would
        // read half of one. The stores are the same either way.
        0x00 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let group = modrm_byte >> 3 & 7;
            match group {
                // sldt, str
                0 | 1 => {
                    let seg = if group == 0 { LDTR } else { TR };
                    let value = *sreg.offset(seg as isize) as i32;
                    if modrm_byte >= 0xC0 {
                        write_reg_sized(modrm_rm(modrm_byte), value as i64, osize);
                    }
                    else {
                        match resolve_modrm64(modrm_byte) {
                            Ok(addr) => {
                                let _ = safe_write16_64(addr, value);
                            },
                            Err(()) => {},
                        }
                    }
                    true
                },
                // lldt and ltr, whose descriptor is the sixteen byte form
                2 | 3 => {
                    let value = match read_rm(modrm_byte, 16) {
                        Ok(v) => v as i32 & 0xFFFF,
                        Err(()) => return true,
                    };
                    if group == 2 {
                        load_ldt_64(value)
                    }
                    else {
                        load_tr_64(value)
                    }
                },
                _ => {
                    dbg_log!("Unimplemented: 64-bit 0f00 /{}", group);
                    false
                },
            }
        },

        // group 7: lgdt and lidt, whose pseudo descriptor is ten bytes in long mode rather than
        // six - the base is eight
        0x01 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let group = modrm_byte >> 3 & 7;

            // /7 with a memory operand is invlpg, which drops one page rather than loading a
            // descriptor table. Its operand is a virtual address like any other, so it has to be
            // taken at full width - windows invalidates kernel pages while it builds the address
            // space it is about to run in.
            if group == 7 && modrm_byte < 0xC0 {
                if 0 != *cpl {
                    trigger_gp(0);
                    return true;
                }
                match resolve_modrm64(modrm_byte) {
                    Ok(addr) => invlpg64(addr),
                    Err(()) => {},
                }
                return true;
            }

            if modrm_byte >= 0xC0 || !matches!(group, 0 | 1 | 2 | 3) {
                dbg_log!("Unimplemented: 64-bit 0f01 /{}", group);
                return false;
            }
            let addr = match resolve_modrm64(modrm_byte) {
                Ok(a) => a,
                Err(()) => return true,
            };

            // /0 and /1 store, /2 and /3 load
            if group < 2 {
                let (size, base) = if group == 0 {
                    (*gdtr_size, *gdtr_offset)
                }
                else {
                    (*idtr_size, *idtr_offset)
                };
                if safe_write16_64(addr, size).is_err() {
                    return true;
                }
                // the base is eight bytes here, and v86 only ever holds a 32-bit one
                let _ = safe_write64_64(addr + 2, base as u32 as u64);
                return true;
            }

            let size = match safe_read16_64(addr) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let base = match safe_read64s_64(addr + 2) {
                Ok(v) => v as i64,
                Err(()) => return true,
            };
            let base = match truncate_address(base) {
                Ok(b) => b,
                Err(()) => return true,
            };
            if group == 2 {
                *gdtr_size = size;
                *gdtr_offset = base;
            }
            else {
                *idtr_size = size;
                *idtr_offset = base;
            }
            true
        },

        // bit test group with an immediate index
        0xBA => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let op = modrm_byte >> 3 & 7;
            if !(4..=7).contains(&op) {
                dbg_log!("Unimplemented: 64-bit 0fba /{}", op);
                return false;
            }
            // a byte of immediate follows the modrm
            let (value, addr) = match read_rm_keep_addr_imm(modrm_byte, osize, 1) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let bit = match read_imm8() {
                Ok(v) => v,
                Err(()) => return true,
            };
            if let Some(result) = bit_test_op(op, value, bit, osize) {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
            }
            true
        },

        // bit test group with the index in a register. With a memory operand the index is signed
        // and can reach outside the operand, which is not implemented; the register form is.
        0xA3 | 0xAB | 0xB3 | 0xBB => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            if modrm_byte < 0xC0 {
                dbg_log!("Unimplemented: 64-bit bit test on memory with a register index");
                return false;
            }
            // the operation sits where the reg field would be for the immediate form
            let op = match opcode {
                0xA3 => 4,
                0xAB => 5,
                0xB3 => 6,
                _ => 7,
            };
            let bit = read_reg64(modrm_reg(modrm_byte)) as i32;
            let (value, addr) = match read_rm_keep_addr(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            if let Some(result) = bit_test_op(op, value, bit, osize) {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
            }
            true
        },

        // mov r64, crN and mov crN, r64. The operand is always 64 bits here, rex.w or not, and
        // rex.r selects cr8 rather than extending the register.
        0x20 | 0x22 => {
            if 0 != *cpl {
                trigger_gp(0);
                return true;
            }
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let creg = (modrm_byte >> 3 & 7) | rex_bit(REX_R);
            let reg = modrm_rm(modrm_byte);

            if !matches!(creg, 0 | 2 | 3 | 4) {
                dbg_log!("Unimplemented: 64-bit mov with cr{}", creg);
                return false;
            }

            if opcode == 0x20 {
                write_reg64(reg, *cr.offset(creg as isize) as u32 as i64);
            }
            else {
                let value = read_reg64(reg);
                dbg_assert!(
                    value as u64 >> 32 == 0,
                    "Unsupported: control register above 32 bits"
                );
                match creg {
                    0 => set_cr0(value as i32),
                    2 => *cr.offset(2) = value as i32,
                    3 => set_cr3(value as i32),
                    _ => {
                        // cr4 goes through the 0f22 path for its side effects
                        crate::cpu::instructions_0f::instr_0F22(reg, 4);
                        return true;
                    },
                }
                after_block_boundary();
            }
            true
        },

        // imul r, r/m. Carry and overflow say the result did not fit in the destination; the
        // rest are undefined and left alone.
        0xAF => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let src = match read_rm(modrm_byte, osize) {
                Ok(v) => sized(v, osize),
                Err(()) => return true,
            };
            let dst = sized(read_reg64(reg), osize);
            let wide = (dst as i128) * (src as i128);
            let result = sized(wide as i64, osize);
            let overflowed = wide != result as i128;

            *flags_changed &= !(FLAG_CARRY | FLAG_OVERFLOW);
            *flags = *flags & !(FLAG_CARRY | FLAG_OVERFLOW)
                | if overflowed { FLAG_CARRY | FLAG_OVERFLOW } else { 0 };
            write_reg_sized(reg, result, osize);
            true
        },

        // multi byte nop, which still has a modrm to consume
        0x1F => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            if modrm_byte < 0xC0 {
                let _ = resolve_modrm64(modrm_byte);
            }
            true
        },

        // bswap
        // 0f c7 /6 reg is rdrand, which windows uses to seed itself once cpuid advertises it.
        // rex.w makes it 64 bits wide, which needs two draws from the 32-bit source.
        //
        // The other member of this group, /1 mem, is cmpxchg8b - and rex.w turns that one into
        // cmpxchg16b, a different instruction rather than a wider form of the same one. Neither is
        // implemented here, so both fall through and trap by name.
        0xC7 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let group = modrm_byte >> 3 & 7;
            if group != 6 || modrm_byte < 0xC0 {
                dbg_log!("Unimplemented: 64-bit 0fc7 /{}", group);
                return false;
            }
            let rand = if osize == 64 {
                js::get_rand_int() as u32 as i64 | (js::get_rand_int() as u32 as i64) << 32
            }
            else {
                js::get_rand_int() as u32 as i64
            };
            write_reg_sized((modrm_byte & 7) | rex_bit(REX_B), rand, osize);
            // success is reported in cf, and the other arithmetic flags are cleared
            *flags &= !FLAGS_ALL;
            *flags |= 1;
            *flags_changed = 0;
            true
        },

        0xC8..=0xCF => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            let value = read_reg64(reg);
            let swapped =
                if osize == 64 { value.swap_bytes() } else { (value as u32).swap_bytes() as i64 };
            write_reg_sized(reg, swapped, osize);
            true
        },

        // the fence group. lfence, mfence and sfence are the register forms of 0f ae /5, /6 and
        // /7, and order memory against other cpus - of which there are none here, so they are the
        // no-ops the 32-bit implementations already make them. Windows pairs them with a lock
        // prefixed operation on a throwaway operand to get a full barrier.
        //
        // The memory forms are a different matter entirely - fxsave, xrstor, clflush - and are
        // left to trap by name rather than being folded in here.
        0xAE => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let group = modrm_byte >> 3 & 7;
            if modrm_byte < 0xC0 || !matches!(group, 5 | 6 | 7) {
                dbg_log!("Unimplemented: 64-bit 0fae /{} mod={}", group, modrm_byte >> 6);
                return false;
            }
            true
        },

        // bsf and bsr: the index of the lowest or highest set bit. A source of zero has no index,
        // so zf says so and the destination keeps whatever it already held - which is why nothing
        // is written in that case rather than a zero being written.
        0xBC | 0xBD => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let src = match read_rm(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let src = if osize == 64 {
                src as u64
            }
            else {
                (src as u64) & ((1u64 << osize) - 1)
            };

            *flags_changed = FLAGS_ALL & !FLAG_ZERO & !FLAG_CARRY;
            *flags &= !FLAG_CARRY;
            *last_op_size = match osize {
                64 => OPSIZE_64,
                32 => OPSIZE_32,
                _ => OPSIZE_16,
            };

            let result = if src == 0 {
                *flags |= FLAG_ZERO;
                0
            }
            else {
                *flags &= !FLAG_ZERO;
                let index = if opcode == 0xBC {
                    src.trailing_zeros()
                }
                else {
                    63 - src.leading_zeros()
                } as i64;
                write_reg_sized(reg, index, osize);
                index
            };
            if osize == 64 {
                *last_result_64 = result;
            }
            else {
                *last_result = result as i32;
            }
            true
        },

        // cpuid
        0xA2 => {
            crate::cpu::instructions_0f::instr_0FA2();
            true
        },

        // system instructions whose behaviour doesn't change in 64-bit mode
        0x06 => {
            crate::cpu::instructions_0f::instr_0F06();
            true
        },
        0x09 => {
            crate::cpu::instructions_0f::instr_0F09();
            true
        },
        0x0B => {
            crate::cpu::instructions_0f::instr_0F0B();
            true
        },
        0x30 => {
            crate::cpu::instructions_0f::instr_0F30();
            true
        },
        0x31 => {
            crate::cpu::instructions_0f::instr_0F31();
            true
        },
        0x32 => {
            crate::cpu::instructions_0f::instr_0F32();
            true
        },
        0x77 => {
            crate::cpu::instructions_0f::instr_0F77();
            true
        },

        _ => {
            dbg_log!("Unimplemented 64-bit 0f opcode {:02x}", opcode);
            false
        },
    }
}

/// Read an 8 or 16 bit r/m operand, zero extended
unsafe fn read_rm_narrow(modrm_byte: i32, word: bool) -> OrPageFault<i32> {
    if modrm_byte >= 0xC0 {
        let r = modrm_rm(modrm_byte);
        Ok(if word { read_reg64(r) as i32 & 0xFFFF } else { read_reg8(r) })
    }
    else {
        let addr = resolve_modrm64(modrm_byte)?;
        if word {
            safe_read16_64(addr)
        }
        else {
            safe_read8_64(addr)
        }
    }
}

/// 0xFF group, which is where the 64-bit indirect call and jump live
pub unsafe fn run_ff(modrm_byte: i32) -> bool {
    // rex.w and a 0x66 prefix apply to inc, dec and push here; the near call and jump are always
    // 64 bits wide in long mode
    let osize = if 0 != *rex & REX_W {
        64
    }
    else if 0 != *prefixes & crate::prefix::PREFIX_66 {
        16
    }
    else {
        32
    };

    match modrm_byte >> 3 & 7 {
        // inc and dec, which leave carry alone
        op @ (0 | 1) => {
            let (raw, addr) = match read_rm_keep_addr(modrm_byte, osize) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let dst = sized(raw, osize);
            let carry = getcf();
            let result =
                if op == 0 { group1_op(0, dst, 1, osize) } else { group1_op(5, dst, 1, osize) };
            // inc and dec are add and sub that do not touch carry
            *flags_changed &= !FLAG_CARRY;
            *flags = *flags & !FLAG_CARRY | if carry { FLAG_CARRY } else { 0 };
            if let Some(result) = result {
                let _ = write_rm_keep_addr(modrm_byte, addr, result, osize);
            }
            true
        },

        // push r/m, always eight bytes wide
        6 => {
            let value = match read_rm(modrm_byte, 64) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let _ = push64(value);
            true
        },

        // call r/m64. Near calls default to a 64-bit operand size, rex.w or not
        2 => {
            let target = match read_rm(modrm_byte, 64) {
                Ok(v) => v,
                Err(()) => return true,
            };
            let return_address = *instruction_pointer as i64;
            if push64(return_address).is_err() {
                return true;
            }
            match truncate_address(target) {
                Ok(a) => *instruction_pointer = a,
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        // jmp r/m64
        4 => {
            let target = match read_rm(modrm_byte, 64) {
                Ok(v) => v,
                Err(()) => return true,
            };
            match truncate_address(target) {
                Ok(a) => *instruction_pointer = a,
                Err(()) => {},
            }
            after_block_boundary();
            true
        },

        _ => false,
    }
}
