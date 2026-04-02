# ============================================================================
# Simulation Makefile
# Project: rv32_soc + UART IP — Sky130 OpenLane
# Requires: Icarus Verilog (iverilog), optionally GTKWave
#
# Targets:
#   make sim      — run UART IP unit testbench (uart_top_tb)
#   make soc      — run SoC system-level testbench (soc_top_tb)
#   make wave     — open uart_top_tb VCD in GTKWave
#   make soc_wave — open soc_top_tb VCD in GTKWave
#   make all      — run both testbenches
#   make clean    — remove generated files
# ============================================================================

RTL_DIR  := ../rtl
TB_DIR   := .

# ---- UART IP unit test ----
UART_SRC := $(RTL_DIR)/uart_tx.v \
            $(RTL_DIR)/uart_rx.v \
            $(RTL_DIR)/sync_fifo.v \
            $(RTL_DIR)/uart_top.v
UART_TB  := $(TB_DIR)/uart_top_tb.v
UART_BIN := uart_sim
UART_VCD := uart_top_tb.vcd
UART_LOG := simulation_results.txt

# ---- SoC system-level test ----
SOC_SRC  := $(RTL_DIR)/picorv32.v \
            $(RTL_DIR)/sync_fifo.v \
            $(RTL_DIR)/uart_tx.v \
            $(RTL_DIR)/uart_rx.v \
            $(RTL_DIR)/uart_top.v \
            $(RTL_DIR)/soc_sram.v \
            $(RTL_DIR)/soc_bus.v \
            $(RTL_DIR)/soc_top.v
SOC_TB   := $(TB_DIR)/soc_top_tb.v
SOC_BIN  := soc_sim
SOC_VCD  := soc_top_tb.vcd
SOC_LOG  := soc_results.txt

IVERILOG_FLAGS := -g2012 -Wall -Wno-timescale

.PHONY: all sim soc wave soc_wave clean

all: sim soc

# ---- UART IP unit simulation ----
sim: $(UART_BIN)
	@echo "Running UART unit simulation..."
	@./$(UART_BIN) | tee $(UART_LOG)
	@echo ""
	@echo "Results saved to $(UART_LOG)"

$(UART_BIN): $(UART_SRC) $(UART_TB)
	iverilog $(IVERILOG_FLAGS) -o $@ $^

wave: $(UART_VCD)
	gtkwave $(UART_VCD) &

$(UART_VCD): sim

# ---- SoC system-level simulation ----
soc: $(SOC_BIN)
	@echo "Running SoC system simulation..."
	@./$(SOC_BIN) | tee $(SOC_LOG)
	@echo ""
	@echo "Results saved to $(SOC_LOG)"

$(SOC_BIN): $(SOC_SRC) $(SOC_TB)
	iverilog $(IVERILOG_FLAGS) -o $@ $^

soc_wave: $(SOC_VCD)
	gtkwave $(SOC_VCD) &

$(SOC_VCD): soc

# ---- Cleanup ----
clean:
	rm -f $(UART_BIN) $(UART_VCD) $(UART_LOG) \
	      $(SOC_BIN)  $(SOC_VCD)  $(SOC_LOG)
