# Docs — Diagrams, Waveforms, and Visualisations

This directory contains visual assets for the project and the Python scripts that generate them.

---

## Images

| File | What it shows |
|---|---|
| `images/architecture.svg` | UART IP block diagram: uart_top → uart_tx, uart_rx, sync_fifo |
| `images/register_map.svg` | UART register definitions and bit layouts |
| `images/uart_8n1_waveform.png` | Single byte TX/RX waveform — transmitting 0xA5 in 8N1 format |
| `images/uart_fifo_burst.png` | FIFO burst waveform — 4 bytes transmitted back-to-back |
| `images/gds_layout.png` | Physical chip layout viewed in KLayout (uart_tx module) |

---

## Regenerating Waveforms

The waveform PNGs are generated from a VCD (Value Change Dump) file produced by simulation:

```bash
# 1. Run the UART unit simulation to produce the VCD
cd ../tb
make sim

# 2. Generate waveform images from the VCD
cd ../docs
python3 gen_waveforms.py
```

The script `gen_waveforms.py` parses the VCD, extracts specific signal traces, and renders them as annotated PNG images using matplotlib.

---

## Regenerating Architecture Diagrams

```bash
cd docs
python3 gen_diagrams.py
```

This regenerates `images/architecture.svg` and `images/register_map.svg`.

---

## Understanding the Waveforms

### 8N1 Frame — transmitting 0xA5

0xA5 in binary is `1010 0101`. In UART, bits are sent LSB-first:

```
Bit order on wire:  1  0  1  0  0  1  0  1
                    b0 b1 b2 b3 b4 b5 b6 b7

Full frame:
uart_tx:  ─┐  ┌──┐  ┌─────┐  ┌──┐  ┌─┐
           │  │  │  │     │  │  │  │ │
         ──┘  └──┘  └─────┘  └──┘  └─┘───
          SB  1  0   1  0  0   1  0  1  STOP

SB = Start Bit (LOW), STOP = Stop Bit (HIGH)
```

### FIFO burst — 4 bytes

When 4 bytes are written to TX_DATA in rapid succession, the FIFO holds them. The serialiser drains one at a time with no idle gap between frames:

```
CPU writes:  [t=0] 0x11  [t=5] 0x22  [t=10] 0x33  [t=15] 0x44
FIFO:        [0x11][0x22][0x33][0x44][ ][ ][ ][ ]
uart_tx:     ──0x11──────────0x22──────────0x33──────────0x44────
                       (no gaps between frames)
```

Without the FIFO, the CPU would have to wait 4340 cycles between each write.

---

## Physical Layout

The `gds_layout.png` image shows the `uart_tx` module after full place-and-route through OpenLane on sky130 HD standard cells. What you can see:

- **Standard cells** — the small rectangular tiles are logic gates (AND, OR, flip-flops, buffers)
- **Metal routing** — the horizontal and vertical lines are wires connecting the cells
- **Clock tree** — the spine of clock buffers running through the design
- **Power grid** — the wider horizontal stripes are VDD/VSS power rails

The full `uart_top` (with UART RX, TX FIFO, and register interface) produces a proportionally larger layout — 145 cells across a 60×71 µm die area.

For the SoC (PicoRV32 + SRAM + UART), the dominant visual feature would be the behavioral SRAM's DFF array — a large rectangular block of ~8192 flip-flops.
