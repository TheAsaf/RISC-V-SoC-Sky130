# RTL — Hardware Description

This directory contains all Verilog source files for the rv32_soc. There are **8 modules**; 4 are new SoC-level modules and 4 are the original UART IP.

The files are listed in dependency order (each file only instantiates modules defined in files above it):

```
picorv32.v        ← CPU core (no dependencies)
sync_fifo.v       ← FIFO primitive (no dependencies)
uart_tx.v         ← UART transmitter (no dependencies)
uart_rx.v         ← UART receiver (no dependencies)
uart_top.v        ← uses: sync_fifo, uart_tx, uart_rx
soc_sram.v        ← SRAM (no dependencies)
soc_bus.v         ← bus logic (no dependencies, just wire logic)
soc_top.v         ← uses: picorv32, uart_top, soc_sram, soc_bus
```

---

## Module Reference

### `soc_top.v` — Top-Level SoC Integration

The chip's top-level module. This is what OpenLane synthesises. It:
- Instantiates all other modules
- Implements a 2-FF reset synchronizer
- Wires the CPU interrupt input to the UART irq output

```
Ports:
  clk      — system clock (50 MHz default)
  rst_n    — asynchronous active-low reset (goes through synchronizer internally)
  uart_rx  — serial receive input (async; goes through 2-FF sync in uart_rx.v)
  uart_tx  — serial transmit output
  irq_out  — UART interrupt output (level-sensitive, exposed for debug)

Parameters:
  CLKS_PER_BIT = 434   (50 MHz / 115200 baud; override to 16 for fast simulation)
```

**Reset synchronizer — why it's here:**
The external `rst_n` signal arrives from a pad with no timing relationship to `clk`. If different flip-flops inside the chip see reset deassertion on different clock cycles, some modules start executing while others are still held in reset — an undefined state. The 2-FF chain ensures all internal logic sees deassertion in the same clock cycle.

```verilog
// Assertion (rst_n goes LOW) is asynchronous — propagates immediately
// Deassertion (rst_n goes HIGH) is synchronised through 2 FFs
reg rst_n_meta, rst_n_sync;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rst_n_meta <= 0; rst_n_sync <= 0; end
    else        begin rst_n_meta <= 1; rst_n_sync <= rst_n_meta; end
end
```

---

### `soc_bus.v` — Address Decoder and Bus Logic

This module sits between the CPU and the two slaves (SRAM and UART). It has no state — it is purely combinational logic.

```
Inputs:  PicoRV32 memory interface (mem_valid, mem_addr, mem_wdata, mem_wstrb)
Outputs: PicoRV32 mem_ready, mem_rdata

Outputs to SRAM: sram_cs, sram_we, sram_wstrb, sram_addr[7:0], sram_wdata
Inputs from SRAM: sram_rdata[31:0]

Outputs to UART: uart_addr[2:0], uart_wdata[7:0], uart_wen, uart_ren
Inputs from UART: uart_rdata[7:0]
```

**Address decode logic** (3 lines of Verilog):
```verilog
wire sram_sel = mem_valid && (mem_addr[31:10] == 22'h0);      // 0x000–0x3FF
wire uart_sel = mem_valid && (mem_addr[31:4] == 28'h2000000); // 0x20000000–0x2000000F
wire default_sel = mem_valid && !sram_sel && !uart_sel;
```

**Critical design rule:** `mem_ready` and `mem_rdata` must never feed back into the address decode logic. This prevents combinational loops. The decode is purely a function of `mem_addr` (a CPU output) — no feedback possible.

**UART width adapter:** The CPU has a 32-bit bus; the UART has an 8-bit interface. The adapter:
- Passes `mem_addr[4:2]` as the UART register selector (word offset)
- Passes `mem_wdata[7:0]` as UART write data (software always writes bytes)
- Zero-extends `uart_rdata[7:0]` to 32 bits for the CPU
- Asserts `uart_ren` on pure reads (wstrb=0) — this has the side effect of clearing `rx_ready` when reading RX_DATA

