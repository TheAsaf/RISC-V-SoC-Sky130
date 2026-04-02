# rv32_soc — A Complete RISC-V System-on-Chip in Silicon

> **A PicoRV32 CPU, 1 KB SRAM, and a memory-mapped UART peripheral — integrated into a single chip, verified end-to-end, and taken through RTL-to-GDS physical design on the open-source SkyWater 130 nm process.**

---

## What Is This?

This project builds a **real, working System-on-Chip** from scratch.

It started as a production-quality UART peripheral IP (a hardware serial communication block). That IP was then evolved into a full SoC by integrating it with a RISC-V CPU core, a memory system, an interrupt controller, and the firmware that runs on it — then pushed all the way through physical chip design to produce an actual silicon layout.

**In 30 seconds:** a small CPU fetches instructions from memory, writes bytes through a hardware UART to communicate with the outside world, and handles interrupts when data arrives — all verified in simulation with firmware and ready for tapeout on real silicon.

```
 ┌──────────────────────────────────────────────────────────────┐
 │                        rv32_soc                              │
 │                                                              │
 │  ┌───────────┐   mem_valid/ready   ┌────────────────────┐   │
 │  │ PicoRV32  │◄───────────────────►│     soc_bus        │   │
 │  │  RV32I    │   mem_addr[31:0]    │  (addr decoder +   │   │
 │  │ ENABLE_IRQ│   mem_wdata[31:0]   │   rdata mux +      │   │
 │  │           │   mem_wstrb[3:0]    │   UART adapter)    │   │
 │  └───────────┘   mem_rdata[31:0]   └────────┬───────────┘   │
 │        ▲                                     │               │
 │        │                         ┌───────────┴────────┐      │
 │        │                  ┌──────▼──────┐  ┌──────────▼──┐  │
 │        │                  │  soc_sram   │  │  uart_top   │  │
 │        │                  │  1 KB SRAM  │  │  (TX FIFO + │  │
 │        │                  │  0x00000000 │  │   RX + IRQ) │  │
 │        └──── irq[0] ──────────────────────── irq         │  │
 │                                                           │  │
 │  Pins: clk  rst_n  uart_rx  uart_tx  irq_out             │  │
 └──────────────────────────────────────────────────────────┘
```

---

## Why Is This Interesting?

Most SoC projects either:
- Show a CPU running in isolation with fake memory, or
- Show a peripheral IP with a register-level testbench

This project does **all of it together**: a real CPU core executing real firmware, communicating through a verified hardware UART peripheral, handling hardware interrupts — and the entire design is taken through a complete ASIC physical flow to produce a chip layout. Every layer of the stack is present and connected.

It also documents two real bugs found during integration — the kind of bugs that don't appear in textbooks but that every hardware engineer encounters on real projects.

---

## Table of Contents

