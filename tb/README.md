# Testbenches — Simulation & Verification

This directory contains two self-checking testbenches and a Makefile that runs them.

## Quick Start

```bash
cd tb

make sim      # UART IP unit test  (6 tests)
make soc      # SoC system test    (4 tests)
make all      # both together
make wave     # open UART VCD in GTKWave
make soc_wave # open SoC VCD in GTKWave
make clean    # remove generated binaries and VCDs
```

All tests print `PASS` / `FAIL` per assertion and a summary at the end.

---

## `uart_top_tb.v` — UART IP Unit Test

Tests the UART peripheral in isolation, without the CPU or SRAM. Drives the register interface directly (addr/wdata/wen/ren) and loops TX back to RX.

### Test Plan

| # | Test | Description |
|---|---|---|
| 1 | **8N1 loopback** | Sends 5 bytes (`0xA5, 0x00, 0xFF, 0x55, 0xAA`) through TX→RX loopback. Verifies each byte received correctly. |
| 2 | **8E1 even parity** | Sets `CTRL = parity_en=1, parity_odd=0`. Sends 2 bytes. Verifies parity is generated and checked. |
| 3 | **8O1 odd parity** | Sets `CTRL = parity_en=1, parity_odd=1`. Sends 2 bytes. |
| 4 | **FIFO burst** | Writes 4 bytes rapidly without waiting for TX to complete. Verifies FIFO holds them and drains in order. |
| 5 | **Framing error** | Manually drives a bad UART frame (stop bit = LOW) directly onto the RX pin. Verifies `frame_err` sticky flag sets, and W1C clears it. |
| 6 | **Status register** | After idle period: verifies `fifo_empty=1, tx_busy=0`. |

### Key design choices in the testbench

**Fast baud divider:** `CLKS_PER_BIT = 16` (not the realistic 434). This makes each byte take 160 ns in simulation instead of 4.34 µs — 27× faster. The UART protocol is timing-proportional, so the tests are still architecturally valid.

**Stimulus timing:** All register writes use `@(posedge clk); #1;` — the `#1` delay places the stimulus just after the clock edge, avoiding setup-time races where the DUT and testbench sample the same edge.

**W1C verification (Test 5):** After injecting the framing error, the testbench:
1. Reads STATUS — checks `frame_err=1`
2. Writes `STATUS = 0x10` (bit 4 = frame_err)
3. Reads STATUS again — verifies `frame_err=0`

This is the complete W1C read-modify-clear cycle that a real driver would use.

---

## `soc_top_tb.v` — SoC System Test

Tests the full SoC: a real CPU core executing firmware, communicating through the bus, and handling an interrupt.

### Firmware Load

Before reset releases, the testbench loads firmware from `../firmware/firmware.hex`:

```verilog
initial begin : fw_load
    #1;
    $readmemh("../firmware/firmware.hex", dut.u_sram.mem, 0, 15);
end
```

The `#1` delay yields to `soc_sram`'s own `initial` block (which fills the array with NOPs), then overwrites words 0–15 with the firmware. Words 16–255 remain as NOPs — safe for the CPU to execute if it ever strays.

**If `firmware.hex` is missing:** run `make -C ../firmware python` first. The testbench will fail with a file-not-found warning from `$readmemh` but will still elaborate.

### Test Plan

| # | Test | What is verified | How |
|---|---|---|---|
| 1 | **CPU boot** | PicoRV32 fetches from `0x00000000` within 20 cycles of reset | Polls `dut.mem_valid && dut.mem_addr == 0x0` |
| 2 | **UART TX** | CPU writes 'U' (0x55) then 'V' (0x56); bytes appear on `uart_tx` pin | `recv_uart_byte` task decodes the serial line |
| 3 | **IRQ assertion** | After firmware writes `CTRL=irq_en` and `maskirq`, injecting a byte on `uart_rx` causes `irq_out=1` | Persistent monitor; `send_uart_byte` injects 0xA5 |
| 4 | **IRQ clear** | ISR reads `RX_DATA` (`irq_out` deasserts), `retirq` executes, CPU resumes | Persistent monitors for both events |

