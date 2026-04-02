// ============================================================================
// Testbench: soc_top_tb
// Project:   rv32_soc — Sky130 OpenLane
// Description:
//   System-level self-checking testbench for the complete SoC.
//   Firmware is loaded from ../firmware/firmware.hex via $readmemh.
//   Generate the hex with: make -C ../firmware  (or: make -C ../firmware python)
//
// Test plan:
//   1. CPU boot   — verify first instruction fetch from 0x00000000
//   2. UART TX    — CPU writes 'U' then 'V'; testbench decodes serial line
//   3. IRQ assert — firmware enables IRQ + unmasks; testbench injects byte;
//                   verify irq_out goes HIGH
//   4. IRQ clear  — CPU ISR reads RX_DATA, executes retirq;
//                   verify irq_out goes LOW and CPU resumes
//
// ============================================================================
// FIRMWARE LAYOUT (from firmware/firmware.hex — see firmware.py for encodings)
//
//   Word  Addr  Encoding    Assembly
//   ----  ----  ----------  ---------------------------------------------------
//   0     0x00  01C0006F    JAL  x0, +0x1C        // reset vector → main
//   1–3   0x04  00000013    NOP ×3                 // IRQ vector padding
//   -- IRQ handler (PROGADDR_IRQ = 0x10) --
//   4     0x10  200000B7    LUI  x1,  0x20000      // x1 = UART_BASE
//   5     0x14  0040A583    LW   x11, 4(x1)        // read RX_DATA → deasserts irq
//   6     0x18  0400000B    retirq                  // return from interrupt
//   -- main (0x1C) --
//   7     0x1C  200000B7    LUI  x1,  0x20000      // x1 = UART_BASE
//   8     0x20  05500593    ADDI x11, x0, 0x55     // x11 = 'U'
//   9     0x24  00B0A023    SW   x11, 0(x1)        // TX 'U'
//   10    0x28  05600593    ADDI x11, x0, 0x56     // x11 = 'V'
//   11    0x2C  00B0A023    SW   x11, 0(x1)        // TX 'V'
//   12    0x30  00400593    ADDI x11, x0, 4        // irq_en bit
//   13    0x34  00B0A623    SW   x11, 0xC(x1)      // UART_CTRL = irq_en
//   14    0x38  0600000B    maskirq x0, x0          // unmask all IRQ lines ← critical
//   15    0x3C  0000006F    JAL  x0, 0              // spin
//
// IRQ mechanics (PicoRV32, ENABLE_IRQ=1, ENABLE_IRQ_QREGS=0):
//   Reset: irq_mask = ~0 (all masked). MUST call maskirq to unmask before any
//          interrupt can be taken — this is the only non-obvious requirement.
//   On IRQ entry: CPU saves return-PC → x3, IRQ-pending → x4
//   ISR uses only x1, x2 → x3/x4 preserved → correct return ✓
//   retirq: jumps to x3, clears irq_active, does NOT restore irq_mask
//           (mask stays 0 after maskirq, so future IRQs are still enabled)
//
// Instruction encoding reference (verified against picorv32.v):
//   maskirq: bits[31:25]=0000011, bits[6:0]=0001011 → 0x0600000B
//   retirq:  bits[31:25]=0000010, bits[6:0]=0001011 → 0x0400000B
//   All RV32I encodings verified by hand; encodings documented inline.
//
// Testbench architecture note:
//   Transient bus events (CTRL write, RX_DATA read) are captured by
//   always-block persistent monitors, not procedural polling loops.
//   This prevents false failures when the CPU executes faster than
//   the UART serializer — which it always does at simulation speeds.
// ============================================================================

