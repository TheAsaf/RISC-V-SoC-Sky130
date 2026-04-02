# =============================================================================
# soc_top.sdc — Timing constraints for rv32_soc
# Project: rv32_soc — Sky130 OpenLane
# Target:  50 MHz on sky130A sky130_fd_sc_hd
#
# This file defines:
#   1. Primary clock definition and waveform
#   2. Generated clocks (none — single clock domain)
#   3. I/O timing constraints
#   4. False paths (reset synchronizer, async UART RX)
#   5. Multicycle paths (none required at 50 MHz)
#
# All path constraints are relative to clk. The design is single-domain;
# there are no CDC crossings requiring set_max_delay -datapath_only.
#
# The uart_rx input pin is the only truly asynchronous input. The 2-FF
# synchronizer in uart_rx.v correctly handles this; we declare it a false
# path so the timer does not attempt to characterise a path that has no
# meaningful setup/hold requirement relative to clk.
# =============================================================================

# =============================================================================
# 1. Primary clock — 50 MHz, 50% duty cycle
# =============================================================================
create_clock -name clk \
             -period 20.000 \
             -waveform {0.000 10.000} \
             [get_ports clk]

# Apply clock uncertainty (jitter + skew budget).
# 200 ps is a conservative estimate for sky130 at this frequency.
# CTS will target ≤200 ps skew (CTS_TARGET_SKEW in config.json).
# The combined uncertainty budget ensures setup slack absorbs both.
set_clock_uncertainty 0.200 [get_clocks clk]

# Clock transition time — used by STA to model clock edge quality.
# 0.15 ns is typical for a buffered clock at 50 MHz in sky130 HD.
set_clock_transition 0.150 [get_clocks clk]

# =============================================================================
# 2. Input delays
#
# All synchronous inputs (rst_n, uart_rx) are given input delays relative
# to clk to model the external driving circuit.
#
# rst_n:   Assumed to arrive at least 2 ns before the sampling edge.
#          This is conservative — in practice, rst_n goes through the
#          reset synchronizer (2 FFs) so the synchronised version is
#          available well within any reasonable skew budget.
#          The 2 ns value covers a worst-case external reset assertion.
#
# uart_rx: Formally asynchronous (see false_paths section below).
#          We still constrain it nominally so the pre-synthesis tool
#          does not leave the input completely unconstrained, which can
#          produce misleading timing reports.
# =============================================================================
set_input_delay -clock clk -max 2.000 [get_ports rst_n]
set_input_delay -clock clk -min 0.500 [get_ports rst_n]

set_input_delay -clock clk -max 2.000 [get_ports uart_rx]
set_input_delay -clock clk -min 0.000 [get_ports uart_rx]

# =============================================================================
# 3. Output delays
#
# uart_tx: Driven by a registered output in uart_tx.v. Allow 2 ns for
#          external load (PCB trace, level shifter, or loopback wire in
#          simulation). This is a typical value for a UART output.
#
# irq_out: Combinational from uart_top.irq = irq_en & rx_ready.
#          Both signals are registered inside uart_top, so irq_out is
#          registered-to-output. Allow 2 ns external load.
# =============================================================================
set_output_delay -clock clk -max 2.000 [get_ports uart_tx]
set_output_delay -clock clk -min 0.000 [get_ports uart_tx]

set_output_delay -clock clk -max 2.000 [get_ports irq_out]
set_output_delay -clock clk -min 0.000 [get_ports irq_out]

# =============================================================================
# 4. False paths
#
# Reset synchronizer — rst_n → rst_n_meta → rst_n_sync:
#   The two flip-flops in soc_top's reset synchronizer are intentionally
#   designed to be metastable-safe. STA cannot characterise the metastable
#   resolution time, and the path from rst_n (async pad) to rst_n_meta is
#   by definition a false path for setup/hold purposes.
#   We set a false path on the -from [get_ports rst_n] to prevent STA from
#   flagging this as a setup/hold violation.
#
# UART RX async input — uart_rx → uart_rx.v 2-FF synchronizer:
#   Same reasoning as reset. The 2-FF chain in uart_rx.v is the designed
#   metastability protection. The path from the pad to the first FF has
#   no meaningful setup/hold constraint relative to clk.
# =============================================================================
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rx]

# =============================================================================
# 5. Load and drive strength models
#
# These are conservative estimates for sky130 at board level.
# In a real tape-out, these values come from the pad ring specification.
#
# set_load: 5 fF = typical net load for a short on-chip connection to pad
# set_driving_cell: use the standard drive-strength-1 buffer as the model
#   for the external driver. STA uses this to compute slew on input paths.
# =============================================================================
set_load 5.000 [all_outputs]
set_driving_cell -lib_cell sky130_fd_sc_hd__buf_2 \
                 -pin X \
                 [all_inputs]

# =============================================================================
# 6. Design-specific path notes (for review, not active constraints)
#
# Critical path analysis (50 MHz = 20 ns):
#
#   Path 1: SRAM read return  (expected WNS > +8 ns)
#     mem_addr[9:2] → soc_sram address decode → 256-to-1 mux tree → mem_rdata
#     → soc_bus mux → PicoRV32 mem_rdata input register
#     Combinational: ~6 mux levels × ~0.35 ns/level + routing ≈ 3.5 ns
#     Plus PicoRV32 setup ≈ 0.2 ns. Well within 20 ns budget.
#
#   Path 2: PicoRV32 ALU → register file write  (expected WNS > +5 ns)
#     PicoRV32 closes at ~100 MHz in isolation on sky130 HD; at 50 MHz
#     the ALU path has ~10 ns of slack.
#
#   Path 3: UART baud counter carry chain  (expected WNS > +12 ns)
#     16-bit counter increment with ripple carry ≈ 2.5 ns at worst.
#
#   Hold risk: behavioral SRAM has combinational read output.
#     If PicoRV32's mem_addr changes and the SRAM output changes in the
#     same cycle, a hold violation is theoretically possible on any FF
#     that samples mem_rdata. CTS hold-fixing buffers should catch this.
#     If post-route hold slack is negative, increase:
#       CTS_CLK_BUFFER_LIST: add sky130_fd_sc_hd__clkbuf_4 entries
# =============================================================================
