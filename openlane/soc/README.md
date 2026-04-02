# rv32_soc — OpenLane Physical Flow

## Prerequisites

```bash
# Install OpenLane via Docker (recommended)
git clone https://github.com/The-OpenROAD-Project/OpenLane.git ~/OpenLane
cd ~/OpenLane
make pull-openlane          # pulls the Docker image
make pdk                    # downloads and prepares sky130A PDK
```

Or via pip (OpenLane 2):
```bash
pip3 install openlane
python3 -m openlane --smoke-test
```

Set environment variables (add to ~/.zshrc):
```bash
export OPENLANE_ROOT=~/OpenLane
export PDK_ROOT=~/OpenLane/pdks
export PDK=sky130A
```

---

## Running the Flow

### OpenLane 1 (Docker)

```bash
cd ~/OpenLane

# Run the SoC flow
./flow.tcl -design /path/to/UART_VLSI_Project/OpenLane/openlane/soc

# Or from within the OpenLane directory using the mounted path:
./flow.tcl -design $OPENLANE_ROOT/designs/rv32_soc
```

To use the project directory directly:
```bash
cd ~/OpenLane
make mount  # starts the Docker container with the current directory mounted

# Inside the container:
./flow.tcl -design /openlane/openlane/soc -tag rv32_soc_run1
```

### OpenLane 2 (pip)

```bash
cd /path/to/UART_VLSI_Project/OpenLane/openlane/soc
python3 -m openlane config.json
```

---

## Flow Stages and What to Watch

OpenLane runs these stages in order. Each produces artifacts in `runs/<tag>/`:

| Stage | Tool | Key output | What to check |
|---|---|---|---|
| **Synthesis** | Yosys | `results/synthesis/*.v` | Cell count, area estimate |
| **Floorplan** | OpenROAD | `results/floorplan/*.def` | Die size, utilisation |
| **Placement** | OpenROAD | `results/placement/*.def` | Congestion heatmap |
| **CTS** | OpenROAD | `results/cts/*.def` | Clock skew, hold slack |
| **Routing** | OpenROAD | `results/routing/*.def` | DRC count, wire length |
| **RC Extraction** | OpenROAD | `results/parasitics/*.spef` | Net capacitances |
| **STA** | OpenSTA | `reports/signoff/*.rpt` | WNS, TNS, hold slack |
| **DRC** | Magic | `reports/magic_drc.rpt` | Must be zero violations |
| **LVS** | Netgen | `reports/lvs.rpt` | Must match |
| **GDS** | Magic | `results/final/gds/*.gds` | Open in KLayout |

---

## Expected Results at 50 MHz

Based on cell count estimates and sky130 HD characterisation:

| Metric | Estimate | Notes |
|---|---|---|
| **Total cells** | ~10,500 | PicoRV32 ~2000 + SRAM DFFs ~8192 + UART ~145 + bus ~50 |
| **Core area** | ~330×330 µm | At 35% utilisation |
| **Die area** | ~400×400 µm | Including IO ring and margins |
| **WNS (setup)** | > +5 ns | 20 ns budget, SRAM mux path ~3.5 ns |
| **WNS (hold)** | > 0 ns | CTS hold-fix buffers should close this |
| **Power (typical)** | ~2–4 mW | Dominated by 8192 DFF switching activity |
| **DRC violations** | 0 | Target |

---

## Interpreting Synthesis Output

After synthesis, check the cell count breakdown:

```bash
grep "Number of cells" runs/<tag>/reports/synthesis/1-synthesis.log
```

Expected breakdown:
- `sky130_fd_sc_hd__dfxtp_1` — the dominant cell; ~8192 for SRAM DFFs
- `sky130_fd_sc_hd__mux2_1` — SRAM read mux tree; ~255 at each level × 8 levels
- `sky130_fd_sc_hd__buf_*` — clock/data buffers inserted by synthesis
- `sky130_fd_sc_hd__and*/or*` — address decode and bus logic

If total cell count is dramatically higher than ~10,500, check whether
Yosys has duplicated the SRAM DFF array for retiming — this indicates
`SYNTH_STRATEGY` needs to be set to `AREA 0` instead of `AREA 1`.

---

## If Timing Fails

### Setup violations (WNS negative)

Likely culprit: SRAM read mux path at higher clock frequencies.

Fix options (in order of preference):
1. Increase `CLOCK_PERIOD` to 25.0 (40 MHz) — conservative but clean
2. Add `set_multicycle_path 2 -from [get_cells u_sram/*] -to [get_cells u_cpu/*]`
   to `soc_top.sdc` if the SRAM→CPU path is the bottleneck
3. Switch to the sky130 SRAM macro (registered output, but then
   `soc_bus.v` must assert `mem_ready` one cycle later for reads)

### Hold violations (after CTS)

Hold violations on the SRAM combinational read output are the most likely
post-CTS issue. Fix:
```json
"CTS_CLK_BUFFER_LIST": "sky130_fd_sc_hd__clkbuf_2 sky130_fd_sc_hd__clkbuf_4 sky130_fd_sc_hd__clkbuf_8"
```
Adding `clkbuf_4` and `clkbuf_8` gives the hold-fixer larger delay
options and avoids cascaded small buffers that waste area.

### Routing congestion

If routing fails with > 5% overflow, reduce `PL_TARGET_DENSITY` to 0.40
and increase `GLB_RT_ADJUSTMENT` to 0.20. Both changes give the router
more slack at the cost of larger die area.

---

## Switching to the sky130 SRAM Macro (Production Path)

The behavioral SRAM (`soc_sram.v`) synthesises correctly but produces an
impractically large DFF array for a real tape-out. To use the hardened
sky130 1 KB SRAM macro:

**Step 1:** Replace `soc_sram.v` body with macro instantiation:
```verilog
sky130_sram_1kbyte_1rw1r_32x256_8 u_sram_macro (
    .clk0  (clk),
    .csb0  (~cs),
    .web0  (~we),
    .wmask0(wstrb),
    .addr0 (addr),
    .din0  (wdata),
    .dout0 (rdata)
);
```

**Step 2:** Add one wait state for reads in `soc_bus.v` (see the annotated
macro path comment in that file — the code is already written, just
uncommented).

**Step 3:** Add to `config.json`:
```json
"EXTRA_LEFS": ["path/to/sky130_sram_1kbyte_1rw1r_32x256_8.lef"],
"EXTRA_GDS":  ["path/to/sky130_sram_1kbyte_1rw1r_32x256_8.gds"],
"MACRO_PLACEMENT_CFG": "dir::sram_placement.cfg"
```

**Step 4:** Create `sram_placement.cfg`:
```
sky130_sram_1kbyte_1rw1r_32x256_8 100 100 N
```
(Places the macro at 100,100 µm from die origin, north orientation.)

---

## Viewing the GDS

```bash
klayout runs/<tag>/results/final/gds/soc_top.gds
```

Expected layout features:
- Dense DFF cluster (behavioral SRAM) — a rectangular sea of flip-flops
- PicoRV32 core — visually distinct due to its FSM and ALU structure
- UART block — small, recognisable from the existing uart_top layout
- Clock tree — visible as a spine of buffers running horizontally
- Power grid — met4/met5 stripes for VDD/VSS

---

## Running the Existing UART IP Flow (unchanged)

```bash
./flow.tcl -design /path/to/UART_VLSI_Project/OpenLane/openlane
```

The UART IP flow is independent of the SoC flow and continues to work
exactly as before. Both flows share the same RTL directory but have
separate OpenLane configurations.
