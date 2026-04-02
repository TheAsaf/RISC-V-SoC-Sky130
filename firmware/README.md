# Firmware — Software for the rv32_soc CPU

The firmware runs on the PicoRV32 RISC-V core inside the SoC. It demonstrates every major hardware path: polled UART transmit, interrupt-driven receive, and the ring buffer that decouples the ISR from main().

---

## Quick Start

```bash
cd firmware

# Build (auto-detects GCC; falls back to Python if not found)
make

# Force Python path — no RISC-V toolchain required
make python

# Print full instruction listing
make verbose

# Verify the generated hex file
make check
```

The output is `firmware.hex`, a text file in Verilog `$readmemh` format (one 32-bit word per line). The testbench loads this file before simulation starts.

---

## File Map

| File | Purpose |
|---|---|
| `start.S` | Reset vector, IRQ entry, context save/restore, BSS zero, call main |
| `uart_drv.h` | All UART register definitions and inline driver functions |
| `main.c` | Demo program: boot banner, IRQ enable, echo loop |
| `link.ld` | Linker script placing code at 0x0, IRQ at 0x10, stack at 0x400 |
| `firmware.py` | Python encoder producing `firmware.hex` without any toolchain |
| `firmware.hex` | Pre-built firmware image (loaded by testbench via `$readmemh`) |
| `Makefile` | Orchestrates both build paths |

---

## Memory Layout

```
SRAM (1 KB = 0x000–0x3FF)
┌─────────────────────────────────────────────────────────┐
│ 0x000  Reset vector                                     │
│        JAL x0, _start   → jumps to 0x1C (or wherever   │
│                           _start lands after linking)   │
├─────────────────────────────────────────────────────────┤
│ 0x004  IRQ vector padding                               │
│ 0x008  NOP                                              │
│ 0x00C  NOP                                              │
├─────────────────────────────────────────────────────────┤
│ 0x010  _irq_entry  ← PROGADDR_IRQ (hardwired in CPU)   │
│        Save registers onto stack                        │
│        Call irq_handler()                               │
│        Restore registers                                │
│        retirq  (PicoRV32 custom instruction)            │
├─────────────────────────────────────────────────────────┤
│ 0x020  _start                                           │
│        Zero BSS                                         │
│        Call main()                                      │
│        maskirq x0, x0  (unmask interrupts)              │
│        Spin loop (main never returns)                   │
├─────────────────────────────────────────────────────────┤
│ ...    .text (main.c compiled code)                     │
│        .rodata (string literals)                        │
│        .data (initialised globals)                      │
├─────────────────────────────────────────────────────────┤
│ ...    .bss (zero-initialised globals)                  │
│        irq_rx_buf[16]                                   │
│        irq_rx_head, irq_rx_tail                         │
├─────────────────────────────────────────────────────────┤
│ 0x3FF  ← stack grows DOWN from here                    │
│         (STACKADDR = 0x400 in soc_top.v)                │
└─────────────────────────────────────────────────────────┘
```

The linker enforces a minimum 128 bytes of stack headroom. If firmware + data exceeds 896 bytes, the linker emits an error.

---

## `start.S` — Startup Assembly

### Why assembly for startup?

Three things cannot be expressed in standard C:
1. **Precise address layout** — the reset vector must be at exactly byte 0, and `_irq_entry` must land at exactly byte 16 (`PROGADDR_IRQ`). C compilers do not give this level of control.
2. **Context save/restore in the ISR** — the interrupt handler must save and restore CPU registers. The compiler does not know which registers to save for an interrupt handler using PicoRV32's custom calling convention.
3. **PicoRV32 custom instructions** — `retirq` and `maskirq` are not standard RISC-V instructions. They must be emitted as raw `.word` directives.

### IRQ entry convention

When PicoRV32 takes an interrupt (with `ENABLE_IRQ_QREGS=0`):
- `x3` (gp) ← return PC
- `x4` (tp) ← IRQ-pending bitmap

The ISR prologue saves all ABI caller-saved registers EXCEPT `x3` and `x4` (which hold the return information). The epilogue restores them, then executes `retirq` which jumps to `x3` and clears `irq_active`.

```asm
_irq_entry:
    addi sp, sp, -56     // allocate 14-register frame
    sw ra,  0(sp)
    sw a0,  4(sp)
    // ... save a1-a5, t0-t6 ...
    mv a0, tp            // pass IRQ-pending bitmap to C handler
    call irq_handler
    // ... restore all saved registers ...
    addi sp, sp, 56
    .word 0x0400000B     // retirq
```

### The `maskirq` requirement

PicoRV32 resets with `irq_mask = 0xFFFFFFFF` (all 32 IRQ lines masked). This is intentional — it prevents spurious interrupts from firing before firmware is ready. Firmware **must** execute `maskirq x0, x0` to clear the mask and enable interrupt delivery.

We place `maskirq` in `_start` after `call main` — meaning main() runs without interrupts, and only after main() completes (or never, since main() is an infinite loop) do we unmask. For the echo loop to work, `main()` itself calls `uart_irq_enable()` which includes the `maskirq` instruction at the right moment.

---

## `uart_drv.h` — UART Driver

All driver functions are `static inline` — no separate compilation unit, no function call overhead for simple register accesses.

### Register definitions

