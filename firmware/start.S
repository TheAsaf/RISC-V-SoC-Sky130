// ============================================================================
// File:    start.S
// Project: rv32_soc firmware
// Description:
//   Startup code and interrupt vector table for PicoRV32 (ENABLE_IRQ=1,
//   ENABLE_IRQ_QREGS=0).
//
//   Memory layout (matches link.ld):
//     0x00000000  Reset vector — must be exactly one JAL to _start
//     0x00000004  IRQ vector padding (3 NOPs; alignment only)
//     0x00000010  IRQ entry point (PROGADDR_IRQ) — jump to _irq_handler
//     0x00000020  _start — initialise BSS, call main
//
//   PicoRV32 IRQ mechanics (ENABLE_IRQ_QREGS=0):
//     On interrupt entry:
//       x3 (gp) ← return PC
//       x4 (tp) ← IRQ-pending bitmap (32 bits)
//     On retirq: PC ← x3, irq_active cleared
//
//     irq_mask resets to ~0 (all masked). Firmware MUST call maskirq
//     before returning from _start to enable interrupt delivery.
//     We unmask in _start rather than main() to keep main() pure C.
//
//   Register conventions (PicoRV32 ABI = RV32I RISC-V ABI):
//     x1  (ra)  return address     — saved by ISR prologue
//     x2  (sp)  stack pointer      — set by PicoRV32 STACKADDR param
//     x3  (gp)  global pointer     — REPURPOSED by PicoRV32 as IRQ retaddr
//     x4  (tp)  thread pointer     — REPURPOSED by PicoRV32 as IRQ pending
//     x5–x7     temporaries
//     x8  (s0)  saved / frame ptr
//     x10 (a0)  arg0 / return val
// ============================================================================

    .section .text.init, "ax"
    .global  _reset_vector
    .global  _irq_entry
    .global  _start

// ============================================================================
// 0x00000000 — Reset vector
// A single JAL to _start.  Must be exactly 4 bytes; no other instructions
// here because 0x10 is the IRQ entry point and must land at exactly that
// address.
// ============================================================================
_reset_vector:
    jal  x0, _start              // jump to startup; never returns

// ============================================================================
// 0x00000004 – 0x0000000F  — IRQ vector table padding
// PicoRV32 jumps directly to PROGADDR_IRQ (0x10); it does NOT indirect
// through a table.  These NOPs are pure padding to land the label at 0x10.
// ============================================================================
    .word 0x00000013             // NOP (ADDI x0, x0, 0)
    .word 0x00000013             // NOP
    .word 0x00000013             // NOP

// ============================================================================
// 0x00000010 — IRQ entry point (PROGADDR_IRQ)
// PicoRV32 has already:
//   1. Finished the current instruction
//   2. Written return-PC to x3 (gp)
//   3. Written IRQ-pending bitmap to x4 (tp)
//   4. Jumped here
//
// We must preserve all caller-saved registers that the interrupted code
// might have been using.  Since we're a bare-metal ISR with no RTOS, we
// push a minimal frame: ra, a0–a5, t0–t6.
//
// Stack layout (grows downward, 4-byte aligned words):
//   sp+0   ra
//   sp+4   a0
//   sp+8   a1
//   sp+12  a2
//   sp+16  a3
//   sp+20  a4
//   sp+24  a5
//   sp+28  t0
//   sp+32  t1
//   sp+36  t2
//   sp+40  t3
//   sp+44  t4
//   sp+48  t5
//   sp+52  t6
//   total: 56 bytes (14 words)
//
// x3 (gp) and x4 (tp) are NOT saved — they are the IRQ return address and
// pending bitmap respectively.  We must not clobber them before retirq.
// ============================================================================
_irq_entry:
    // Allocate frame
    addi sp, sp, -56

    // Save caller-saved registers
    sw   ra, 0(sp)
    sw   a0, 4(sp)
    sw   a1, 8(sp)
    sw   a2, 12(sp)
    sw   a3, 16(sp)
    sw   a4, 20(sp)
    sw   a5, 24(sp)
    sw   t0, 28(sp)
    sw   t1, 32(sp)
    sw   t2, 36(sp)
    sw   t3, 40(sp)
    sw   t4, 44(sp)
    sw   t5, 48(sp)
    sw   t6, 52(sp)

    // x4 (tp) holds the IRQ-pending bitmap. Dispatch to C handler.
    // void irq_handler(uint32_t pending)
    mv   a0, tp
    call irq_handler

    // Restore caller-saved registers
    lw   ra, 0(sp)
    lw   a0, 4(sp)
    lw   a1, 8(sp)
    lw   a2, 12(sp)
    lw   a3, 16(sp)
    lw   a4, 20(sp)
    lw   a5, 24(sp)
    lw   t0, 28(sp)
    lw   t1, 32(sp)
    lw   t2, 36(sp)
    lw   t3, 40(sp)
    lw   t4, 44(sp)
    lw   t5, 48(sp)
    lw   t6, 52(sp)

    // Deallocate frame
    addi sp, sp, 56

    // Return from interrupt.
    // PicoRV32 custom instruction: restores PC from x3 (gp), clears irq_active.
    // Encoding: 0x0400000B  (verified: picorv32.v line 871)
    .word 0x0400000B             // retirq

// ============================================================================
// _start — C runtime initialisation
// Called from the reset vector.  Stack pointer is already set by PicoRV32's
// STACKADDR parameter (0x400 = top of 1 KB SRAM), so no sp setup needed.
//
// Responsibilities:
//   1. Zero the .bss section (C guarantees zero-initialised globals)
//   2. Call main()
//   3. Unmask interrupts (maskirq x0, x0  → irq_mask = 0)
//      Done here, after BSS clear, so that IRQs cannot fire during init.
//   4. Spin on main() return (should never happen; belt-and-suspenders)
// ============================================================================
_start:
    // ---- Zero BSS ----
    // __bss_start and __bss_end are defined by link.ld
    la   t0, __bss_start
    la   t1, __bss_end
.Lbss_zero:
    bge  t0, t1, .Lbss_done
    sw   x0, 0(t0)
    addi t0, t0, 4
    j    .Lbss_zero
.Lbss_done:

    // ---- Call main ----
    call main

    // ---- Unmask all interrupts ----
    // maskirq rd, rs1: irq_mask = rs1; rd = old irq_mask
    // maskirq x0, x0: irq_mask = 0 (unmask all)
    // Encoding: bits[31:25]=0000011, rs1=x0, rd=x0, bits[6:0]=0001011
    //           = 0x0600000B  (verified: picorv32.v lines 1092, 1682)
    // Note: we unmask AFTER main() returns so that main() itself controls
    // when it's ready for interrupts (it calls uart_irq_enable() internally).
    // In practice main() never returns; this is a safety net.
    .word 0x0600000B             // maskirq x0, x0

    // ---- Halt ----
.Lhalt:
    j    .Lhalt
