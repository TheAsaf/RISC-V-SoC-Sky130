/* ============================================================================
 * link.ld — Linker script for rv32_soc firmware
 * Target: PicoRV32, 1 KB SRAM at 0x00000000
 *
 * Memory layout:
 *   0x00000000  SRAM base — reset vector (JAL to _start)
 *   0x00000010  PROGADDR_IRQ — IRQ entry point (_irq_entry)
 *   0x00000020  _start — C runtime init, then main()
 *   ...         .text  — code
 *   ...         .rodata — read-only data (string literals, const tables)
 *   ...         .data  — initialised globals (copied from LMA if XIP)
 *   ...         .bss   — zero-initialised globals (zeroed by _start)
 *   0x000003FF  Top of SRAM — stack grows down from here
 *               (STACKADDR = 0x400 set in soc_top.v)
 *
 * Since we have a single flat SRAM (no separate ROM/RAM), LMA == VMA for all
 * sections.  The "load address" and "run address" are the same.
 *
 * Constraints:
 *   - Total firmware + data + BSS must fit within 1 KB (0x400 bytes).
 *   - The stack grows downward from 0x400; the linker does not enforce this
 *     automatically, but the sizing check at the bottom will flag overflows.
 *   - .text.init must be placed first (contains the reset vector at 0x0 and
 *     the IRQ entry at 0x10) — enforced by the explicit section name.
 * ============================================================================ */

OUTPUT_ARCH(riscv)
ENTRY(_reset_vector)

MEMORY {
    SRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 1K
}

SECTIONS {

    /* ------------------------------------------------------------------ */
    /* .text — executable code                                             */
    /* .text.init MUST come first: it contains the reset vector at 0x0.   */
    /* ------------------------------------------------------------------ */
    .text : {
        . = ALIGN(4);
        KEEP(*(.text.init))         /* start.S: reset vector + IRQ entry */
        *(.text .text.*)            /* all other code */
        . = ALIGN(4);
    } > SRAM

    /* ------------------------------------------------------------------ */
    /* .rodata — read-only data (string literals, const arrays)           */
    /* Placed immediately after .text; accessed via PC-relative or        */
    /* absolute addressing.                                                */
    /* ------------------------------------------------------------------ */
    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.*)
        . = ALIGN(4);
    } > SRAM

    /* ------------------------------------------------------------------ */
    /* .data — initialised global and static variables                    */
    /* For this single-memory system, LMA == VMA (no copy needed).        */
    /* ------------------------------------------------------------------ */
    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        . = ALIGN(4);
    } > SRAM

    /* ------------------------------------------------------------------ */
    /* .bss — zero-initialised globals and statics                        */
    /* _start zeroes this region before calling main().                   */
    /* ------------------------------------------------------------------ */
    .bss : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > SRAM

    /* ------------------------------------------------------------------ */
    /* Size check                                                          */
    /* Stack occupies from __bss_end up to STACKADDR (0x400).             */
    /* Minimum useful stack = 128 bytes.                                   */
    /* ------------------------------------------------------------------ */
    __firmware_end = .;
    ASSERT(__firmware_end <= (0x400 - 128),
        "ERROR: firmware too large — less than 128 bytes of stack remaining in 1 KB SRAM")

    /* ------------------------------------------------------------------ */
    /* Discard debug/unwinding sections to save space                     */
    /* ------------------------------------------------------------------ */
    /DISCARD/ : {
        *(.comment)
        *(.riscv.attributes)
        *(.eh_frame)
        *(.note.*)
    }
}