### Architecture: Persistent Bus Monitors

The SoC testbench uses a different strategy from the UART unit test. The CPU executes ~40 instructions in the time it takes the UART to serialise one byte, so bus events happen much earlier than the testbench's main sequence reaches the relevant check.

**Wrong approach (polling loop):** opens a time window and looks for the event. Misses it if the event already happened.

**Correct approach (persistent monitor):** runs from time 0, latches any matching event into a flag that persists forever.

```verilog
// Runs for the ENTIRE simulation from time 0
always @(posedge clk) begin
    // CPU wrote to UART CTRL register?
    if (dut.mem_valid && (dut.mem_addr == 32'h2000000C) && |dut.mem_wstrb)
        ctrl_written <= 1'b1;  // stays 1 even if we check it 1000 cycles later

    // ISR read UART RX_DATA?
    if (dut.mem_valid && (dut.mem_addr == 32'h20000004) && (dut.mem_wstrb == 0))
        rx_data_read <= 1'b1;

    // irq_out ever went HIGH?
    if (irq_out)
        irq_was_asserted <= 1'b1;
end
```

This pattern is the correct one for any testbench where stimulus generation and DUT execution happen at very different rates.

### UART decode tasks

`recv_uart_byte` — waits for the falling edge (start bit) on `uart_tx`, advances to the mid-start-bit, samples 8 data bits at `BIT_PERIOD` intervals, and checks the stop bit:

```verilog
@(negedge uart_tx);          // detect start bit
#(BIT_PERIOD / 2);           // advance to mid-start-bit
for (i = 0; i < 8; i++) begin
    #BIT_PERIOD;
    data[i] = uart_tx;       // sample at bit centre, LSB first
end
#BIT_PERIOD;
framing_ok = uart_tx;        // stop bit must be HIGH
```

`send_uart_byte` — drives a complete 8N1 frame on `uart_rx` at the testbench's baud rate:

```verilog
uart_rx = 0; #BIT_PERIOD;                    // start bit
for (i = 0; i < 8; i++) begin
    uart_rx = data[i]; #BIT_PERIOD;          // data bits, LSB first
end
uart_rx = 1; #(BIT_PERIOD * 2);             // stop bit + idle guard
```

---

## Makefile Reference

```makefile
make sim        # compile + run uart_top_tb.v
make soc        # compile + run soc_top_tb.v
make all        # both sim and soc
make wave       # gtkwave uart_top_tb.vcd
make soc_wave   # gtkwave soc_top_tb.vcd
make clean      # rm uart_sim soc_sim *.vcd *_results.txt
```

The Makefile uses `-g2012 -Wall -Wno-timescale` for both testbenches. The only expected warnings are from `picorv32.v` (sensitivity list warnings for the 32-word register file array — benign and from upstream).

---

## Reading the Simulation Output

A passing run looks like:
```
=== TEST 1: CPU boot (first instruction fetch) ===
  PASS: mem_valid at addr=0x0 within 20 cycles of reset

=== TEST 2: CPU writes 'U','V' via UART TX ===
  PASS: byte[0] == 'U' = 0x55
  PASS: byte[1] == 'V' = 0x56

=== TEST 3: IRQ assertion after UART RX ===
  PASS: firmware wrote UART_CTRL (irq_en=1, confirmed via bus monitor)
  Injecting 0xA5 on uart_rx...
  PASS: irq_out asserted after RX byte received

=== TEST 4: ISR clears IRQ by reading RX_DATA ===
  PASS: ISR read from UART_RX_ADDR (LW x2, 4(x1))
  PASS: irq_out deasserted after ISR read RX_DATA
  PASS: CPU resumed SRAM execution after retirq

================================================
  ALL TESTS PASSED (4 tests)
================================================
```

If a test fails, the failure message shows what was expected vs. received, which is usually enough to identify whether the bug is in RTL, firmware, or testbench.