---

### `soc_sram.v` — 1 KB Behavioral SRAM

A synchronous RAM: writes are clocked, reads are combinational.

```
Ports:
  clk            — clock
  cs             — chip select (gates all operations)
  we             — write enable
  wstrb[3:0]     — byte-lane enables (bit 0 = byte 0 = bits [7:0])
  addr[7:0]      — word address (byte address >> 2)
  wdata[31:0]    — write data
  rdata[31:0]    — read data (combinational)

Parameter:
  DEPTH = 256    (256 × 32-bit = 1 KB)
```

**Byte-lane writes** are critical for RISC-V correctness. The `SB` (store byte) and `SH` (store halfword) instructions must modify only part of a 32-bit word. PicoRV32 encodes which bytes to write in `mem_wstrb[3:0]`:
```verilog
if (wstrb[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];  // SB to byte 0
if (wstrb[1]) mem[addr][15: 8] <= wdata[15: 8];  // SB to byte 1
if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];  // SH upper byte
if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];  // SW all 4 bytes
```

**Simulation initialisation:** The `initial` block fills the array with `0x00000013` (the RV32I NOP instruction) so that any unloaded address the CPU fetches from executes a harmless NOP rather than an illegal instruction trap. The testbench then uses `$readmemh` to overwrite the firmware words before reset releases.

**Physical design note:** This behavioral model synthesises to 8192 DFFs. For a production tapeout, replace with the sky130 1 KB SRAM macro. See `openlane/soc/README.md` for the migration steps.

---

### `picorv32.v` — PicoRV32 CPU Core

