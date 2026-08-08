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

use crate::cpu::cpu::*;
use crate::cpu::global_pointers::*;
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

/// Dispatch one instruction in 64-bit mode. `rex` has already been consumed. Returns false if the
/// opcode isn't implemented yet, in which case the caller reports it.
pub unsafe fn run(opcode: i32) -> bool {
    // rex.w wins over a 0x66 prefix, which otherwise selects a 16-bit operand size
    let wide = 0 != *rex & REX_W;
    let narrow = !wide && 0 != *prefixes & crate::prefix::PREFIX_66;

    match opcode {
        // sub r, r/m
        0x2B => {
            let modrm_byte = match read_imm8() {
                Ok(o) => o,
                Err(()) => return true,
            };
            let reg = modrm_reg(modrm_byte);
            let src = match read_rm(modrm_byte, wide) {
                Ok(v) => v,
                Err(()) => return true,
            };
            if wide {
                // 64-bit arithmetic needs the lazy flag machinery to gain a 64-bit operand size,
                // which it doesn't have. Refusing is better than leaving the flags stale and
                // sending every conditional branch after this the wrong way.
                dbg_log!("Unimplemented: 64-bit sub");
                return false;
            }
            let dst = read_reg64(reg) as i32;
            write_reg_sized(reg, crate::cpu::arith::sub32(dst, src as i32) as i64, false);
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
            true
        },

        _ => {
            let _ = narrow;
            false
        },
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
            true
        },

        _ => false,
    }
}
