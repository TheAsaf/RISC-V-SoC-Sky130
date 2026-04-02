// ============================================================================
// Module:  soc_sram
// Project: rv32_soc — Sky130 OpenLane
// Description:
//   Behavioral 1 KB synchronous SRAM, 32-bit wide, 256 words deep.
//
//   Interface matches PicoRV32's native memory bus directly:
//     - 4-bit write-strobe (byte enables) — each bit gates one byte lane
//     - Combinational read: data appears same cycle as address + cs
//     - Synchronous write: data written on posedge clk when we && cs
//
//   Physical design note:
//     For a real sky130 tapeout, replace this module body with an
//     instantiation of sky130_sram_1kbyte_1rw1r_32x256_8. That macro
//     has a registered (1-cycle latency) read output, which requires
//     soc_bus to insert one wait state for reads (mem_ready_r path).
//     All bus logic for that case is already annotated in soc_bus.v.
//
// Parameters:
//   DEPTH — word count. Default 256 (1 KB). Must match address decode
//           in soc_bus.v (SRAM_TOP = DEPTH*4 - 1).
// ============================================================================

module soc_sram #(
    parameter DEPTH = 256   // 256 × 32-bit = 1 KB
) (
    input  wire        clk,
    // Chip select — qualifies all operations
    input  wire        cs,
    // Write port
    input  wire        we,
    input  wire [3:0]  wstrb,   // byte-lane enables: {byte3, byte2, byte1, byte0}
    input  wire [7:0]  addr,    // word address (byte_addr[9:2])
    input  wire [31:0] wdata,
    // Read port — combinational
    output wire [31:0] rdata
);

    // -----------------------------------------------------------------------
    // Storage array
    // Synthesis: infers 8192 DFFs (4 × 256 × 8-bit). Area ~8000 cells on
    // sky130 HD. Acceptable for architecture demonstration; replace with
    // hardened macro for production.
    // -----------------------------------------------------------------------
    reg [31:0] mem [0:DEPTH-1];

    // -----------------------------------------------------------------------
    // Synchronous write with byte-lane enables
    // Each strobe bit protects one byte lane independently, matching the
    // PicoRV32 mem_wstrb encoding (byte 0 = bits [7:0]).
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (cs && we) begin
            if (wstrb[0]) mem[addr][ 7: 0] <= wdata[ 7: 0];
            if (wstrb[1]) mem[addr][15: 8] <= wdata[15: 8];
            if (wstrb[2]) mem[addr][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[addr][31:24] <= wdata[31:24];
        end
    end

    // -----------------------------------------------------------------------
    // Combinational read
    // Returns mem[addr] immediately. When cs=0, returns 32'h0 to avoid
    // spurious bus contention (important when rdata mux is transparent).
    // -----------------------------------------------------------------------
    assign rdata = cs ? mem[addr] : 32'h0;

    // -----------------------------------------------------------------------
    // Simulation: zero-initialise memory so unloaded firmware reads as NOP
    // (RISC-V NOP = 32'h00000013 = ADDI x0,x0,0; 32'h0 = illegal trap).
    // The testbench overwrites this via $readmemh before the CPU starts.
    // -----------------------------------------------------------------------
    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 32'h00000013;  // NOP sled — safe default
    end

endmodule