```c
#define UART_BASE   0x20000000UL

#define UART_TX     (*(volatile uint32_t *)(UART_BASE + 0x00))  // TX_DATA [W]
#define UART_RX     (*(volatile uint32_t *)(UART_BASE + 0x04))  // RX_DATA [R]
#define UART_STATUS (*(volatile uint32_t *)(UART_BASE + 0x08))  // STATUS [R/W1C]
#define UART_CTRL   (*(volatile uint32_t *)(UART_BASE + 0x0C))  // CTRL [RW]
```

The `volatile` qualifier is critical. Without it, the compiler could:
- Cache `UART_STATUS` in a register and never re-read from hardware
- Reorder `UART_TX` writes (they must happen in program order)
- Optimise away `UART_RX` reads (reading has a side effect: clears `rx_ready`)

### Backpressure handling

```c
static inline void uart_putc(uint8_t c) {
    while (UART_STATUS & STATUS_FIFO_FULL)  // spin if FIFO full
        ;
    UART_TX = c;
}
```

The TX FIFO is 8 deep. The CPU is ~4000× faster than the UART serializer at 50 MHz / 115200 baud. Without the `while(FIFO_FULL)` check, the 9th byte written would be silently discarded by hardware (the FIFO doesn't overflow — it just drops writes when full). This spin is the correct policy for a UART with no hardware stall.

### IRQ enable sequence

```c
static inline void uart_irq_enable(void) {
    UART_CTRL = CTRL_IRQ_EN;             // Set irq_en bit in UART peripheral
    __asm__ volatile (".word 0x0600000B" // maskirq x0, x0  → irq_mask = 0
                      ::: "memory");
}
```

Both steps are required. Setting `CTRL_IRQ_EN` tells the UART to assert `irq` when `rx_ready=1`. The `maskirq` instruction tells PicoRV32 to actually accept the interrupt. Doing only one of the two has no effect.

---

## `main.c` — Demo Program

```
Boot:    uart_puts("rv32_soc boot\r\n")         [polled TX]
         uart_irq_enable()                       [arms IRQ]
         uart_puts("waiting for rx...\r\n")

Loop:    wait for irq_rx_buf to be non-empty    [set by ISR]
         c = uart_irq_getc()                    [drain ring buffer]
         print_rx_byte(c)  → "rx: XX\r\n"       [polled TX]
         uart_putc(c)                           [raw echo]
```

### ISR → main() data flow

```
Hardware:    byte arrives on uart_rx pin
uart_rx.v:   decodes byte, pulses rx_valid
uart_top.v:  sets rx_ready=1, asserts irq
PicoRV32:    detects irq[0], saves PC→x3, jumps to 0x10

start.S:     saves registers, calls irq_handler(pending)
irq_handler: byte = UART_RX  ← reads and clears rx_ready → irq deasserts
             irq_rx_buf[irq_rx_head % 16] = byte
             irq_rx_head++
start.S:     restores registers, retirq → resumes main()

main():      uart_irq_available() → irq_rx_head != irq_rx_tail  → true
             c = irq_rx_getc()   → reads buf[irq_rx_tail], tail++
             print_rx_byte(c)
```

The ring buffer provides **temporal decoupling**: the ISR fires at a hardware-determined time and deposits bytes asynchronously. main() drains them at its own pace. As long as main() drains faster than bytes arrive on average, no bytes are lost.

---

## `firmware.py` — Python Encoder

Produces `firmware.hex` without requiring a RISC-V cross-compiler. Useful when:
- Running in CI/CD with no toolchain installed
- Demonstrating the project to someone who just wants to simulate

The encoder implements the RV32I instruction format for every instruction used in the firmware, plus the PicoRV32 custom instructions (`retirq`, `maskirq`). Each instruction encoding is documented inline and matches the RISC-V specification exactly.

```bash
python3 firmware.py --verbose --out firmware.hex
```

Output (abbreviated):
```
=== Firmware image ===
  Addr        Word  Mnemonic
0x0000  0x01C0006F  JAL x0, _start (0x1C)
0x0004  0x00000013  NOP (IRQ pad)
...
0x0010  0x200000B7  LUI x1, 0x20000  (UART base)
0x0014  0x0040A583  LW  x11, 4(x1)  (read RX_DATA)
0x0018  0x0400000B  retirq
...
Total: 16 words (64 bytes), 960 bytes available for stack
self-check: PASS
```

---

## Building with the RISC-V GCC Toolchain

If `riscv32-unknown-elf-gcc` or `riscv64-unknown-elf-gcc` is installed, `make` will use it automatically:

```bash
# macOS — install via Homebrew
brew tap riscv-software-src/riscv
brew install riscv-gnu-toolchain

# Ubuntu/Debian
sudo apt install gcc-riscv64-unknown-elf

# Verify
riscv64-unknown-elf-gcc --version
```

The compiler flags used:
```makefile
-march=rv32i        # RV32I only — matches the CPU configuration
-mabi=ilp32         # 32-bit int/long/ptr, no FP ABI
-Os                 # optimise for size (1 KB SRAM)
-ffreestanding      # no stdlib assumptions
-nostdlib           # no standard startup files or libraries
-fno-builtin        # no built-in memcpy/memset substitutions
```

The resulting ELF is converted to a Verilog `$readmemh` hex file by the Makefile. The GCC and Python paths produce functionally equivalent firmware (same observable UART output and IRQ behaviour), though the exact instruction sequences may differ.
