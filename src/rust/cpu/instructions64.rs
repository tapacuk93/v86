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
use crate::cpu::misc_instr::{getaf, getcf, getof, getpf, getsf, getzf};
use crate::paging::OrPageFault;

/// A linear address computed in 64-bit mode. v86 can only address the low 4 GiB.
fn truncate_address(addr: i64) -> OrPageFault<i32> {
    if addr as u64 >> 32 != 0 {
        dbg_log!("Unsupported: 64-bit address {:x} above 4 GiB", addr);
        dbg_assert!(false, "Unsupported: address above 4 GiB");
        return Err(());
    }
    Ok(addr as i32)
}

/// Narrow a value to the current operand size, sign extended so the flag computation sees the
/// right sign bit
fn sized(value: i64, wide: bool) -> i64 {
    if wide {
        value
    }
    else {
        value as i32 as i64
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
unsafe fn resolve_modrm64(modrm_byte: i32) -> OrPageFault<i32> {
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
        // rip relative: the displacement is added to the address of the next instruction, so it
        // must be read before instruction_pointer has moved past any immediate that follows
        let disp = read_imm32s()? as i64;
        *instruction_pointer as i64 + disp
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

    truncate_address(addr)
}

/// Push in 64-bit mode, where the stack is always 64 bits wide and the stack segment has no base
unsafe fn push64(value: i64) -> OrPageFault<()> {
    let new_rsp = read_reg64(ESP) - 8;
    safe_write64(truncate_address(new_rsp)?, value as u64)?;
    write_reg64(ESP, new_rsp);
    Ok(())
}

unsafe fn pop64() -> OrPageFault<i64> {
    let rsp = read_reg64(ESP);
    let value = safe_read64s(truncate_address(rsp)?)? as i64;
    write_reg64(ESP, rsp + 8);
    Ok(value)
}

/// Read the r/m operand at the current operand size
unsafe fn read_rm(modrm_byte: i32, wide: bool) -> OrPageFault<i64> {
    if modrm_byte >= 0xC0 {
        let r = modrm_rm(modrm_byte);
        Ok(if wide { read_reg64(r) } else { read_reg64(r) as i32 as u32 as i64 })
    }
    else {
        let addr = resolve_modrm64(modrm_byte)?;
        Ok(if wide { safe_read64s(addr)? as i64 } else { safe_read32s(addr)? as u32 as i64 })
    }
}

/// Write a general purpose register. A 32-bit write zero extends into the full register, which is
/// what makes `sub eax, eax` a valid way to clear rax.
unsafe fn write_reg_sized(reg: i32, value: i64, wide: bool) {
    if wide {
        write_reg64(reg, value);
    }
    else {
        write_reg64(reg, value as u32 as i64);
    }
}

unsafe fn write_rm(modrm_byte: i32, value: i64, wide: bool) -> OrPageFault<()> {
    if modrm_byte >= 0xC0 {
        write_reg_sized(modrm_rm(modrm_byte), value, wide);
        Ok(())
    }
    else {
        let addr = resolve_modrm64(modrm_byte)?;
        if wide {
            safe_write64(addr, value as u64)
        }
        else {
            safe_write32(addr, value as i32)
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
unsafe fn group1_op(op: i32, dst: i64, src: i64, wide: bool) -> Option<i64> {
    // At the full width the flags stay lazy, the same as every other operand size, so that
    // generated code can defer them too. Narrower operations still go through the 32-bit path,
    // where the operands must be brought back to their own width first: otherwise the sign bit is
    // looked for at bit 63, and a result of 0x1_0000_0000 would not count as zero.
    if wide {
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
            _ => {
                dbg_log!("Unimplemented: 64-bit adc/sbb");
                dbg_assert!(false, "Unimplemented: 64-bit adc/sbb");
                None
            },
        };
    }
    match op {
        0 => {
            let r = sized(dst.wrapping_add(src), wide);
            set_flags64(dst, src, r, false);
            Some(r)
        },
        1 => {
            let r = sized(dst | src, wide);
            set_flags64_logical(r);
            Some(r)
        },
        4 => {
            let r = sized(dst & src, wide);
            set_flags64_logical(r);
            Some(r)
        },
        5 => {
            let r = sized(dst.wrapping_sub(src), wide);
            set_flags64(dst, src, r, true);
            Some(r)
        },
        6 => {
            let r = sized(dst ^ src, wide);
            set_flags64_logical(r);
            Some(r)
        },
        7 => {
            // cmp: subtract and discard
            let r = sized(dst.wrapping_sub(src), wide);
            set_flags64(dst, src, r, true);
            None
        },
        // adc and sbb need the incoming carry, which is fine, but they are not needed yet
        _ => {
            dbg_log!("Unimplemented: 64-bit group1 op {}", op);
            dbg_assert!(false, "Unimplemented: 64-bit adc/sbb");
            None
        },
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
fn narrow(value: i64, byte_op: bool, wide: bool) -> i64 {
    if byte_op {
        value as i8 as i64
    }
    else {
        sized(value, wide)
    }
}

unsafe fn read_rm8(modrm_byte: i32) -> OrPageFault<i32> {
    if modrm_byte >= 0xC0 {
        Ok(read_reg8(modrm_rm(modrm_byte)))
    }
    else {
        safe_read8(resolve_modrm64(modrm_byte)?)
    }
}

unsafe fn write_rm8(modrm_byte: i32, value: i32) -> OrPageFault<()> {
    if modrm_byte >= 0xC0 {
        write_reg8(modrm_rm(modrm_byte), value);
        Ok(())
    }
    else {
        safe_write8(resolve_modrm64(modrm_byte)?, value)
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

/// Dispatch one instruction in 64-bit mode. `rex` has already been consumed. Returns false if the
/// opcode isn't implemented yet, in which case the caller reports it.
pub unsafe fn run(opcode: i32) -> bool {
    // rex.w selects a 64-bit operand size, otherwise it is 32.
    let wide = 0 != *rex & REX_W;

    // A 0x66 prefix makes it 16, which changes how many bytes the immediate occupies. Nothing here
    // implements that, and decoding such an instruction at the wrong width does not merely compute
    // the wrong value: it consumes the wrong number of bytes, and every instruction after it is
    // garbage. Refuse instead. 0x8E is exempt, its operand being r/m16 with or without the prefix.
    if 0 != *prefixes & crate::prefix::PREFIX_66 && opcode != 0x8E {
        dbg_log!(
            "Unimplemented: 16-bit operand size in 64-bit mode, opcode {:02x}",
            opcode
        );
        return false;
    }

    match opcode {
        // `op r/m, r` for add/or/and/sub/xor/cmp. The operation is bits 5:3 of the opcode.
        0x01 | 0x09 | 0x21 | 0x29 | 0x31 | 0x39 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let src = sized(read_reg64(modrm_reg(modrm_byte)), wide);
            let dst = match read_rm(modrm_byte, wide) {
                Ok(v) => sized(v, wide),
                Err(()) => return true,
            };
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, src, wide) {
                let _ = write_rm(modrm_byte, result, wide);
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
            let src = match read_rm(modrm_byte, wide) {
                Ok(v) => sized(v, wide),
                Err(()) => return true,
            };
            let dst = sized(read_reg64(reg), wide);
            if let Some(result) = group1_op(opcode >> 3 & 7, dst, src, wide) {
                write_reg_sized(reg, result, wide);
            }
            true
        },

        // group1: op r/m, imm32 (0x81) or sign extended imm8 (0x83)
        0x81 | 0x83 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let dst = match read_rm(modrm_byte, wide) {
                Ok(v) => sized(v, wide),
                Err(()) => return true,
            };
            let imm = if opcode == 0x83 {
                match read_imm8s() {
                    Ok(v) => v as i64,
                    Err(()) => return true,
                }
            }
            else {
                match read_imm32s() {
                    Ok(v) => v as i64,
                    Err(()) => return true,
                }
            };
            if let Some(result) = group1_op(modrm_byte >> 3 & 7, dst, sized(imm, wide), wide) {
                let _ = write_rm(modrm_byte, result, wide);
            }
            true
        },

        // test r/m, r
        0x85 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let src = sized(read_reg64(modrm_reg(modrm_byte)), wide);
            let dst = match read_rm(modrm_byte, wide) {
                Ok(v) => sized(v, wide),
                Err(()) => return true,
            };
            if wide {
                arith::logical64(dst & src);
            }
            else {
                set_flags64_logical(sized(dst & src, wide));
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
            let _ = write_rm(modrm_byte, value, wide);
            true
        },

        // mov r, r/m
        0x8B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            match read_rm(modrm_byte, wide) {
                Ok(v) => write_reg_sized(reg, v, wide),
                Err(()) => {},
            }
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

        // mov r, imm. The immediate is 64 bits wide only with rex.w
        0xB8..=0xBF => {
            let reg = (opcode & 7) | rex_bit(REX_B);
            if wide {
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
                match read_imm32s() {
                    Ok(v) => write_reg_sized(reg, v as i64, false),
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
            run_0f(opcode2, wide)
        },

        // nop
        0x90 => true,

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

            let dst = if byte_op {
                match read_rm8(modrm_byte) {
                    Ok(v) => v as i8 as i64,
                    Err(()) => return true,
                }
            }
            else {
                match read_rm(modrm_byte, wide) {
                    Ok(v) => sized(v, wide),
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
                        match read_imm32s() {
                            Ok(v) => v as i64,
                            Err(()) => return true,
                        }
                    };
                    set_flags64_logical(narrow(dst & imm, byte_op, wide));
                },
                // not: does not affect flags
                2 => {
                    let r = narrow(!dst, byte_op, wide);
                    if byte_op {
                        let _ = write_rm8(modrm_byte, r as i32);
                    }
                    else {
                        let _ = write_rm(modrm_byte, r, wide);
                    }
                },
                // neg: 0 - dst, with carry set when the operand was non-zero
                3 => {
                    let r = narrow(0i64.wrapping_sub(dst), byte_op, wide);
                    set_flags64(0, dst, r, true);
                    if byte_op {
                        let _ = write_rm8(modrm_byte, r as i32);
                    }
                    else {
                        let _ = write_rm(modrm_byte, r, wide);
                    }
                },
                _ => {
                    dbg_log!("Unimplemented: 64-bit group3 op {}", op);
                    return false;
                },
            }
            true
        },

        // mov r/m, imm32 sign extended (0xC7) or imm8 (0xC6)
        0xC6 | 0xC7 => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            if modrm_byte >> 3 & 7 != 0 {
                return false;
            }
            if opcode == 0xC6 {
                let imm = match read_imm8() {
                    Ok(v) => v,
                    Err(()) => return true,
                };
                if modrm_byte >= 0xC0 {
                    write_reg8(modrm_rm(modrm_byte), imm);
                }
                else {
                    match resolve_modrm64(modrm_byte) {
                        Ok(addr) => {
                            let _ = safe_write8(addr, imm);
                        },
                        Err(()) => {},
                    }
                }
            }
            else {
                let imm = match read_imm32s() {
                    Ok(v) => v as i64,
                    Err(()) => return true,
                };
                let _ = write_rm(modrm_byte, sized(imm, wide), wide);
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
            let slot = if wide { 8 } else { 4 };

            let read_slot = |offset: i64| -> OrPageFault<i64> {
                let addr = truncate_address(rsp + offset)?;
                if wide {
                    Ok(safe_read64s(addr)? as i64)
                }
                else {
                    Ok(safe_read32s(addr)? as u32 as i64)
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

        // ret
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
            match resolve_modrm64(modrm_byte) {
                Ok(addr) => write_reg_sized(reg, addr as u32 as i64, wide),
                Err(()) => {},
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
                    Ok(addr) => match safe_read16(addr) {
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
unsafe fn run_0f(opcode: i32, wide: bool) -> bool {
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
            let src = match read_rm(modrm_byte, wide) {
                Ok(v) => v,
                Err(()) => return true,
            };
            // The destination is written either way: a cmov with a false condition still zero
            // extends a 32-bit destination
            let value = if test_condition(opcode & 0xF) { src } else { read_reg64(reg) };
            write_reg_sized(reg, value, wide);
            true
        },

        // movzx r, r/m8 and r/m16
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
            write_reg_sized(reg, value as i64, wide);
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
            write_reg_sized(reg, extended, wide);
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
            safe_read16(addr)
        }
        else {
            safe_read8(addr)
        }
    }
}

/// 0xFF group, which is where the 64-bit indirect call and jump live
pub unsafe fn run_ff(modrm_byte: i32) -> bool {
    match modrm_byte >> 3 & 7 {
        // call r/m64. Near calls default to a 64-bit operand size, rex.w or not
        2 => {
            let target = match read_rm(modrm_byte, true) {
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
            let target = match read_rm(modrm_byte, true) {
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