**Upstream file — not modified.** From [YosysHQ/picorv32](https://github.com/YosysHQ/picorv32) by Claire Wolf, MIT License.

**Configuration used in this SoC:**

| Parameter | Value | Reason |
|---|---|---|
| `ENABLE_MUL` | 0 | No multiply hardware — not needed for UART demo |
| `ENABLE_DIV` | 0 | No divide hardware |
| `ENABLE_IRQ` | 1 | Required for UART interrupt |
| `ENABLE_IRQ_QREGS` | 0 | Saves 128 DFFs; ISR explicitly saves/restores context |
| `COMPRESSED_ISA` | 0 | No 16-bit compressed instructions |
| `BARREL_SHIFTER` | 1 | Single-cycle shifts (default is multi-cycle) |
| `STACKADDR` | `0x400` | Stack pointer initialised to top of 1 KB SRAM |
| `PROGADDR_RESET` | `0x0` | Reset vector at SRAM base |
| `PROGADDR_IRQ` | `0x10` | IRQ handler entry at byte 16 of SRAM |

**IRQ mechanics (important for firmware authors):**

When `irq[i]` is HIGH and `irq_mask[i]` is 0:
1. CPU finishes its current instruction
2. Writes return PC → `x3` (gp)
3. Writes IRQ-pending bitmap → `x4` (tp)
4. Jumps to `PROGADDR_IRQ` (0x10)

The ISR must:
- NOT clobber `x3` or `x4` before `retirq`
- Read `UART_RX_DATA` to clear `rx_ready` and deassert `irq[0]`
- Execute `retirq` (encoding: `0x0400000B`) to return

`irq_mask` resets to `~0` (all masked). Firmware must execute `maskirq x0, x0` (`0x0600000B`) to enable interrupt delivery.

---

### `uart_top.v` — UART Register-Mapped Controller

The UART peripheral. Designed as a bus-agnostic IP block; integrates `uart_tx`, `uart_rx`, and `sync_fifo`.

```
Ports:
  clk, rst_n          — system clock and synchronous reset
  addr[2:0]           — register select
  wdata[7:0]          — write data
  rdata[7:0]          — read data (combinational)
  wen                 — write enable (1 cycle pulse)
  ren                 — read enable (1 cycle pulse; triggers rx_ready clear)
  uart_rx, uart_tx    — serial I/O
  irq                 — interrupt output (level-sensitive)

Parameters:
  CLKS_PER_BIT = 868  (default: 100 MHz / 115200; SoC uses 434 for 50 MHz)
  FIFO_DEPTH = 8
```

**TX path:**
```
wen + addr==TX_DATA → push to sync_fifo (if not full)
sync_fifo not empty + tx not busy → latch byte + assert tx_start
uart_tx serialises byte on uart_tx pin
```

**RX path:**
```
uart_rx_pin → 2-FF sync inside uart_rx → FSM samples bits
rx_valid pulse → rx_data_reg latched, rx_ready=1
ren + addr==RX_DATA → rx_ready cleared (combinational rdata already stable)
```

**Interrupt:** `irq = irq_en & rx_ready` — purely combinational from registered signals. Level-sensitive: stays HIGH until `RX_DATA` is read.

---

### `uart_tx.v` — UART Transmitter

FSM with states: `IDLE → START → DATA → PARITY → STOP → IDLE`

```
Ports:
  tx_start     — 1-cycle pulse to begin transmission
  tx_data[7:0] — byte to transmit (must be stable on tx_start)
  parity_en    — 0: 8N1, 1: parity enabled
  parity_odd   — 0: even parity, 1: odd parity
  tx           — serial output (idles HIGH)
  tx_busy      — HIGH while transmitting
  tx_done      — 1-cycle pulse when done
```

Baud clock: 16-bit counter, resets to 0 at each bit boundary. `CLKS_PER_BIT` determines how many system clocks equal one UART bit period.

---

### `uart_rx.v` — UART Receiver

FSM with states: `IDLE → START → DATA → PARITY → STOP`

```
Ports:
  rx           — serial input (asynchronous — goes through 2-FF sync inside)
  parity_en    — must match transmitter setting
  parity_odd   — must match transmitter setting
  rx_data[7:0] — received byte (valid for 1 cycle when rx_valid=1)
  rx_valid     — 1-cycle pulse on successful reception
  frame_err    — 1-cycle pulse if stop bit was LOW (bad frame)
  parity_err   — 1-cycle pulse if parity mismatch
```

**2-FF synchronizer is inside this module:**
```verilog
reg rx_meta, rx_sync;
always @(posedge clk) begin
    rx_meta <= rx;       // first FF: may be metastable
    rx_sync <= rx_meta;  // second FF: stable (with high probability)
end
```

Mid-bit sampling: on start-bit detection, waits `CLKS_PER_BIT/2` to reach the bit center, then samples at `CLKS_PER_BIT` intervals.

---

### `sync_fifo.v` — Parameterised Synchronous FIFO

```
Parameters:
  DATA_WIDTH = 8      (8-bit data for UART TX)
  DEPTH = 8           (must be power of two)
  ADDR_WIDTH = 3      (derived: $clog2(DEPTH))

Ports:
  wr_en, wr_data      — write port
  rd_en, rd_data      — read port (rd_data is combinational / fall-through)
  full, empty, count  — status
```

**Pointer design:** Write and read pointers are `ADDR_WIDTH+1` bits wide. The extra MSB distinguishes full from empty when lower bits are equal:
- `wr_ptr == rd_ptr` → empty (all bits match)
- `wr_ptr[MSB] != rd_ptr[MSB]` AND `wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]` → full (wrapped around)

**Fall-through read:** `rd_data = mem[rd_ptr]` is combinational — data is available immediately without a read-enable clock edge. This saves one cycle of latency in the UART TX path.

---

## Running RTL Elaboration

To verify all files elaborate without errors:

```bash
cd ..   # project root
iverilog -g2012 -Wno-timescale -o /dev/null \
  rtl/picorv32.v rtl/sync_fifo.v rtl/uart_tx.v rtl/uart_rx.v \
  rtl/uart_top.v rtl/soc_sram.v rtl/soc_bus.v rtl/soc_top.v
# No output = success (only picorv32.v cpuregs sensitivity warnings, benign)
```