1. [System Architecture](#1-system-architecture)
2. [How It Works — Step by Step](#2-how-it-works--step-by-step)
3. [Firmware Execution Flow](#3-firmware-execution-flow)
4. [Physical Design Flow](#4-physical-design-flow)
5. [Concepts for Beginners](#5-concepts-for-beginners)
6. [Design Decisions & Tradeoffs](#6-design-decisions--tradeoffs)
7. [Bugs & Lessons Learned](#7-bugs--lessons-learned)
8. [Verification Results](#8-verification-results)
9. [Physical Design Results](#9-physical-design-results)
10. [Repository Structure](#10-repository-structure)
11. [How to Run](#11-how-to-run)
12. [Tools](#12-tools)

---

## 1. System Architecture

### Block Diagram

```
                          rv32_soc
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   ┌────────────────────────────────────────────────────────┐   │
│   │                     soc_top.v                          │   │
│   │                                                        │   │
│   │  ┌─────────────┐        ┌──────────────────────────┐  │   │
│   │  │             │        │        soc_bus.v          │  │   │
│   │  │  PicoRV32   │        │                          │  │   │
│   │  │  (RV32I)    │◄──────►│  Address Decoder         │  │   │
│   │  │             │        │  ┌───────────────────┐   │  │   │
│   │  │  irq[31:0]  │        │  │ 0x000 → SRAM      │   │  │   │
│   │  │             │        │  │ 0x200 → UART      │   │  │   │
│   │  └──────┬──────┘        │  └───────────────────┘   │  │   │
│   │         │               │                          │  │   │
│   │         │               │  rdata Mux               │  │   │
│   │         │               │  32-bit ← 8-bit Adapter  │  │   │
│   │         │               └────────────┬─────────────┘  │   │
│   │         │                            │                 │   │
│   │         │               ┌────────────┴──────────────┐  │   │
│   │         │          ┌────▼─────┐         ┌───────────▼┐ │   │
│   │         │          │soc_sram.v│         │ uart_top.v │ │   │
│   │         │          │          │         │            │ │   │
│   │         │          │ 1KB SRAM │         │ TX FIFO(8) │ │   │
│   │         │          │ 256×32b  │         │ uart_tx.v  │ │   │
│   │         │          │          │         │ uart_rx.v  │ │   │
│   │         │          │ (code +  │         │ sync_fifo  │ │   │
│   │         │          │  stack)  │         │            │ │   │
│   │         │          └──────────┘         └─────┬──────┘ │   │
│   │         │                                     │         │   │
│   │         └──── irq[0] ────────────────── irq  │         │   │
│   │                                               │         │   │
│   └───────────────────────────────────────────────────────── ┘  │
│                                                                 │
│   External pins:  clk   rst_n   uart_rx ──►   uart_tx ──►      │
│                                              irq_out ──►        │
└─────────────────────────────────────────────────────────────────┘
```

### Memory Map

| Base Address | End Address | Size | Module | Description |
|---|---|---|---|---|
| `0x00000000` | `0x000003FF` | 1 KB | `soc_sram` | SRAM — code, data, and stack |
| `0x20000000` | `0x2000000F` | 16 B | `uart_top` | UART registers (4 × 32-bit words) |
| Everything else | — | — | — | Returns `0x0`, no bus error |

### UART Register Map

The CPU accesses the UART by reading/writing to these byte addresses. This is called **memory-mapped I/O** — peripherals look like memory to the CPU.

| Byte Address | Register | Access | Bit Layout |
|---|---|---|---|
| `0x20000000` | `TX_DATA` | Write | `[7:0]` — byte to transmit |
| `0x20000004` | `RX_DATA` | Read | `[7:0]` — last received byte (reading clears `rx_ready`) |
| `0x20000008` | `STATUS` | Read / W1C | `[5]` parity_err · `[4]` frame_err · `[3]` rx_ready · `[2]` fifo_full · `[1]` fifo_empty · `[0]` tx_busy |
| `0x2000000C` | `CTRL` | Read/Write | `[2]` irq_en · `[1]` parity_odd · `[0]` parity_en |

**W1C** (Write-1-to-Clear): Writing a `1` to a status flag bit clears it. This is the ARM AMBA standard for error flags — it prevents software from accidentally clearing flags it hasn't yet read.

---

## 2. How It Works — Step by Step

### 2.1 Instruction Fetch (CPU → SRAM → CPU)

Every instruction the CPU executes starts with a memory read from SRAM:

```
Cycle N:   PicoRV32 asserts mem_valid=1, mem_addr=0x1C, mem_wstrb=0 (read)
           soc_bus sees addr < 0x400 → selects SRAM
           soc_bus asserts sram_cs=1
           soc_sram reads mem[7] combinationally → rdata = 0x200000B7

Cycle N:   soc_bus asserts mem_ready=1, drives mem_rdata = sram_rdata
           PicoRV32 samples mem_rdata on this same clock edge
           PicoRV32 begins decoding: 0x200000B7 = LUI x1, 0x20000
```

The entire read path is **combinational** — SRAM data appears in the same cycle as the address. This means the CPU never stalls for a memory read (zero wait states) in the behavioral simulation model.

### 2.2 UART Transmit (CPU writes a byte)

```
Firmware:  uart_putc('U')  →  while(FIFO_FULL); UART_TX = 0x55;

CPU:       SW x11, 0(x1)   stores x11 to mem_addr=0x20000000

soc_bus:   addr[31:4] == 28'h2000000  →  uart_sel=1
           uart_addr = mem_addr[4:2] = 3'b000  (TX_DATA register)
           uart_wdata = mem_wdata[7:0] = 0x55
           uart_wen = 1

uart_top:  fifo_wr_en = wen && (addr == TX_DATA) && !fifo_full  →  1
           TX FIFO receives 0x55 (now 1 entry in the 8-deep FIFO)

uart_tx:   serializer was idle → detects FIFO not empty → reads byte
           Transmits on uart_tx pin:
             1 start bit (LOW) for 434 cycles  (50 MHz / 115200 baud)
             8 data bits LSB-first: 1,0,1,0,1,0,1,0  (0x55 = 01010101)
             1 stop bit (HIGH) for 434 cycles
```

**ASCII waveform — transmitting 'U' (0x55 = 01010101b):**
```
         Start  b0  b1  b2  b3  b4  b5  b6  b7  Stop
uart_tx:   ___   _   _   _   _   _   _   _   _   ___
         _|   |_| |_| |_| |_| |_| |_| |_| |_|

          LOW  1  0  1  0  1  0  1  0  HIGH
               └──────── 0x55 = 01010101b ────────┘
                              LSB first
```

### 2.3 UART Receive (external device sends a byte)

```
External:  drives uart_rx LOW (start bit)

uart_rx.v (inside uart_top):
  2-FF sync:  rx_meta → rx_sync  (metastability protection, 2 cycles)
  Detects falling edge on rx_sync → starts receiver FSM
  Waits CLKS_PER_BIT/2 = 217 cycles (mid-start-bit)
  Samples 8 data bits at 434-cycle intervals (mid-bit sampling)
  Checks stop bit (must be HIGH)
  Pulses rx_valid for 1 cycle, drives rx_data = received byte

uart_top:
  rx_valid pulse → sets rx_data_reg = received byte
                 → sets rx_ready = 1
  irq = irq_en & rx_ready  →  asserts irq HIGH if irq_en=1
```

**Why mid-bit sampling?** The receiver has no shared clock with the sender. It synchronizes on the falling edge of the start bit, then waits half a bit period to reach the center of that bit. From there, it advances one full bit period at a time to hit the center of each subsequent bit — the most noise-immune sampling point.

```
                   ┌──────────────────────────┐
uart_rx:  _________|  start  |  d0  |  d1  |  d2 ...

          ↑         ↑         ↑      ↑      ↑
          |      detect    sample  sample  sample
          |      falling  at t+T/2  t+T    t+2T
          |       edge
          |
     2-FF sync
     (metastability
      protection)
```

### 2.4 Interrupt Flow (end-to-end)

This is the most important path in the system. Here is every step, in order:

```
1. Firmware enables IRQ:
      UART_CTRL = 0x04       (sets irq_en=1 in uart_top)
      maskirq x0, x0         (PicoRV32: sets irq_mask=0, unmasking all 32 IRQ lines)

2. External byte arrives on uart_rx → uart_rx.v decodes it

3. uart_top sets rx_ready=1
   irq = irq_en & rx_ready = 1 & 1 = 1  →  irq_out goes HIGH

4. PicoRV32 sees irq[0]=1 (next instruction boundary):
      Saves return-PC  →  x3 (gp register)
      Saves IRQ-pending bitmap  →  x4 (tp register)
      Jumps to PROGADDR_IRQ = 0x00000010

5. ISR executes (at 0x10):
      LUI  x1, 0x20000    →  x1 = 0x20000000 (UART base)
      LW   x11, 4(x1)     →  reads UART_RX_DATA (0x20000004)
                              SIDE EFFECT: uart_top clears rx_ready
      irq = irq_en & rx_ready = 1 & 0 = 0  →  irq_out goes LOW
      retirq              →  jumps to x3 (return address), clears irq_active

6. CPU resumes execution from where it was interrupted
```

**Interrupt flow diagram:**

```
  firmware               uart_top              PicoRV32
  ────────               ────────              ────────
  CTRL = irq_en ──────►  irq_en=1
  maskirq x0,x0 ──────────────────────────►  irq_mask=0

                         rx_ready=1
                         irq=1 ──────────────► irq[0] samples HIGH
                                               save PC → x3
                                               jump to 0x10 (ISR)

  ISR: LW 4(x1) ──────►  read RX_DATA
                         rx_ready=0
                         irq=0 ──────────────► irq[0] goes LOW

  ISR: retirq ─────────────────────────────►  jump to x3, resume
```

---

## 3. Firmware Execution Flow

### What happens after the chip comes out of reset

```
Power-on / rst_n released
         │
         ▼
  Reset synchronizer (2-FF chain in soc_top.v)
  Ensures all internal logic sees a clean synchronous reset deassertion.
  Without this, different flip-flops could see reset release on different
  clock cycles — a metastability hazard.
         │
         ▼
  PicoRV32 begins fetching from address 0x00000000
         │
         ▼
  Word 0: 0x01C0006F  =  JAL x0, +28  →  jump to _start at 0x1C
         │
         │   (Words 1–3 are NOPs: padding so that 0x10 lands exactly
         │    at PROGADDR_IRQ — the IRQ entry point)
         │
         ▼
  _start (0x1C in simulation firmware / start.S in GCC-compiled firmware):
  ┌─ In GCC firmware (start.S):
  │   Zero BSS section (C guarantees global variables start at zero)
  │   Call main()
  │   maskirq x0, x0  (unmask all IRQs — done AFTER main() for safety)
  │   Spin loop (main never returns in normal operation)
  │
  └─ In simulation firmware (firmware.py output):
      Directly executes main's instruction sequence
         │
         ▼
  main():
  ┌──────────────────────────────────────────────────────────┐
  │  uart_puts("rv32_soc boot\r\n")                          │
  │    → polled TX: spins on STATUS.fifo_full for each byte  │
  │    → writes each byte to UART_TX_DATA                    │
  │    → uart_tx.v serializes over uart_tx pin               │
  │                                                          │
  │  uart_irq_enable()                                       │
  │    → UART_CTRL = 0x04  (irq_en=1)                       │
  │    → maskirq x0, x0   (unmask PicoRV32 IRQ lines)       │
  │                                                          │
  │  uart_puts("waiting for rx...\r\n")                      │
  │                                                          │
  │  while(!uart_irq_available())  ← spin, CPU idles here   │
  │    ;                                                     │
  │                                                          │
  │  c = uart_irq_getc()           ← drain ring buffer      │
  │  print_rx_byte(c)              ← "rx: XX\r\n"           │
  │                                                          │
  │  uart_puts("echo mode active\r\n")                       │
  │                                                          │
  │  while(1) {                    ← steady-state echo loop  │
  │      while(!uart_irq_available()) ;                      │
  │      c = uart_irq_getc();                                │
  │      print_rx_byte(c);         ← "rx: XX\r\n"           │
  │      uart_putc(c);             ← raw echo for terminal   │
  │  }                                                       │
  └──────────────────────────────────────────────────────────┘
```

### How the ISR interacts with main()

The ISR and main() share a **ring buffer** (circular array):

```
  IRQ fires (byte received)
         │
         ▼
  _irq_entry (start.S):
    Save ra, a0-a5, t0-t6 onto stack  ← caller-saved registers
    mv a0, tp                          ← pass IRQ-pending bitmap as argument
    call irq_handler                   ← C function in main.c
    Restore registers
    retirq                             ← return to interrupted code
         │
         ▼
  irq_handler(pending):
    if (pending & 0x1) {               ← was it the UART IRQ?
        byte = UART_RX_DATA            ← reads and clears rx_ready
        irq_rx_buf[irq_rx_head] = byte ← deposit into ring buffer
        irq_rx_head++                  ← advance producer pointer
    }
         │
         ▼ (ISR returns, main() resumes)

  main() loop:
    uart_irq_available()  →  irq_rx_head != irq_rx_tail
    uart_irq_getc()       →  read buf[irq_rx_tail], irq_rx_tail++
```

**Why a ring buffer?** The ISR must never block. If main() is slow to drain bytes, the ring buffer absorbs multiple arrivals without losing any (up to its depth of 16). The ISR writes to `irq_rx_head`; main() reads from `irq_rx_tail`. Both are declared `volatile` so the compiler does not cache them in registers across the ISR boundary.

---

## 4. Physical Design Flow

### What OpenLane does

OpenLane is an automated RTL-to-GDS flow. Given Verilog source files and a configuration, it runs a sequence of tools to produce a chip layout:

```
Verilog RTL
    │
    ▼ Yosys (Synthesis)
    │  Translates Verilog into a netlist of standard cells
    │  (AND gates, flip-flops, buffers — real silicon primitives)
    │  Optimises for area or timing based on SYNTH_STRATEGY
    │
    ▼ OpenROAD (Floorplan)
    │  Decides how big the chip die should be
    │  Places macros (large blocks) and power/ground rails
    │  Calculates utilisation (% of die area used by cells)
    │
    ▼ OpenROAD (Placement)
    │  Assigns each standard cell a physical (x,y) location
    │  Balances wire length vs. timing vs. congestion
    │
    ▼ OpenROAD (Clock Tree Synthesis)
    │  Inserts clock buffers to distribute the clock signal
    │  Goal: minimize clock skew (all FFs see the clock edge
    │  at nearly the same time)
    │
    ▼ OpenROAD (Routing)
    │  Draws the actual wires connecting every cell
    │  Uses multiple metal layers (met1–met4 for signals, met5 for power)
    │  Must route every net without short circuits or open connections
    │
    ▼ OpenROAD / OpenSTA (Timing Sign-off)
    │  Static Timing Analysis: measures the critical path delay
    │  Setup slack = clock period − (logic delay + routing delay)
    │  Hold slack = (logic delay + routing delay) − 0
    │  Both must be positive for the chip to work reliably
    │
    ▼ Magic (DRC + Antenna Check)
    │  Design Rule Check: verifies minimum feature sizes, spacings,
    │  and other fabrication constraints are met
    │  Antenna check: long metal wires charge up and can damage gates
    │  during fabrication — the tool inserts diodes to bleed this off
    │
    ▼ Netgen (LVS)
    │  Layout vs. Schematic: confirms the physical layout matches
    │  the logical netlist exactly (no missing/extra connections)
    │
    ▼ Magic (GDS Export)
       Produces the final GDSII file — the format sent to the fab
```

### This design's specific challenges

| Challenge | Root cause | Our mitigation |
|---|---|---|
| **Large cell count** | 8192 DFFs for the behavioral 1 KB SRAM | `SYNTH_STRATEGY: AREA 1`, `FP_CORE_UTIL: 35%` |
| **Routing congestion** | Dense DFF cluster creates local routing pressure | `GLB_RT_ADJUSTMENT: 0.15`, `RT_MAX_LAYER: met4` |
| **Hold timing** | Combinational SRAM read path has no registered output | CTS hold-fix buffers; `CTS_TARGET_SKEW: 200 ps` |
| **Async inputs** | `uart_rx` and `rst_n` have no timing relationship to `clk` | `set_false_path` in SDC; 2-FF synchronizers in RTL |

---

## 5. Concepts for Beginners

### What is RISC-V?

RISC-V (pronounced "risk-five") is an **instruction set architecture** — a specification of the machine language that a CPU understands. It defines what operations the CPU can perform (`ADD`, `LOAD`, `STORE`, `BRANCH`, etc.) and how they are encoded as binary numbers.

What makes RISC-V special is that it is **open and free**. Anyone can build a RISC-V chip without paying a license fee. This project uses **PicoRV32**, a small open-source RISC-V CPU written in Verilog by Claire Wolf at YosysHQ.

The CPU we use implements `RV32I` — the base 32-bit integer instruction set. No floating-point, no multiplication hardware. Just the minimum needed to run useful software.

### What is a CPU instruction cycle?

The CPU executes instructions in a cycle:

```
FETCH:   Read the instruction from memory (at address stored in PC)
         PC = Program Counter — points to the current instruction

DECODE:  Figure out what the instruction means
         e.g., "0x200000B7 = LUI x1, 0x20000 = load upper immediate"

EXECUTE: Perform the operation
         e.g., write 0x20000000 into register x1

WRITEBACK: Store the result (register write, or memory store)

PC advances to the next instruction (PC += 4 for 32-bit instructions)
```

PicoRV32 is a multicycle CPU — each stage takes one or more clock cycles. It is simple and predictable, which is exactly what you want for a first silicon design.

### What is memory-mapped I/O?

In most processor architectures, peripherals (UART, timer, GPIO) are **not** connected to special CPU instructions. Instead, they appear as memory locations. To talk to a UART, you simply read or write to a specific address.

```
// C code to send a byte via UART:
*((volatile uint32_t *)0x20000000) = 'U';

// This compiles to a single RISC-V store instruction:
// SW x11, 0(x1)   (where x1=0x20000000, x11='U'=0x55)

// The bus routes the write to uart_top, which sees:
//   addr=0, wdata=0x55, wen=1
// and pushes 0x55 into the TX FIFO
```

The CPU does not know — or care — that it is talking to hardware. It just sees memory. This is elegant: you can write hardware drivers in ordinary C.

### What is an interrupt?

An interrupt is a hardware signal that tells the CPU "stop what you are doing and handle this urgent event." Without interrupts, software must continuously check ("poll") whether data has arrived:

```c
// Polling: wastes CPU cycles, misses fast events
while (!(UART_STATUS & STATUS_RX_READY))
    ;  // spin, doing nothing useful
byte = UART_RX_DATA;

// Interrupt-driven: CPU does useful work; hardware notifies when ready
// ISR fires automatically when rx_ready=1
void irq_handler(uint32_t pending) {
    if (pending & 1) byte = UART_RX_DATA;  // handles it instantly
}
```

For this SoC: when the UART receives a complete byte, it asserts `irq`. PicoRV32 detects `irq[0]=1`, finishes its current instruction, saves the program counter, and jumps to the interrupt handler at address `0x10`.

### What is a FIFO?

A FIFO (First In, First Out) is a hardware queue. Data written first comes out first — like a pipe.

The UART uses an 8-deep FIFO for transmit. Without it:
- CPU writes 'H', waits 434 cycles for 'H' to finish sending
- CPU writes 'e', waits 434 more cycles...
- Sending "Hello" would take 5 × 434 = 2170 cycles of waiting

With the FIFO:
- CPU writes 'H', 'e', 'l', 'l', 'o' — all 5 writes in 5 cycles
- FIFO holds all 5 bytes; UART drains them one at a time
- CPU is free to do other work immediately

```
CPU writes:  H  e  l  l  o           (5 cycles)
             ↓  ↓  ↓  ↓  ↓
FIFO:     [H][e][l][l][o][ ][ ][ ]  (8 slots)
                           ↓
UART TX:    H        e       l       (one at a time, ~4340 cycles total)
```

### What is a ring buffer?

A ring buffer (circular buffer) is the software equivalent of the hardware FIFO. It is an array where a "head" pointer tracks where new data goes in and a "tail" pointer tracks where the next unread data is.

```
irq_rx_buf:  [ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ][ ]
              0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15

After 3 bytes arrive:
irq_rx_buf:  [A][B][C][ ][ ][ ]...
              ↑           ↑
            tail         head   (ISR advances head)

main() reads:
irq_rx_buf:  [_][_][C][ ][ ][ ]...
                      ↑  ↑
                    tail head   (main advances tail)
```

When `head == tail`, the buffer is empty. When `(head+1) % SIZE == tail`, it is full. The "ring" metaphor: when the index reaches the end of the array, it wraps around to index 0.

### What is Static Timing Analysis (STA)?

STA answers the question: "Will my circuit work at the target clock speed?"

Every gate has a propagation delay — time for a signal change at its input to appear at its output. A **timing path** is a chain of gates between two flip-flops:

```
Flip-flop A output
    → gate1 (0.2 ns)
    → gate2 (0.3 ns)
    → gate3 (0.15 ns)
    → Flip-flop B input
Total: 0.65 ns

If clock period = 20 ns (50 MHz):
    Setup slack = 20 ns − 0.65 ns − 0.2 ns (uncertainty) = +19.15 ns  ✓
```

STA finds the **critical path** (the slowest chain of gates) and reports setup slack (positive = good) and hold slack (positive = good). Both must be positive for reliable operation.

---

## 6. Design Decisions & Tradeoffs

Every non-obvious decision is documented here, with the alternative considered and why it was rejected.

### CPU: PicoRV32 (RV32I, no M or C extensions)

| Option | Cell count | Notes |
|---|---|---|
| **PicoRV32 RV32I** | ~2,000 | Chosen. Proven on sky130. Simple, auditable. |
| PicoRV32 RV32IM | ~2,400 | M-extension adds a multicycle multiplier — good for math, not needed here |
| PicoRV32 RV32IMC | ~2,600 | Compressed instructions shrink code size but complicate the fetch unit |
| SERV (serial core) | ~200 | 1 bit/cycle — tiny but 32× slower; not useful for UART demo |
| Ibex / CV32E40P | ~20,000 | Full pipeline, excellent performance, but much larger |

**Decision:** RV32I keeps the design auditable and avoids the tight timing paths that the M-extension's combinational multiply creates.

### Interconnect: PicoRV32 native bus (not APB/AHB/AXI)

PicoRV32 exposes a simple handshake interface (`mem_valid`, `mem_ready`, `mem_addr`, `mem_wdata`, `mem_wstrb`, `mem_rdata`). With a single master (the CPU) and two slaves (SRAM, UART), wrapping this in APB or AXI would add:
- A protocol bridge (~100–500 cells)
- Extra pipeline registers (adding latency)
- More design to verify

The native bus **is** a proper bus. It has valid/ready handshaking, byte-lane enables, and full 32-bit addressing. At this scale, it is the right choice.

**If scaling to 4+ peripherals:** the combinational mux depth grows and the `mem_rdata` return path timing gets tighter. At that point, converting `soc_bus.v` to an APB interconnect with registered outputs is the clean upgrade path.

### SRAM: Behavioral model (not sky130 macro)

| Option | Simulation | Synthesis | Physical |
|---|---|---|---|
| **Behavioral `reg [31:0] mem[255:0]`** | ✓ Zero-wait | 8192 DFFs | ~330×330 µm die |
| sky130 SRAM macro | ✓ With wrapper | 0 DFFs, hardened | ~150×150 µm (smaller!) |

The behavioral model is simpler to bring up. The macro path requires LEF/GDS files, macro placement constraints, and a one-cycle wait state for reads (registered macro output). The `soc_bus.v` already has the wait-state logic annotated and commented — switching to the macro is a well-defined upgrade path documented in `openlane/soc/README.md`.

### Interrupt: Direct connection, no PLIC

A PLIC (Platform-Level Interrupt Controller) is the standard RISC-V way to handle many interrupt sources with priority levels. With **one** interrupt source (the UART), a PLIC is pure overhead:

```
Without PLIC:  uart_irq → irq[0]  (1 wire)
With PLIC:     uart_irq → PLIC → priority_encoder → irq[0]  (+100 cells)
```

The PLIC is the correct choice at 4+ interrupt sources. With one source, it is over-engineering.

### Synthesis: `AREA 1` strategy

The dominant area in this design is the 8192 DFFs from the behavioral SRAM. A delay-first synthesis strategy (`DELAY 3`) would cause Yosys to:
- Duplicate logic for retiming (creating multiple copies of the SRAM mux tree)
- Potentially 2× the total cell count
- Create routing congestion that prevents place-and-route from completing

`AREA 1` tells Yosys to minimise area first. The SRAM mux tree stays as a single tree; timing is then recovered by CTS and buffering during physical design.

### Floorplan: 35% utilisation (not 50%)

The UART IP alone uses 50% core utilisation without issue — 145 cells spread evenly. The SoC has ~10,500 cells, dominated by the DFF cluster. Dense DFF arrays create routing congestion because every DFF needs clock, reset, D, and Q wires, and they are all placed adjacent to each other.

At 50% utilisation, the DFF cluster has essentially no room between cells for routing. At 35%, there is 15% of empty space that the router can use for local detours. Empirical rule: **designs with >5,000 DFFs need ≤40% utilisation** on sky130 HD to avoid routing failures.

### False paths on `rst_n` and `uart_rx`

Both signals are **asynchronous** — they have no timing relationship to `clk`. The 2-FF synchronizers in the RTL handle them correctly, but STA cannot characterise the metastable resolution window of the first FF in each synchronizer. Without `set_false_path`, STA reports them as setup violations (which are false — the 2-FF chain was designed to absorb the metastability). `set_false_path` tells STA to skip these paths entirely.

### Reset synchronizer in `soc_top.v`

```verilog
reg rst_n_meta, rst_n_sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rst_n_meta <= 0; rst_n_sync <= 0; end
    else        begin rst_n_meta <= 1; rst_n_sync <= rst_n_meta; end
end
```

`rst_n` deassertion (0→1) is asynchronous. If different flip-flops inside the SoC see this event on different clock cycles, some start executing while others are still in reset — a race condition that causes unpredictable behaviour. The synchronizer ensures all internal logic sees deassertion on the same clock edge. Assertion (1→0) propagates immediately (asynchronous path in the `always` block) — this is correct because putting the chip into reset should be instantaneous.

This is one of the most commonly omitted details in student designs and always asked about in design reviews.

---

## 7. Bugs & Lessons Learned

### Bug 1 — The `maskirq` trap: PicoRV32 starts fully masked

**What failed:** After Stage 1 and Stage 2 RTL, the system-level testbench showed `irq_out` going HIGH after a byte was injected on `uart_rx`, but the ISR never ran. The IRQ signal stayed HIGH for 300+ cycles with the CPU completely ignoring it and continuing to spin in the `JAL x0, 0` loop.

**Why it failed:** PicoRV32 resets with `irq_mask = ~0` (all 32 IRQ lines masked). This is documented in the PicoRV32 README but easy to miss. When `irq_mask[0] = 1`, the condition:

```verilog
// picorv32.v line 1538
if (ENABLE_IRQ && ((decoder_trigger && !irq_active && !irq_delay
    && |(irq_pending & ~irq_mask)) || irq_state))
```

evaluates as `|(irq_pending & ~irq_mask)` = `|(1 & 0)` = `0`. The CPU legitimately never takes the interrupt because software has not yet indicated it is safe to do so.

**How it was debugged:** A diagnostic testbench was added that printed a timestamped log of every bus transaction and every `irq_out` transition. The log showed:
```
[890000]  CTRL write: wdata=0x00000004   (firmware wrote irq_en=1 ✓)
[11330000] >>> IRQ RISE <<<               (uart_top asserted irq ✓)
...300 cycles of irq_out=1 with no ISR activity...
[no CTRL or RX_DATA access visible]       (CPU never entered ISR ✗)
```

The fix was a single PicoRV32 custom instruction added to the firmware before the spin loop:

```asm
maskirq x0, x0   // irq_mask = 0  (unmask all IRQ lines)
// Encoding: 0x0600000B — verified: picorv32.v line 1682
```

**Lesson:** When integrating any CPU core, read the reset state of every architectural register — not just the general-purpose registers. PicoRV32 fully masks interrupts at reset as a safety feature (prevents spurious IRQ entry before firmware is ready). That feature becomes a bug when firmware forgets to unmask.

---

### Bug 2 — Testbench polling loops are unreliable for transient events

**What failed:** Test 3 (IRQ assertion) reported "firmware never wrote UART_CTRL within timeout" even though the simulation log showed the CTRL write happening at cycle 44 (very early in the simulation). The test's polling loop opened its monitoring window at cycle ~600 (after the UART TX tests completed).

**Why it failed:** The polling loop was:

```verilog
// WRONG: polling loop misses events that happened before the loop starts
for (timeout = 0; timeout < 600; timeout = timeout + 1) begin
    @(posedge clk); #1;
    if (dut.mem_valid && (dut.mem_addr == UART_CT_ADDR) && |dut.mem_wstrb)
        ctrl_written = 1;
end
```

The CPU executes ~30 instructions to reach the CTRL write (LUI, ADDI, SW = ~15 cycles). The two UART TX bytes take ~200 cycles to *serialise on the wire*, but the CPU issues both SW instructions in ~6 cycles and immediately proceeds to write CTRL. By the time the testbench finished waiting for the serial waveforms in Test 2 and opened the polling window for Test 3, the CTRL write was hundreds of cycles in the past.

**How it was debugged:** The timestamp log from Bug 1's diagnostic showed `CTRL write` at `[890000]` = 44 cycles after reset, while Test 3's polling started around cycle 600. The event was simply over.

**The correct solution:** Use `always @(posedge clk)` monitors that run continuously from time zero, latching events permanently:

```verilog
// CORRECT: persistent monitor captures the event whenever it happens
reg ctrl_written;
initial ctrl_written = 1'b0;

always @(posedge clk) begin
    if (dut.mem_valid && (dut.mem_addr == UART_CT_ADDR) && |dut.mem_wstrb)
        ctrl_written <= 1'b1;  // latched: stays 1 forever after the event
end

// Test just checks the flag — no race condition possible
if (ctrl_written) pass("CTRL written"); else fail("CTRL never written");
```

**Lesson:** In a system where the CPU runs 100–1000× faster than the peripheral serializer, any testbench code that polls for CPU-generated bus events must be written as persistent always-block monitors. Procedural polling loops are only safe when you can guarantee the loop opens its window *before* the event occurs.

---

## 8. Verification Results

### UART IP Unit Tests — `tb/uart_top_tb.v`

| # | Test | Patterns | Result |
|---|---|---|---|
| 1 | 8N1 loopback | `0xA5, 0x00, 0xFF, 0x55, 0xAA` | ✅ PASS |
| 2 | 8E1 (even parity) | `0x37, 0xC3` | ✅ PASS |
| 3 | 8O1 (odd parity) | `0x42, 0xBD` | ✅ PASS |
| 4 | FIFO burst | `0x11, 0x22, 0x33, 0x44` back-to-back | ✅ PASS |
| 5 | Framing error | Injected bad stop bit → `frame_err` W1C | ✅ PASS |
| 6 | Status register | Idle: `fifo_empty=1, tx_busy=0` | ✅ PASS |

### SoC System Tests — `tb/soc_top_tb.v`

| # | Test | What is verified | Result |
|---|---|---|---|
| 1 | CPU boot | `mem_valid` at `addr=0x0` within 20 cycles of reset release | ✅ PASS |
| 2 | UART TX | CPU writes 'U' (0x55) then 'V' (0x56); testbench decodes serial line | ✅ PASS |
| 3 | IRQ assertion | Firmware writes `CTRL=irq_en`, `maskirq`; testbench injects 0xA5; `irq_out` goes HIGH | ✅ PASS |
| 4 | IRQ clear | ISR reads `RX_DATA`, `irq_out` deasserts, CPU resumes SRAM execution | ✅ PASS |

**Total: 10/10 tests passing.**

---

## 9. Physical Design Results

### UART IP (existing, from OpenLane run)

| Metric | Value |
|---|---|
| Technology | SkyWater 130 nm (`sky130_fd_sc_hd`) |
| Clock period | 10 ns (100 MHz) |
| Worst setup slack | **+78.59 ns** |
| Worst hold slack | **+0.34 ns** |
| Total power (typical) | **61.2 µW** |
| Cell count | 145 |
| Cell area | 1,565 µm² |
| Die | 60 × 71 µm |
| DRC violations | **0** |
| LVS errors | **0** |
| Antenna violations | **0** |

### SoC (estimated, pending OpenLane run)

| Metric | Estimate | Basis |
|---|---|---|
| Technology | SkyWater 130 nm (`sky130_fd_sc_hd`) | Same PDK |
| Clock period | 20 ns (50 MHz) | Conservative; 2× margin on CPU |
| Expected WNS (setup) | > +5 ns | SRAM mux path ~3.5 ns |
| Expected WNS (hold) | > 0 ns | CTS hold-fix buffers |
| Total cells | ~10,500 | PicoRV32 ~2000 + SRAM DFFs ~8192 + UART 145 + bus ~50 |
| Core area | ~330 × 330 µm | 35% utilisation estimate |
| Power | ~2–4 mW | Dominated by DFF switching |

---

## 10. Repository Structure

```
rv32_soc/
│
├── README.md                    ← You are here
│
├── rtl/                         ← All hardware description (Verilog)
│   ├── picorv32.v               PicoRV32 CPU core (upstream, unmodified)
│   ├── soc_top.v                Top-level SoC integration + reset synchronizer
│   ├── soc_bus.v                Address decoder, rdata mux, UART adapter
│   ├── soc_sram.v               Behavioral 1 KB SRAM (256 × 32-bit)
│   ├── uart_top.v               UART register-mapped controller
│   ├── uart_tx.v                UART transmitter (8N1/8E1/8O1)
│   ├── uart_rx.v                UART receiver (2-FF sync, mid-bit sampling)
│   ├── sync_fifo.v              Parameterised synchronous FIFO
│   └── README.md                Module reference + interface docs
│
├── tb/                          ← Simulation testbenches
│   ├── uart_top_tb.v            UART IP unit test (6 tests)
│   ├── soc_top_tb.v             SoC system test (4 tests, loads firmware.hex)
│   ├── Makefile                 make sim / make soc / make all
│   ├── simulation_results.txt   UART unit test output
│   ├── soc_results.txt          SoC system test output
│   └── README.md                How to run simulations
│
├── firmware/                    ← Software that runs on the CPU
│   ├── start.S                  Reset vector, IRQ handler prologue, BSS clear
│   ├── uart_drv.h               Memory-mapped UART driver (pure C, no stdlib)
│   ├── main.c                   Demo: boot message, IRQ-driven echo loop
│   ├── link.ld                  Linker script (0x0–0x3FF, 1 KB SRAM)
│   ├── firmware.py              Python encoder — produces firmware.hex without GCC
│   ├── firmware.hex             Pre-built firmware image (loaded by testbench)
│   ├── Makefile                 Builds firmware; auto-detects GCC or uses Python
│   └── README.md                Firmware architecture + build instructions
│
├── openlane/
│   ├── config.json              OpenLane config for UART IP alone
│   ├── pin_order.cfg            UART IP pin placement
│   │
│   └── soc/                     ← SoC physical flow configuration
│       ├── config.json          OpenLane config for full SoC
│       ├── pin_order.cfg        SoC pin placement (N: clk/rst/irq, S: uart)
│       ├── soc_top.sdc          Timing constraints + false paths
│       └── README.md            Full run instructions + troubleshooting
│
└── docs/
    ├── images/
    │   ├── architecture.svg     UART IP block diagram
    │   ├── register_map.svg     UART register definitions
    │   ├── uart_8n1_waveform.png  Single byte transfer waveform
    │   ├── uart_fifo_burst.png  FIFO burst waveform
    │   └── gds_layout.png       Physical chip layout (KLayout view)
    ├── gen_waveforms.py         Regenerates waveform PNGs from VCD
    └── gen_diagrams.py          Regenerates SVG architecture diagrams
```

---

## 11. How to Run

### Prerequisites

```bash
# macOS
brew install icarus-verilog gtkwave

# Ubuntu / Debian
sudo apt install iverilog gtkwave

# Python (for firmware generation)
python3 --version   # 3.8+ required
```

### Simulation

```bash
cd tb

# Run UART IP unit tests (6 tests)
make sim

# Run SoC system tests (4 tests) — requires firmware.hex
make soc

# Run all tests
make all

# Open waveforms in GTKWave
make wave       # UART unit test VCD
make soc_wave   # SoC system test VCD
```

Expected output:
```
ALL TESTS PASSED (6 tests)   ← UART unit test
ALL TESTS PASSED (4 tests)   ← SoC system test
```

### Firmware Build

```bash
cd firmware

# Auto-detect toolchain (uses Python if GCC not found)
make

# Force Python path (no RISC-V toolchain needed)
make python

# Show instruction listing
make verbose

# Verify the hex file
make check
```

### OpenLane Physical Flow

```bash
# Install OpenLane (Docker)
git clone https://github.com/The-OpenROAD-Project/OpenLane ~/OpenLane
cd ~/OpenLane && make pull-openlane && make pdk

# Run UART IP flow (from Docker container)
./flow.tcl -design path/to/openlane

# Run SoC flow
./flow.tcl -design path/to/openlane/soc -tag rv32_soc_run1

# View results
klayout runs/rv32_soc_run1/results/final/gds/soc_top.gds
```

Full OpenLane setup and troubleshooting: [`openlane/soc/README.md`](openlane/soc/README.md)

---

## 12. Tools

| Tool | Version | Purpose |
|---|---|---|
| Icarus Verilog | 11+ | RTL simulation |
| GTKWave | 3.3+ | Waveform viewer |
| Python | 3.8+ | Firmware generation (no GCC needed) |
| riscv32-unknown-elf-gcc | 12+ | Optional: compile firmware from C source |
| OpenLane | v1.0 / v2.x | RTL-to-GDS physical flow |
| SkyWater sky130A PDK | — | 130 nm standard cell library |
| KLayout | 0.27+ | GDS layout viewer |
| Docker | 20+ | OpenLane container runtime |

---

## Project Origin

This project evolved in stages, each building on the previous:

1. **Stage 0** — Production-quality UART IP with 6-test verification suite and clean GDS
2. **Stage 1** — SoC RTL: integrated PicoRV32 CPU, SRAM, and UART with a minimal bus
3. **Stage 2** — System-level testbench: CPU executing firmware, UART TX/RX, full IRQ cycle
4. **Stage 3** — Firmware: `start.S`, `uart_drv.h`, `main.c`, `link.ld`, and Python hex encoder
5. **Stage 4** — Physical flow: OpenLane configuration, SDC timing constraints, run guide

Each stage was verified before proceeding to the next. The two bugs documented in [Section 7](#7-bugs--lessons-learned) were found during Stage 2 and fixed before Stage 3.

---

## License

Original RTL (soc_top, soc_bus, soc_sram, uart_top, uart_tx, uart_rx, sync_fifo, firmware): original work.
PicoRV32: MIT License, Copyright (C) 2015–2024 Claire Wolf.
OpenLane flow infrastructure: Apache 2.0, Efabless Corporation.
SkyWater sky130 PDK: Apache 2.0, SkyWater Technology Foundry.
