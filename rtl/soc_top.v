// ============================================================================
// Module:  soc_top
// Project: rv32_soc — Sky130 OpenLane
// Description:
//   Top-level integration of rv32_soc. Instantiates:
//     - PicoRV32 (RV32I, ENABLE_IRQ=1)
//     - soc_bus  (address decoder + UART width adapter)
//     - soc_sram (1 KB behavioral SRAM)
//     - uart_top (existing UART IP, unmodified)
//
//   Implements a 2-FF reset synchronizer so all internal modules see a
//   clean synchronous reset deassertion regardless of when the external
//   rst_n pad releases.
//
//   Interrupt topology:
//     uart_top.irq → picorv32.irq[0]
//     irq[31:1]    = 0 (no other sources)
//
// Parameters:
//   CLKS_PER_BIT — Baud divisor passed to uart_top.
//                  Default 434 for 50 MHz / 115200 baud.
//                  Override to 16 in simulation for fast testbenches.
//
// Clock/Reset:
//   clk   — single clock domain; all modules synchronous to this.
//   rst_n — asynchronous active-low reset from pad. Internally synchronised
//           before distribution to avoid metastability on deassertion.
// ============================================================================

module soc_top #(
    parameter CLKS_PER_BIT = 434    // 50 MHz / 115200 baud
) (
    input  wire clk,
    input  wire rst_n,      // asynchronous active-low reset (from pad)

    // UART I/O — to/from physical pins
    input  wire uart_rx,
    output wire uart_tx,

    // Interrupt output (optional: route to LED / logic analyser trigger)
    output wire irq_out
);

    // =========================================================================
    // Reset synchronizer
    // Deassertion of rst_n is sampled through a 2-FF chain so all downstream
    // flops see a synchronous rising edge on rst_n_sync.
    // Assertion is asynchronous (rst_n low travels immediately).
    // =========================================================================
    reg rst_n_meta, rst_n_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_meta <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_sync <= rst_n_meta;
        end
    end

    // =========================================================================
    // PicoRV32 memory interface wires
    // =========================================================================
    wire        mem_valid;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;

    // =========================================================================
    // Interrupt wiring
    // PicoRV32 IRQ vector is 32 bits wide. We use only bit 0 for UART.
    // =========================================================================
    wire        uart_irq;
    wire [31:0] cpu_irq = {31'b0, uart_irq};

    assign irq_out = uart_irq;   // expose on pin for debug / waveform capture

    // =========================================================================
    // PicoRV32 — RV32I, interrupts enabled
    //
    // Configuration rationale:
    //   ENABLE_MUL=0, ENABLE_DIV=0 — M-extension adds ~400 cells of
    //     combinational multiply/divide logic and creates tight timing paths.
    //     Not needed for UART demo firmware.
    //   ENABLE_COMPRESSED=0 — C-extension complicates the fetch unit.
    //     RV32I is sufficient and keeps the decoder auditable.
    //   ENABLE_IRQ=1 — Required for UART receive interrupt.
    //   ENABLE_IRQ_QREGS=0 — IRQ quick-save registers (q0-q3) add 128 DFFs
    //     with no benefit when firmware explicitly saves/restores context.
    //   BARREL_SHIFTER=1 — Single-cycle shifts. Without this, each shift is a
    //     loop consuming multiple cycles. At 50 MHz it's free in area terms.
    //   STACKADDR — initialise stack pointer to top of SRAM (0x400 = 1 KB).
    //     PicoRV32 loads sp from STACKADDR before the first instruction, so
    //     firmware start.S does not need to set up the stack manually.
    //   PROGADDR_RESET=0 — Reset vector at 0x0 (bottom of SRAM).
    //   PROGADDR_IRQ=0x10 — IRQ handler entry point at SRAM word 4 (byte 16).
    //     Firmware places a jump instruction here in the reset vector table.
    // =========================================================================
    picorv32 #(
        .ENABLE_MUL        (0),
        .ENABLE_DIV        (0),
        .COMPRESSED_ISA    (0),
        .ENABLE_IRQ        (1),
        .ENABLE_IRQ_QREGS  (0),
        .BARREL_SHIFTER    (1),
        .STACKADDR         (32'h0000_0400),  // top of 1 KB SRAM
        .PROGADDR_RESET    (32'h0000_0000),  // reset vector
        .PROGADDR_IRQ      (32'h0000_0010)   // IRQ vector (byte 16)
    ) u_cpu (
        .clk        (clk),
        .resetn     (rst_n_sync),            // PicoRV32 uses active-high resetn

        // Memory interface
        .mem_valid  (mem_valid),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),

        // Interrupt
        .irq        (cpu_irq),

        // Unused outputs (trap, mem_instr, look-ahead interface, pcpi)
        .trap       (),
        .mem_instr  (),
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),
        .mem_la_wdata (),
        .mem_la_wstrb (),
        .pcpi_valid (),
        .pcpi_insn  (),
        .pcpi_rs1   (),
        .pcpi_rs2   (),
        .pcpi_wr    (1'b0),
        .pcpi_rd    (32'h0),
        .pcpi_wait  (1'b0),
        .pcpi_ready (1'b0),
        .eoi        ()
    );

    // =========================================================================
    // SRAM inter-module wires
    // =========================================================================
    wire        sram_cs, sram_we;
    wire [ 3:0] sram_wstrb;
    wire [ 7:0] sram_addr;
    wire [31:0] sram_wdata, sram_rdata;

    // =========================================================================
    // UART inter-module wires
    // =========================================================================
    wire [ 2:0] uart_addr;
    wire [ 7:0] uart_wdata, uart_rdata;
    wire        uart_wen, uart_ren;

    // =========================================================================
    // soc_bus — address decode and UART adapter
    // =========================================================================
    soc_bus u_bus (
        .clk        (clk),
        .rst_n      (rst_n_sync),

        // CPU side
        .mem_valid  (mem_valid),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),

        // SRAM side
        .sram_cs    (sram_cs),
        .sram_we    (sram_we),
        .sram_wstrb (sram_wstrb),
        .sram_addr  (sram_addr),
        .sram_wdata (sram_wdata),
        .sram_rdata (sram_rdata),

        // UART side
        .uart_addr  (uart_addr),
        .uart_wdata (uart_wdata),
        .uart_rdata (uart_rdata),
        .uart_wen   (uart_wen),
        .uart_ren   (uart_ren)
    );

    // =========================================================================
    // soc_sram — 1 KB behavioral SRAM
    // =========================================================================
    soc_sram #(
        .DEPTH (256)
    ) u_sram (
        .clk    (clk),
        .cs     (sram_cs),
        .we     (sram_we),
        .wstrb  (sram_wstrb),
        .addr   (sram_addr),
        .wdata  (sram_wdata),
        .rdata  (sram_rdata)
    );

    // =========================================================================
    // uart_top — existing UART IP (zero modifications)
    // CLKS_PER_BIT overridden to match SoC clock (50 MHz default → 434).
    // In simulation testbench: override to 16 for fast simulation.
    // =========================================================================
    uart_top #(
        .CLKS_PER_BIT (CLKS_PER_BIT),
        .FIFO_DEPTH   (8)
    ) u_uart (
        .clk     (clk),
        .rst_n   (rst_n_sync),

        // Register interface (driven by soc_bus)
        .addr    (uart_addr),
        .wdata   (uart_wdata),
        .rdata   (uart_rdata),
        .wen     (uart_wen),
        .ren     (uart_ren),

        // Physical pins
        .uart_rx (uart_rx),
        .uart_tx (uart_tx),

        // Interrupt
        .irq     (uart_irq)
    );

endmodule
