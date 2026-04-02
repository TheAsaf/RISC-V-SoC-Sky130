// ============================================================================
// Module:  soc_bus
// Project: rv32_soc — Sky130 OpenLane
// Description:
//   Address decoder, rdata mux, and UART width adapter for rv32_soc.
//   Sits between PicoRV32's native memory interface and two slaves:
//     1. soc_sram  — 1 KB SRAM at 0x00000000–0x000003FF
//     2. uart_top  — UART registers at 0x20000000–0x2000000F
//
//   Design rules enforced here (see architecture analysis for rationale):
//     • mem_ready depends only on mem_addr/mem_valid — never on mem_rdata.
//       This breaks any combinational loop through the rdata mux.
//     • Default (unmapped) addresses: mem_ready asserts after one cycle,
//       mem_rdata = 0. CPU sees a valid response and advances; no stall.
//     • UART adapter: 32-bit bus → 8-bit registers.
//       word offset = mem_addr[4:2]; write data = mem_wdata[7:0].
//       Read data zero-extended to 32 bits.
//
// Memory Map:
//   0x00000000 – 0x000003FF   soc_sram  (1 KB, word-addressed by [9:2])
//   0x20000000 – 0x2000000F   uart_top  (4 registers, word-stride 4 B)
//   All other addresses       default   (returns 0x00000000)
//
// Interface (PicoRV32 native memory bus):
//   mem_valid  — CPU asserts to initiate a transaction
//   mem_ready  — Bus asserts when transaction is complete (one cycle for
//                both SRAM behavioral and UART; see macro note in soc_sram)
//   mem_addr   — 32-bit byte address
//   mem_wdata  — 32-bit write data
//   mem_wstrb  — 4-bit byte enables (0000 = read, else write)
//   mem_rdata  — 32-bit read data
// ============================================================================

module soc_bus (
    input  wire        clk,
    input  wire        rst_n,

    // ---- PicoRV32 native memory interface ----
    input  wire        mem_valid,
    output wire        mem_ready,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output wire [31:0] mem_rdata,

    // ---- SRAM slave port ----
    output wire        sram_cs,
    output wire        sram_we,
    output wire [ 3:0] sram_wstrb,
    output wire [ 7:0] sram_addr,
    output wire [31:0] sram_wdata,
    input  wire [31:0] sram_rdata,

    // ---- UART slave port ----
    output wire [ 2:0] uart_addr,
    output wire [ 7:0] uart_wdata,
    input  wire [ 7:0] uart_rdata,
    output wire        uart_wen,
    output wire        uart_ren
);

    // =========================================================================
    // Address decode
    // All decode is purely combinational from mem_addr.
    // No feedback from ready or rdata — no combinational loops possible.
    // =========================================================================

    // SRAM: 0x00000000 – 0x000003FF (1 KB = 256 × 32-bit words)
    wire sram_sel = mem_valid && (mem_addr[31:10] == 22'h0);

    // UART: 0x20000000 – 0x2000000F (4 registers, 4 bytes each)
    // mem_addr[31:4] == 28'h2000000 covers 0x20000000–0x2000000F
    wire uart_sel = mem_valid && (mem_addr[31:4] == 28'h2000000);

    // Default: anything not covered above
    wire default_sel = mem_valid && !sram_sel && !uart_sel;

    // =========================================================================
    // mem_ready
    // Both SRAM (behavioral) and UART respond combinationally — one cycle.
    // Default selection also responds in one cycle (returns 0x0).
    //
    // NOTE — sky130 SRAM macro path (documented, not active):
    // If using the hardened macro (registered output), replace sram_sel in
    // the mem_ready assignment with sram_ready_r defined below.
    //
    //   reg sram_ready_r;
    //   always @(posedge clk) begin
    //       if (!rst_n) sram_ready_r <= 1'b0;
    //       else sram_ready_r <= sram_sel && (mem_wstrb == 4'b0);
    //   end
    //   // writes still respond in one cycle (no read-back needed)
    //   wire sram_ready = (sram_sel && |mem_wstrb) ? 1'b1 : sram_ready_r;
    // =========================================================================
    assign mem_ready = sram_sel | uart_sel | default_sel;

    // =========================================================================
    // mem_rdata mux
    // Exactly one select can be high at a time (address ranges don't overlap).
    // sram_rdata and uart_rdata are gated by their cs/sel signals — when not
    // selected they return 0, so OR-ing is safe. We use an explicit priority
    // mux for clarity and to avoid X-propagation in simulation.
    // =========================================================================
    assign mem_rdata = sram_sel  ? sram_rdata              :
                       uart_sel  ? {24'h0, uart_rdata}     :
                                   32'h0;

    // =========================================================================
    // SRAM slave drive
    // =========================================================================
    assign sram_cs    = sram_sel;
    assign sram_we    = sram_sel && (|mem_wstrb);
    assign sram_wstrb = mem_wstrb;
    assign sram_addr  = mem_addr[9:2];   // byte addr → word addr (drop [1:0])
    assign sram_wdata = mem_wdata;

    // =========================================================================
    // UART slave drive — 32-bit → 8-bit adapter
    //
    // Register offset: mem_addr[4:2] selects which UART register word.
    //   0x20000000 → addr 3'h0 → TX_DATA
    //   0x20000004 → addr 3'h1 → RX_DATA
    //   0x20000008 → addr 3'h2 → STATUS
    //   0x2000000C → addr 3'h3 → CTRL
    //
    // Write: software always writes a full byte into bits [7:0] of the 32-bit
    //        word (e.g., sw t0, 0(a0)). We pass wdata[7:0] directly.
    //        wen fires when any byte strobe is asserted — the UART register
    //        interface does not have byte-lane enables internally.
    //
    // Read: uart_top drives rdata[7:0] combinationally. We zero-extend.
    //       ren fires on a pure read transaction (wstrb == 0).
    //       Asserting ren has a side-effect: reading RX_DATA clears rx_ready.
    //       We gate ren on uart_sel to avoid spurious clears on other cycles.
    // =========================================================================
    assign uart_addr  = mem_addr[4:2];
    assign uart_wdata = mem_wdata[7:0];
    assign uart_wen   = uart_sel && (|mem_wstrb);
    assign uart_ren   = uart_sel && (mem_wstrb == 4'b0);

endmodule