`timescale 1ns / 1ps

module soc_top_tb;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD   = 20;              // 50 MHz clock (ns)
    localparam CLKS_PER_BIT = 16;             // Fast simulation baud divider
    localparam BIT_PERIOD   = CLK_PERIOD * CLKS_PER_BIT;  // ns per UART bit

    // UART register byte addresses
    localparam [31:0] UART_BASE    = 32'h20000000;
    localparam [31:0] UART_TX_ADDR = UART_BASE + 32'h00;
    localparam [31:0] UART_RX_ADDR = UART_BASE + 32'h04;
    localparam [31:0] UART_ST_ADDR = UART_BASE + 32'h08;
    localparam [31:0] UART_CT_ADDR = UART_BASE + 32'h0C;

    // =========================================================================
    // DUT signals
    // =========================================================================
    reg  clk;
    reg  rst_n;
    reg  uart_rx;
    wire uart_tx;
    wire irq_out;

    // =========================================================================
    // DUT instantiation — CLKS_PER_BIT overridden for fast simulation
    // =========================================================================
    soc_top #(
        .CLKS_PER_BIT (CLKS_PER_BIT)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .uart_rx  (uart_rx),
        .uart_tx  (uart_tx),
        .irq_out  (irq_out)
    );

    // =========================================================================
    // Clock generation
    // =========================================================================
    initial clk = 0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // =========================================================================
    // VCD dump
    // =========================================================================
    initial begin
        $dumpfile("soc_top_tb.vcd");
        $dumpvars(0, soc_top_tb);
    end

    // =========================================================================
    // Persistent bus event monitors
    //
    // Polling loops are unreliable for capturing transient events: the CPU
    // runs ~100-400x faster than the UART, so by the time the test's polling
    // loop starts, the interesting bus transaction is long gone.
    //
    // These always-blocks run for the entire simulation and latch events
    // permanently — the test code only needs to check the flag, not race it.
    // =========================================================================
    reg ctrl_written;       // firmware wrote UART_CTRL (irq_en set)
    reg rx_data_read;       // ISR read UART_RX_DATA (clears rx_ready)
    reg irq_was_asserted;   // irq_out went HIGH at least once

    initial begin
        ctrl_written     = 1'b0;
        rx_data_read     = 1'b0;
        irq_was_asserted = 1'b0;
    end

    always @(posedge clk) begin
        if (dut.mem_valid && (dut.mem_addr == UART_CT_ADDR) && |dut.mem_wstrb)
            ctrl_written <= 1'b1;
        if (dut.mem_valid && (dut.mem_addr == UART_RX_ADDR) && (dut.mem_wstrb == 4'b0))
            rx_data_read <= 1'b1;
        if (irq_out)
            irq_was_asserted <= 1'b1;
    end

    // =========================================================================
    // Test infrastructure
    // =========================================================================
    integer errors   = 0;
    integer test_num = 0;

    task pass; input [8*40-1:0] msg; begin
        $display("  PASS: %0s", msg);
    end endtask

    task fail; input [8*40-1:0] msg; begin
        $display("  FAIL: %0s", msg);
        errors = errors + 1;
    end endtask

    task check_byte;
        input [7:0] got, expected;
        input [8*20-1:0] label;
        begin
            if (got === expected)
                $display("  PASS: %0s = 0x%02X", label, got);
            else begin
                $display("  FAIL: %0s: expected 0x%02X, got 0x%02X", label, expected, got);
                errors = errors + 1;
            end
        end
    endtask

    // =========================================================================
    // UART receive task — decodes serial bits on uart_tx
    //
    // Timing model (8N1):
    //   @(negedge uart_tx)         → start bit detected
    //   #(BIT_PERIOD/2)            → advance to mid-start-bit
    //   loop 8×: #BIT_PERIOD; sample → mid-bit samples for bits [7:0]
    //   #BIT_PERIOD; check stop bit
    // =========================================================================
    task recv_uart_byte;
        output [7:0] data;
        output       framing_ok;
        integer      i;
        begin
            @(negedge uart_tx);
            #(BIT_PERIOD / 2);
            for (i = 0; i < 8; i = i + 1) begin
                #BIT_PERIOD;
                data[i] = uart_tx;
            end
            #BIT_PERIOD;
            framing_ok = uart_tx;   // stop bit must be HIGH
        end
    endtask

    // =========================================================================
    // UART send task — drives an 8N1 frame onto uart_rx
    // Used to inject a byte "from an external device" into the SoC.
    // =========================================================================
    task send_uart_byte;
        input [7:0] data;
        integer     i;
        begin
            uart_rx = 1'b0;             // start bit
            #BIT_PERIOD;
            for (i = 0; i < 8; i = i + 1) begin
                uart_rx = data[i];      // LSB first
                #BIT_PERIOD;
            end
            uart_rx = 1'b1;             // stop bit + idle guard
            #(BIT_PERIOD * 2);
        end
    endtask

    // =========================================================================
    // Firmware load via $readmemh
    //
    // Loads ../firmware/firmware.hex into the SRAM model.
    // firmware.hex is generated by:
    //   Path A (preferred): make -C ../firmware      (requires riscv32-elf-gcc)
    //   Path B (fallback):  make -C ../firmware python  (Python 3, no toolchain)
    //
    // $readmemh format: one 32-bit hex word per line, no address tags,
    // sequential from word 0.  Lines beginning with // are treated as comments
    // and ignored — matching the header that firmware.py emits.
    //
    // The #1 delay yields to soc_sram's own initial block (NOP fill), so
    // the $readmemh overwrites only the words that contain real firmware;
    // the rest of the 1 KB remain as the NOP sled from soc_sram.v.
    // =========================================================================
    initial begin : fw_load
        #1;
        $readmemh("../firmware/firmware.hex", dut.u_sram.mem, 0, 15);
    end

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        // ---- Global initialisation ----
        rst_n   = 1'b0;
        uart_rx = 1'b1;   // UART idles HIGH

        repeat (10) @(posedge clk);  // hold reset ≥ reset-synchronizer depth

        // =====================================================================
        // TEST 1: CPU boot — first instruction fetch from 0x00000000
        //
        // PicoRV32 must present mem_valid=1 at mem_addr=0x0 within a handful
        // of cycles after resetn deasserts. We poll the public wires on
        // soc_top (which connect directly to the PicoRV32 memory interface).
        // =====================================================================
        test_num = 1;
        $display("\n=== TEST %0d: CPU boot (first instruction fetch) ===", test_num);

        begin : test_boot
            integer t;
            reg     saw_fetch;
            saw_fetch = 0;
            rst_n = 1'b1;
            for (t = 0; t < 20; t = t + 1) begin
                @(posedge clk); #1;
                if (dut.mem_valid && (dut.mem_addr == 32'h0) && (dut.mem_wstrb == 4'b0)) begin
                    saw_fetch = 1;
                    t = 20;
                end
            end
            if (saw_fetch)
                pass("mem_valid at addr=0x0 within 20 cycles of reset");
            else
                fail("CPU did not fetch from 0x0 within 20 cycles");
        end

        // =====================================================================
        // TEST 2: UART TX — CPU sends 'U' (0x55) then 'V' (0x56)
        //
        // CPU executes main: LUI → ADDI 'U' → SW → ADDI 'V' → SW
        // Each SW goes to 0x20000000 (UART_TX_DATA).  soc_bus routes it to
        // uart_top's TX FIFO; uart_tx.v serialises it.
        //
        // recv_uart_byte blocks until it sees the start-bit edge on uart_tx,
        // so no explicit synchronisation is needed — the task IS the wait.
        //
        // Timeout: fork with 500-cycle watchdog (actual: ~200 cycles).
        // =====================================================================
        test_num = 2;
        $display("\n=== TEST %0d: CPU writes 'U','V' via UART TX ===", test_num);

        begin : test_uart_tx
            reg [7:0] b0, b1;
            reg       ok0, ok1;
            fork
                begin
                    recv_uart_byte(b0, ok0);
                    recv_uart_byte(b1, ok1);
                end
                repeat (500) @(posedge clk);
            join_any
            disable fork;

            check_byte(b0, 8'h55, "byte[0] == 'U'");
            check_byte(b1, 8'h56, "byte[1] == 'V'");
            if (!ok0) fail("byte[0] framing error");
            if (!ok1) fail("byte[1] framing error");
        end

        // =====================================================================
        // TEST 3: IRQ assertion
        //
        // After the UART TX writes, the firmware executes:
        //   ADDI x2, x0, 4   → irq_en bit
        //   SW   x2, 0xC(x1) → UART_CTRL[2]=1 (irq_en=1)
        //   maskirq x0, x0   → irq_mask=0 (unmask ALL)
        //   JAL  x0, 0       → spin
        //
        // The ctrl_written flag is set by the persistent always-block monitor
        // which watches the bus throughout the simulation.  By the time we
        // check it here, it is already 1 (the CPU wrote CTRL while we were
        // receiving the UART bytes in test 2 — the CPU is much faster).
        //
        // After confirming IRQ is enabled and unmasked, we inject one byte on
        // uart_rx.  uart_rx.v decodes it (~CLKS_PER_BIT×10 cycles), sets
        // rx_ready, and irq_out goes HIGH.  We verify via irq_was_asserted.
        // =====================================================================
        test_num = 3;
        $display("\n=== TEST %0d: IRQ assertion after UART RX ===", test_num);

        begin : test_irq_assert
            integer t;

            // ctrl_written is a persistent flag — if firmware ran during
            // test 2 (which it did), it's already 1.  Give a short window
            // in case we somehow arrived here early.
            if (!ctrl_written) begin
                for (t = 0; t < 100 && !ctrl_written; t = t + 1)
                    @(posedge clk);
            end

            if (ctrl_written)
                pass("firmware wrote UART_CTRL (irq_en=1, confirmed via bus monitor)");
            else
                fail("firmware never wrote UART_CTRL");

            // Inject 0xA5 onto uart_rx — takes BIT_PERIOD*12 = 192 cycles
            $display("  Injecting 0xA5 on uart_rx...");
            send_uart_byte(8'hA5);

            // irq_was_asserted is a persistent flag: it captures the IRQ
            // even if the ISR already ran and cleared it before we check.
            // Give a small window in case the byte is still being received.
            for (t = 0; t < CLKS_PER_BIT * 3 && !irq_was_asserted; t = t + 1)
                @(posedge clk);

            if (irq_was_asserted)
                pass("irq_out asserted after RX byte received");
            else
                fail("irq_out never asserted (check irq_en, irq_mask, uart_rx timing)");
        end

        // =====================================================================
        // TEST 4: IRQ clear — ISR reads RX_DATA, irq_out deasserts
        //
        // PicoRV32 with irq_mask=0 takes the interrupt from the spin loop.
        // IRQ entry: saves return-PC → x3, pending-bitmap → x4; jumps to 0x10.
        // ISR at 0x10:
        //   LUI  x1, 0x20000  → UART base
        //   LW   x2, 4(x1)   → reads UART_RX_DATA → uart_top clears rx_ready
        //   retirq            → jumps to x3 (return PC), clears irq_active
        //
        // We verify:
        //   a) ISR issued a read from UART_RX_ADDR (via rx_data_read flag)
        //   b) irq_out deasserted (1-2 cycles after the LW)
        //   c) CPU resumed SRAM execution after retirq
        //
        // rx_data_read is a persistent flag — might already be set if the
        // ISR ran quickly.  Give a short window to cover the case where it
        // runs after test 3 completes.
        // =====================================================================
        test_num = 4;
        $display("\n=== TEST %0d: ISR clears IRQ by reading RX_DATA ===", test_num);

        begin : test_irq_clear
            integer t;

            // Wait for ISR's LW from UART_RX_ADDR (persistent flag)
            for (t = 0; t < 150 && !rx_data_read; t = t + 1)
                @(posedge clk);

            if (rx_data_read)
                pass("ISR read from UART_RX_ADDR (LW x2, 4(x1))");
            else
                fail("ISR never read UART_RX_ADDR within timeout");

            // rx_ready clears on the cycle after ren is seen by uart_top.
            // irq = irq_en & rx_ready, so irq goes LOW one cycle later.
            // Wait 4 cycles for the combinational path to settle.
            repeat (4) @(posedge clk);

            if (!irq_out)
                pass("irq_out deasserted after ISR read RX_DATA");
            else
                fail("irq_out still HIGH after ISR read RX_DATA");

            // Verify CPU resumed normal execution (fetching from SRAM, not stuck)
            begin : verify_resume
                integer ft;
                reg resumed;
                resumed = 0;
                for (ft = 0; ft < 50 && !resumed; ft = ft + 1) begin
                    @(posedge clk); #1;
                    if (dut.mem_valid && (dut.mem_addr < 32'h400))
                        resumed = 1;
                end
                if (resumed)
                    pass("CPU resumed SRAM execution after retirq");
                else
                    fail("CPU did not resume SRAM execution after retirq");
            end
        end

        // =====================================================================
        // Summary
        // =====================================================================
        repeat (20) @(posedge clk);
        $display("\n================================================");
        if (errors == 0)
            $display("  ALL TESTS PASSED (%0d tests)", test_num);
        else
            $display("  %0d FAILURE(S) across %0d tests", errors, test_num);
        $display("================================================\n");
        $finish;
    end

    // =========================================================================
    // Global safety timeout — 5000 cycles (100 µs at 50 MHz)
    // =========================================================================
    initial begin
        #(CLK_PERIOD * 5000);
        $display("\nTIMEOUT: simulation exceeded 5000 cycles");
        errors = errors + 1;
        $finish;
    end

endmodule
