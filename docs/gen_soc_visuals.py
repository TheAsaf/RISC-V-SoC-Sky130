#!/usr/bin/env python3
"""Generate SoC-level visual assets for the README.

Produces:
  images/soc_architecture.png    — full SoC block diagram
  images/cpu_bus_waveform.png    — CPU fetch + UART write bus transaction
  images/interrupt_flow.png      — IRQ assert → ISR → clear waveform
"""

import os
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.patches import FancyBboxPatch
import numpy as np

IMG_DIR = os.path.join(os.path.dirname(__file__), "images")
os.makedirs(IMG_DIR, exist_ok=True)

# ---------------------------------------------------------------------------
# 1.  SoC Architecture Block Diagram
# ---------------------------------------------------------------------------

def gen_soc_architecture():
    fig, ax = plt.subplots(figsize=(16, 9))
    fig.patch.set_facecolor("#F8FAFC")
    ax.set_xlim(0, 16)
    ax.set_ylim(0, 9)
    ax.axis("off")

    # -----------------------------------------------------------------------
    # Colour palette
    # -----------------------------------------------------------------------
    CPU_EDGE,  CPU_FACE  = "#1E40AF", "#DBEAFE"
    BUS_EDGE,  BUS_FACE  = "#6B21A8", "#EDE9FE"
    SRAM_EDGE, SRAM_FACE = "#065F46", "#D1FAE5"
    UART_EDGE, UART_FACE = "#92400E", "#FFFBEB"
    TX_EDGE,   TX_FACE   = "#1E3A8A", "#BFDBFE"
    RX_EDGE,   RX_FACE   = "#7F1D1D", "#FEE2E2"
    FIFO_EDGE, FIFO_FACE = "#713F12", "#FEF3C7"
    REG_EDGE,  REG_FACE  = "#4338CA", "#E0E7FF"
    IRQ_COLOR = "#7C3AED"
    TXT_GRAY  = "#6B7280"

    def block(x, y, w, h, title, sub="", ec=CPU_EDGE, fc=CPU_FACE,
              title_size=11, sub_size=8, radius=0.25):
        rect = FancyBboxPatch(
            (x, y), w, h,
            boxstyle=f"round,pad=0,rounding_size={radius}",
            linewidth=1.8, edgecolor=ec, facecolor=fc, zorder=2,
        )
        ax.add_patch(rect)
        cy = y + h / 2 + (0.18 if sub else 0)
        ax.text(x + w / 2, cy, title, ha="center", va="center",
                fontsize=title_size, fontweight="bold", color=ec, zorder=3)
        if sub:
            ax.text(x + w / 2, y + h / 2 - 0.22, sub,
                    ha="center", va="center", fontsize=sub_size,
                    color=ec, alpha=0.75, zorder=3)

    def label(x, y, txt, color=TXT_GRAY, size=7.5, bold=False, style="normal"):
        ax.text(x, y, txt, ha="center", va="center", fontsize=size,
                color=color, fontweight="bold" if bold else "normal",
                fontstyle=style)

    def arrow(x1, y1, x2, y2, color, lbl="", bidir=False, lw=1.8,
              label_above=True):
        style = "<->" if bidir else "->"
        ax.annotate(
            "", xy=(x2, y2), xytext=(x1, y1),
            arrowprops=dict(arrowstyle=style, color=color,
                            lw=lw, mutation_scale=14),
            zorder=4,
        )
        if lbl:
            mx, my = (x1 + x2) / 2, (y1 + y2) / 2
            dy = 0.18 if label_above else -0.18
            ax.text(mx, my + dy, lbl, ha="center", fontsize=7,
                    color=color, fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.15", facecolor="white",
                              edgecolor="none", alpha=0.92), zorder=5)

    def hline(x1, x2, y, color, lbl="", lw=1.8):
        ax.plot([x1, x2], [y, y], color=color, lw=lw, zorder=4)
        if lbl:
            ax.text((x1 + x2) / 2, y + 0.16, lbl, ha="center",
                    fontsize=7, color=color, fontweight="bold",
                    bbox=dict(boxstyle="round,pad=0.12", facecolor="white",
                              edgecolor="none", alpha=0.9), zorder=5)

    def vline(x, y1, y2, color, lw=1.8):
        ax.plot([x, x], [y1, y2], color=color, lw=lw, zorder=4)

    # -----------------------------------------------------------------------
    # PicoRV32 CPU  (left column)
    # -----------------------------------------------------------------------
    block(0.4, 4.8, 3.2, 3.5, "PicoRV32", "RV32I CPU Core",
          ec=CPU_EDGE, fc=CPU_FACE, title_size=13, radius=0.3)
    for i, txt in enumerate(["ENABLE_IRQ = 1", "BARREL_SHIFTER = 1",
                              "no MUL / DIV", "STACKADDR = 0x400"]):
        label(2.0, 7.5 - i * 0.38, txt, color=CPU_EDGE, size=7.5)

    # -----------------------------------------------------------------------
    # soc_bus  (centre top)
    # -----------------------------------------------------------------------
    block(5.2, 6.2, 2.6, 1.8, "soc_bus", "address decoder",
          ec=BUS_EDGE, fc=BUS_FACE, title_size=11)
    label(6.5, 6.55, "SRAM sel: addr[31:10]==0", color=BUS_EDGE, size=6.5)
    label(6.5, 6.22, "UART sel: addr[31:4]==0x2000000", color=BUS_EDGE, size=6.5)

    # -----------------------------------------------------------------------
    # soc_sram  (top right)
    # -----------------------------------------------------------------------
    block(9.5, 6.2, 2.8, 1.8, "soc_sram", "1 KB  ·  256 × 32-bit",
          ec=SRAM_EDGE, fc=SRAM_FACE, title_size=11)
    label(10.9, 6.55, "0x0000 – 0x03FF", color=SRAM_EDGE, size=7)
    label(10.9, 6.20, "combinational read", color=SRAM_EDGE, size=7, style="italic")

    # -----------------------------------------------------------------------
    # uart_top container  (bottom right)
    # -----------------------------------------------------------------------
    rect_uart = FancyBboxPatch(
        (5.0, 0.4), 10.2, 5.2,
        boxstyle="round,pad=0,rounding_size=0.35",
        linewidth=2.0, edgecolor=UART_EDGE, facecolor=UART_FACE,
        zorder=1, linestyle="--",
    )
    ax.add_patch(rect_uart)
    ax.text(10.1, 5.45, "uart_top",
            ha="center", fontsize=13, fontweight="bold",
            color=UART_EDGE, zorder=3)

    # reg interface
    block(5.3, 3.4, 2.4, 1.6, "reg interface", "4 registers",
          ec=REG_EDGE, fc=REG_FACE, title_size=10)
    for i, (off, nm) in enumerate([("0x0", "TX_DATA"), ("0x1", "RX_DATA"),
                                    ("0x2", "STATUS"), ("0x3", "CTRL")]):
        label(6.5, 4.65 - i * 0.35, f"{off}  {nm}", color=REG_EDGE, size=6.8)

    # sync_fifo
    block(8.3, 3.4, 2.2, 1.6, "sync_fifo", "8-deep TX FIFO",
          ec=FIFO_EDGE, fc=FIFO_FACE, title_size=10)
    label(9.4, 3.80, "ptr-based  full/empty", color=FIFO_EDGE, size=6.5)
    label(9.4, 3.52, "fall-through read", color=FIFO_EDGE, size=6.5)

    # uart_tx
    block(11.2, 3.4, 2.4, 1.6, "uart_tx", "8N1 / 8E1 / 8O1",
          ec=TX_EDGE, fc=TX_FACE, title_size=10)
    label(12.4, 3.80, "baud rate generator", color=TX_EDGE, size=6.5)
    label(12.4, 3.52, "16-bit counter", color=TX_EDGE, size=6.5)

    # uart_rx
    block(8.3, 0.7, 2.4, 1.8, "uart_rx", "2-FF sync + mid-bit",
          ec=RX_EDGE, fc=RX_FACE, title_size=10)
    label(9.5, 1.10, "parity check", color=RX_EDGE, size=6.5)
    label(9.5, 0.82, "frame error detect", color=RX_EDGE, size=6.5)

    # -----------------------------------------------------------------------
    # Internal uart_top connections
    # -----------------------------------------------------------------------
    # reg → fifo
    arrow(7.7, 4.2, 8.3, 4.2, FIFO_EDGE, bidir=False)
    # fifo → uart_tx
    arrow(10.5, 4.2, 11.2, 4.2, TX_EDGE, bidir=False)
    # uart_rx → reg
    arrow(8.3, 1.58, 7.7, 3.4, RX_EDGE, bidir=False)

    # -----------------------------------------------------------------------
    # External pins
    # -----------------------------------------------------------------------
    # TX pin
    ax.annotate("", xy=(15.4, 4.2), xytext=(13.6, 4.2),
                arrowprops=dict(arrowstyle="->", color=TX_EDGE, lw=2.0,
                                mutation_scale=14), zorder=4)
    ax.text(15.55, 4.2, "TX", ha="left", va="center",
            fontsize=11, fontweight="bold", color=TX_EDGE)

    # RX pin
    ax.annotate("", xy=(10.7, 1.58), xytext=(15.4, 1.58),
                arrowprops=dict(arrowstyle="->", color=RX_EDGE, lw=2.0,
                                mutation_scale=14), zorder=4)
    ax.text(15.55, 1.58, "RX", ha="left", va="center",
            fontsize=11, fontweight="bold", color=RX_EDGE)

    # -----------------------------------------------------------------------
    # Main bus  CPU ↔ soc_bus
    # -----------------------------------------------------------------------
    arrow(3.6, 7.55, 5.2, 7.55, CPU_EDGE, "mem bus  32-bit", bidir=True, lw=2.2)

    # -----------------------------------------------------------------------
    # soc_bus ↔ soc_sram
    # -----------------------------------------------------------------------
    arrow(7.8, 7.55, 9.5, 7.55, SRAM_EDGE, "SRAM select", bidir=True, lw=2.0)

    # -----------------------------------------------------------------------
    # soc_bus ↔ uart_top  (vertical drop)
    # -----------------------------------------------------------------------
    vline(6.5, 6.2, 5.0, BUS_EDGE, lw=2.0)
    ax.annotate("", xy=(6.5, 5.0), xytext=(6.5, 6.2),
                arrowprops=dict(arrowstyle="->", color=BUS_EDGE, lw=2.0,
                                mutation_scale=14), zorder=4)
    ax.text(6.85, 5.55, "UART\nselect", ha="left", va="center",
            fontsize=7, fontweight="bold", color=BUS_EDGE,
            bbox=dict(boxstyle="round,pad=0.12", facecolor="white",
                      edgecolor="none", alpha=0.9), zorder=5)

    # -----------------------------------------------------------------------
    # IRQ path: uart_top → CPU
    # -----------------------------------------------------------------------
    # horizontal from uart_top left boundary to x=4.0
    ax.annotate(
        "", xy=(0.4, 5.55), xytext=(5.0, 5.55),
        arrowprops=dict(arrowstyle="->", color=IRQ_COLOR, lw=1.8,
                        mutation_scale=13,
                        connectionstyle="arc3,rad=0"),
        zorder=4,
    )
    ax.text(2.9, 5.72, "irq[0]", ha="center", fontsize=8,
            fontweight="bold", color=IRQ_COLOR,
            bbox=dict(boxstyle="round,pad=0.15", facecolor="#F5F3FF",
                      edgecolor=IRQ_COLOR, linewidth=0.8, alpha=0.95), zorder=5)

    # -----------------------------------------------------------------------
    # Clock / Reset label
    # -----------------------------------------------------------------------
    ax.text(2.0, 4.6, "clk 50 MHz  |  rst_n (sync)", ha="center",
            fontsize=8, color=TXT_GRAY, style="italic")

    # -----------------------------------------------------------------------
    # Address map inset
    # -----------------------------------------------------------------------
    ax.text(0.45, 3.7, "Memory Map", ha="left", fontsize=9,
            fontweight="bold", color="#374151")
    for i, (addr, name, col) in enumerate([
        ("0x0000 – 0x03FF", "SRAM (1 KB)", SRAM_EDGE),
        ("0x2000_0000 + 0x0", "UART TX_DATA", TX_EDGE),
        ("0x2000_0000 + 0x4", "UART RX_DATA", RX_EDGE),
        ("0x2000_0000 + 0x8", "UART STATUS", BUS_EDGE),
        ("0x2000_0000 + 0xC", "UART CTRL",   IRQ_COLOR),
    ]):
        y = 3.35 - i * 0.40
        ax.text(0.45, y, addr, ha="left", fontsize=7, color=col,
                fontweight="bold")
        ax.text(3.55, y, name, ha="right", fontsize=7, color=col)
    ax.plot([0.4, 3.6], [3.52, 3.52], color="#E5E7EB", lw=0.8)
    ax.plot([0.4, 3.6], [1.35, 1.35], color="#E5E7EB", lw=0.8)
    ax.plot([0.4, 0.4], [1.35, 3.52], color="#E5E7EB", lw=0.8)
    ax.plot([3.6, 3.6], [1.35, 3.52], color="#E5E7EB", lw=0.8)

    # -----------------------------------------------------------------------
    # Title
    # -----------------------------------------------------------------------
    ax.text(8.0, 8.7, "rv32_soc — System Architecture",
            ha="center", fontsize=16, fontweight="bold", color="#111827")
    ax.text(8.0, 8.30,
            "PicoRV32 RV32I  ·  1 KB SRAM  ·  UART IP (8N1/parity/FIFO)  ·  sky130  ·  50 MHz",
            ha="center", fontsize=9, color=TXT_GRAY)

    # -----------------------------------------------------------------------
    # Legend
    # -----------------------------------------------------------------------
    patches = [
        mpatches.Patch(fc=CPU_FACE,  ec=CPU_EDGE,  label="CPU Core"),
        mpatches.Patch(fc=BUS_FACE,  ec=BUS_EDGE,  label="Bus Decoder"),
        mpatches.Patch(fc=SRAM_FACE, ec=SRAM_EDGE, label="SRAM"),
        mpatches.Patch(fc=UART_FACE, ec=UART_EDGE, label="UART Peripheral"),
        mpatches.Patch(fc="#F5F3FF", ec=IRQ_COLOR, label="IRQ path"),
    ]
    ax.legend(handles=patches, loc="lower left", fontsize=8,
              framealpha=0.95, edgecolor="#E5E7EB",
              bbox_to_anchor=(0.0, 0.0))

    out = os.path.join(IMG_DIR, "soc_architecture.png")
    plt.tight_layout(pad=0)
    plt.savefig(out, dpi=180, bbox_inches="tight",
                facecolor="#F8FAFC", edgecolor="none")
    plt.close()
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# 2.  CPU Bus Transaction Waveform
# ---------------------------------------------------------------------------

def gen_cpu_bus_waveform():
    """Show: CPU fetches 3 instructions → SW to UART → TX serialises."""
    CLK = 10       # ns per clock
    BIT = 160      # ns per UART bit (CLKS_PER_BIT=16)

    # ----- Build synthetic-but-accurate signal arrays -----
    # All times in ns.  Source: actual SoC VCD timing.
    T_END = 1800

    def step_sig(transitions, t_end):
        """transitions = [(t, val), ...]  → xs, ys for plt.step."""
        ts, vs = [0], [transitions[0][1]]
        for t, v in transitions:
            ts.append(t)
            vs.append(v)
        ts.append(t_end)
        vs.append(vs[-1])
        return np.array(ts, float), np.array(vs, float)

    # clk (square wave 0-1700ns)
    clk_t, clk_v = [], []
    for i in range(180):
        clk_t += [i * CLK, i * CLK + CLK / 2]
        clk_v += [0, 1]
    clk_t, clk_v = np.array(clk_t, float), np.array(clk_v, float)

    # mem_addr — 3-bit symbolic encoding for display
    # 0 = x, 1 = 0x00 (reset fetch), 2 = SRAM fetch, 3 = UART write
    ADDR_X    = 0.5
    ADDR_SRAM = 0.75    # normalised vertical for "SRAM" bus lines
    ADDR_UART = 0.25    # normalised vertical for "UART" bus lines

    # From VCD (ns):
    #  270 fetch 0x00, 330 fetch 0x1C, 390 fetch 0x20, 450 fetch 0x24,
    #  510 fetch 0x28, 550 UART write, 610 fetch 0x2C, 710 UART write,
    #  870 UART CTRL write
    FETCH_TIMES  = [270, 330, 390, 450, 510]
    UART_WRITE_1 = 550   # 'U'=0x55
    UART_WRITE_2 = 710   # 'V'=0x56
    UART_CTRL    = 870   # CTRL=0x04 (irq_en)

    # mem_wstrb  0=read (fetch), 1=write (SW)
    wstrb_trans = [(0, 0), (FETCH_TIMES[0] - 10, 0),
                   (UART_WRITE_1 - 10, 1), (UART_WRITE_1 + CLK, 0),
                   (UART_WRITE_2 - 10, 1), (UART_WRITE_2 + CLK, 0),
                   (UART_CTRL - 10, 1),    (UART_CTRL + CLK, 0)]
    wstrb_t, wstrb_v = step_sig(wstrb_trans, T_END)

    # uart_tx:  idle HIGH, start-bit LOW at T_TX_START
    # FIFO loaded at 550ns, uart_tx controller picks up ~2 clocks later
    T_TX_START = UART_WRITE_1 + 2 * CLK      # ~570ns
    # 0xA5 data bits LSB-first not relevant here — show that TX goes active
    bits_U = [(0x55 >> i) & 1 for i in range(8)]  # 0x55 = 0,1,0,1,0,1,0,1 LSB-first
    uart_tx_trans = [(0, 1), (T_TX_START, 0)]   # START bit
    t_cur = T_TX_START + BIT
    for b in bits_U:
        uart_tx_trans.append((t_cur, b))
        t_cur += BIT
    uart_tx_trans.append((t_cur, 1))            # STOP bit + idle
    uart_tx_t, uart_tx_v = step_sig(uart_tx_trans, T_END)

    # ----------------------------------------------------------------
    fig, axes = plt.subplots(4, 1, figsize=(15, 6.0), sharex=True,
                              gridspec_kw={"hspace": 0.08,
                                           "height_ratios": [0.6, 1.0, 0.8, 1.0]})
    fig.patch.set_facecolor("white")

    C_CLK   = "#6B7280"
    C_ADDR  = "#6B21A8"
    C_WSTRB = "#065F46"
    C_TX    = "#2563EB"

    def style(ax):
        ax.set_facecolor("#FAFBFC")
        for sp in ax.spines.values():
            sp.set_visible(False)
        ax.tick_params(left=False, bottom=True, colors="#9CA3AF", labelsize=7)
        ax.grid(axis="y", color="#F3F4F6", lw=0.5)

    # ---- clk ----
    axes[0].step(clk_t, clk_v, where="post", color=C_CLK, lw=0.9)
    axes[0].set_ylim(-0.3, 1.6)
    axes[0].set_yticks([0, 1])
    axes[0].set_yticklabels(["0", "1"], fontsize=7, color=C_CLK)
    axes[0].set_ylabel("clk", fontsize=9, fontweight="bold", color=C_CLK,
                        rotation=0, labelpad=40, va="center")
    style(axes[0])

    # ---- mem_wstrb ----
    axes[1].step(wstrb_t, wstrb_v, where="post", color=C_WSTRB, lw=1.5)
    axes[1].fill_between(wstrb_t, 0, wstrb_v, step="post",
                          color=C_WSTRB, alpha=0.12)
    axes[1].set_ylim(-0.25, 1.70)
    axes[1].set_yticks([0, 1])
    axes[1].set_yticklabels(["read", "write"], fontsize=7, color=C_WSTRB)
    axes[1].set_ylabel("mem_wstrb", fontsize=9, fontweight="bold", color=C_WSTRB,
                        rotation=0, labelpad=62, va="center")
    style(axes[1])

    # ---- mem_addr annotations (bus-style) ----
    ax_addr = axes[2]
    ax_addr.set_ylim(-0.3, 1.6)
    ax_addr.set_yticks([])
    ax_addr.set_ylabel("mem_addr", fontsize=9, fontweight="bold", color=C_ADDR,
                        rotation=0, labelpad=62, va="center")
    style(ax_addr)

    def bus_segment(ax, t1, t2, label, color, y_top=1.0):
        y_bot = 0.0
        # trapezoid / bus chevron
        ax.fill_between([t1, t2], y_bot, y_top, color=color, alpha=0.15)
        ax.plot([t1, t2, t2, t1, t1], [y_bot, y_bot, y_top, y_top, y_bot],
                color=color, lw=1.2)
        ax.text((t1 + t2) / 2, (y_bot + y_top) / 2, label,
                ha="center", va="center", fontsize=7, color=color,
                fontweight="bold")

    # Instruction fetches (grouped)
    bus_segment(ax_addr, FETCH_TIMES[0], FETCH_TIMES[-1] + 30,
                "SRAM fetch  0x00 → 0x28", "#6B21A8")
    bus_segment(ax_addr, UART_WRITE_1 - 8, UART_WRITE_1 + 30,
                "UART_TX  0x55 ('U')", "#2563EB")
    bus_segment(ax_addr, UART_WRITE_2 - 8, UART_WRITE_2 + 30,
                "UART_TX  0x56 ('V')", "#2563EB")
    bus_segment(ax_addr, UART_CTRL - 8, UART_CTRL + 30,
                "UART_CTRL", "#7C3AED")
    # Idle / fetch gaps
    ax_addr.fill_between([0, FETCH_TIMES[0] - 8], 0, 1,
                          color="#E5E7EB", alpha=0.5)
    ax_addr.text(135, 0.5, "reset", ha="center", va="center",
                 fontsize=7, color="#9CA3AF", style="italic")

    # ---- uart_tx ----
    axes[3].step(uart_tx_t, uart_tx_v, where="post", color=C_TX, lw=1.6)
    axes[3].fill_between(uart_tx_t, 0, uart_tx_v, step="post",
                          color=C_TX, alpha=0.10)
    axes[3].set_ylim(-0.3, 1.75)
    axes[3].set_yticks([0, 1])
    axes[3].set_yticklabels(["0", "1"], fontsize=7, color=C_TX)
    axes[3].set_ylabel("uart_tx", fontsize=9, fontweight="bold", color=C_TX,
                        rotation=0, labelpad=52, va="center")
    style(axes[3])

    # Annotate uart_tx segments
    axes[3].text(T_TX_START + 0.5 * BIT, 1.52, "START",
                 ha="center", fontsize=6.5, color="#16A34A", fontweight="bold")
    axes[3].text(T_TX_START + 4.5 * BIT, 1.52, "DATA  (0x55 = 'U'  LSB-first)",
                 ha="center", fontsize=6.5, color=C_TX, fontweight="bold")
    axes[3].axvline(T_TX_START, color="#16A34A", lw=0.8, linestyle=":")
    axes[3].axvline(T_TX_START + BIT, color="#E5E7EB", lw=0.6, linestyle=":")
    axes[3].text(460, 1.52, "IDLE", ha="center", fontsize=7.5,
                 color="#9CA3AF", style="italic")

    # ----- Shared vertical markers for UART writes -----
    for ax in axes:
        ax.axvline(UART_WRITE_1, color="#2563EB", lw=0.7, linestyle="--", alpha=0.5)
        ax.axvline(UART_WRITE_2, color="#2563EB", lw=0.7, linestyle="--", alpha=0.5)

    axes[1].annotate("SW 'U'\nto UART",
                     xy=(UART_WRITE_1, 1.0), xytext=(UART_WRITE_1 + 30, 1.45),
                     fontsize=6.5, color="#2563EB", fontweight="bold",
                     arrowprops=dict(arrowstyle="->", color="#2563EB", lw=0.8))
    axes[1].annotate("SW 'V'\nto UART",
                     xy=(UART_WRITE_2, 1.0), xytext=(UART_WRITE_2 + 30, 1.45),
                     fontsize=6.5, color="#2563EB", fontweight="bold",
                     arrowprops=dict(arrowstyle="->", color="#2563EB", lw=0.8))

    axes[-1].set_xlabel("Time (ns)", fontsize=9, color="#6B7280")
    axes[-1].set_xlim(0, T_END)
    axes[-1].xaxis.set_tick_params(labelsize=8)

    fig.suptitle(
        "CPU Bus Transaction: Instruction Fetch  →  SW to UART  →  Serial TX",
        fontsize=12, fontweight="bold", color="#111827", y=1.01,
    )

    out = os.path.join(IMG_DIR, "cpu_bus_waveform.png")
    plt.savefig(out, dpi=180, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close()
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# 3.  Interrupt Flow Waveform
# ---------------------------------------------------------------------------

def gen_interrupt_flow():
    """IRQ assert → CPU jumps to ISR → ISR reads RX_DATA → IRQ clears."""
    # Times from actual SoC VCD (ns):
    CLK = 10
    BIT = 160     # ns per UART bit at CLKS_PER_BIT=16

    # uart_rx injection: 8N1 frame with 0xA5, ending at ~9990ns
    # irq_out HIGH at 10010ns (from VCD)
    # ISR fetch at 0x10:  10090ns
    # ISR reads RX_DATA:  10250ns
    # irq_out LOW:        10270ns
    T_IRQ_HIGH    = 10_010
    T_IRQ_LOW     = 10_270
    T_ISR_FETCH   = 10_090
    T_ISR_RX_READ = 10_250
    T_MAIN_RESUME = 10_350

    # uart_rx injection: 10 bit periods ending at 9990ns
    T_RX_STOP   = 9_990
    T_RX_START  = T_RX_STOP - 10 * BIT   # 8390ns
    bits_A5 = [(0xA5 >> i) & 1 for i in range(8)]

    # Build uart_rx signal
    rx_events = [(0, 1), (T_RX_START, 0)]      # start bit
    t = T_RX_START + BIT
    for b in bits_A5:
        rx_events.append((t, b))
        t += BIT
    rx_events.append((t, 1))                    # stop bit / idle

    def step_sig(events, t_end):
        ts = [0]; vs = [events[0][1]]
        for ev_t, ev_v in events:
            ts.append(ev_t); vs.append(ev_v)
        ts.append(t_end); vs.append(vs[-1])
        return np.array(ts, float), np.array(vs, float)

    T_END = 11_000
    T_START = 7_800

    rx_t, rx_v = step_sig(rx_events, T_END)

    # irq_out
    irq_events = [(0, 0), (T_IRQ_HIGH, 1), (T_IRQ_LOW, 0)]
    irq_t, irq_v = step_sig(irq_events, T_END)

    # mem_addr (symbolic): 0=spin, 0.5=0x10 ISR, 0.75=0x1x ISR continuation, 1=RX_DATA
    # We'll show it as 4 states with labeled bands
    SPIN_ADDR   = 0x3C
    ISR_ENTRY   = 0x10
    ISR_CONT1   = 0x14
    ISR_CONT2   = 0x18
    UART_RX_REG = 0x20000004

    # -----------------------------------------------------------------------
    fig, axes = plt.subplots(3, 1, figsize=(15, 5.5), sharex=True,
                              gridspec_kw={"hspace": 0.08,
                                           "height_ratios": [1.2, 0.8, 1.0]})
    fig.patch.set_facecolor("white")

    C_RX  = "#7C3AED"
    C_IRQ = "#DC2626"
    C_MEM = "#065F46"

    def style(ax):
        ax.set_facecolor("#FAFBFC")
        for sp in ax.spines.values(): sp.set_visible(False)
        ax.tick_params(left=False, bottom=True, colors="#9CA3AF", labelsize=7)
        ax.grid(axis="y", color="#F3F4F6", lw=0.5)

    # ---- uart_rx ----
    mask = (rx_t >= T_START) & (rx_t <= T_END)
    axes[0].step(rx_t[mask], rx_v[mask], where="post", color=C_RX, lw=1.6)
    axes[0].fill_between(rx_t[mask], 0, rx_v[mask],
                          step="post", color=C_RX, alpha=0.10)
    axes[0].set_ylim(-0.3, 1.75)
    axes[0].set_yticks([0, 1])
    axes[0].set_yticklabels(["0", "1"], fontsize=7, color=C_RX)
    axes[0].set_ylabel("uart_rx", fontsize=9, fontweight="bold", color=C_RX,
                        rotation=0, labelpad=52, va="center")
    style(axes[0])

    # Annotate RX frame
    axes[0].axvline(T_RX_START, color="#E5E7EB", lw=0.7, linestyle=":")
    axes[0].text(T_RX_START + 0.5 * BIT, 1.52, "START",
                 ha="center", fontsize=6.5, color="#16A34A", fontweight="bold")
    axes[0].text(T_RX_START + 4.5 * BIT, 1.52, "0xA5  (injected byte)",
                 ha="center", fontsize=7, color=C_RX, fontweight="bold")
    axes[0].text(T_RX_STOP + 0.5 * BIT, 1.52, "STOP",
                 ha="center", fontsize=6.5, color="#16A34A", fontweight="bold")

    # idle before and after
    axes[0].text((T_START + T_RX_START) / 2, 0.5, "IDLE",
                 ha="center", fontsize=8, color="#9CA3AF", style="italic")
    axes[0].text((T_RX_STOP + BIT + T_IRQ_HIGH + 50) / 2, 0.5, "IDLE",
                 ha="center", fontsize=8, color="#9CA3AF", style="italic")

    # ---- irq_out ----
    mask2 = (irq_t >= T_START) & (irq_t <= T_END)
    axes[1].step(irq_t[mask2], irq_v[mask2], where="post", color=C_IRQ, lw=2.0)
    axes[1].fill_between(irq_t[mask2], 0, irq_v[mask2],
                          step="post", color=C_IRQ, alpha=0.15)
    axes[1].set_ylim(-0.3, 1.75)
    axes[1].set_yticks([0, 1])
    axes[1].set_yticklabels(["0", "1"], fontsize=7, color=C_IRQ)
    axes[1].set_ylabel("irq_out", fontsize=9, fontweight="bold", color=C_IRQ,
                        rotation=0, labelpad=52, va="center")
    style(axes[1])

    axes[1].annotate("irq assert\n(rx_ready=1)", xy=(T_IRQ_HIGH, 1.0),
                     xytext=(T_IRQ_HIGH - 250, 1.48),
                     fontsize=7, color=C_IRQ, fontweight="bold",
                     arrowprops=dict(arrowstyle="->", color=C_IRQ, lw=1.0))
    axes[1].annotate("irq clear\n(RX_DATA read)", xy=(T_IRQ_LOW, 1.0),
                     xytext=(T_IRQ_LOW + 60, 1.48),
                     fontsize=7, color="#16A34A", fontweight="bold",
                     arrowprops=dict(arrowstyle="->", color="#16A34A", lw=1.0))
    axes[1].text((T_IRQ_HIGH + T_IRQ_LOW) / 2, 0.5,
                 "LEVEL HIGH\nuntil ISR reads", ha="center",
                 fontsize=6.5, color=C_IRQ, fontweight="bold")

    # ---- mem_addr bus diagram ----
    ax3 = axes[2]
    ax3.set_ylim(-0.3, 1.6)
    ax3.set_yticks([])
    ax3.set_ylabel("mem_addr", fontsize=9, fontweight="bold", color=C_MEM,
                    rotation=0, labelpad=62, va="center")
    style(ax3)

    def seg(t1, t2, lbl, color):
        ax3.fill_between([t1, t2], 0, 1, color=color, alpha=0.15)
        ax3.plot([t1, t2, t2, t1, t1], [0, 0, 1, 1, 0], color=color, lw=1.1)
        ax3.text((t1 + t2) / 2, 0.5, lbl, ha="center", va="center",
                 fontsize=7, color=color, fontweight="bold")

    seg(T_START,       T_IRQ_HIGH - 10, "0x3C  main() spin", "#6B7280")
    seg(T_ISR_FETCH,   T_ISR_FETCH + 50, "0x10 ISR", "#7C3AED")
    seg(T_ISR_FETCH+60, T_ISR_FETCH+120, "0x14", "#7C3AED")
    seg(T_ISR_FETCH+130,T_ISR_RX_READ-10,"0x18", "#7C3AED")
    seg(T_ISR_RX_READ, T_ISR_RX_READ + 60, "RX_DATA\n0x2000_0004", "#2563EB")
    seg(T_MAIN_RESUME, T_END,  "0x3C  main() resumed", "#6B7280")

    # gap between spin end and ISR start (CPU taking interrupt)
    ax3.fill_between([T_IRQ_HIGH - 10, T_ISR_FETCH], 0, 1,
                      color="#E5E7EB", alpha=0.6)
    ax3.text((T_IRQ_HIGH - 10 + T_ISR_FETCH) / 2, 0.5,
             "CPU takes\ninterrupt", ha="center", fontsize=6.5,
             color="#9CA3AF", style="italic")

    # Labels for each address
    ax3.annotate("ISR saves context\nfetches handler code",
                 xy=(T_ISR_FETCH + 100, 1.0), xytext=(T_ISR_FETCH + 100, 1.38),
                 fontsize=6.5, color="#7C3AED", ha="center",
                 arrowprops=dict(arrowstyle="->", color="#7C3AED", lw=0.8))
    ax3.annotate("ISR reads UART_RX\nirq deasserts",
                 xy=(T_ISR_RX_READ + 30, 1.0), xytext=(T_ISR_RX_READ + 30, 1.38),
                 fontsize=6.5, color="#2563EB", ha="center",
                 arrowprops=dict(arrowstyle="->", color="#2563EB", lw=0.8))

    axes[-1].set_xlabel("Time (ns)", fontsize=9, color="#6B7280")
    axes[-1].set_xlim(T_START, T_END)
    axes[-1].xaxis.set_tick_params(labelsize=8)

    # Shared vertical markers
    for ax in axes:
        ax.axvline(T_IRQ_HIGH,    color=C_IRQ,    lw=0.8, linestyle="--", alpha=0.45)
        ax.axvline(T_ISR_FETCH,   color="#7C3AED", lw=0.8, linestyle="--", alpha=0.45)
        ax.axvline(T_ISR_RX_READ, color="#2563EB", lw=0.8, linestyle="--", alpha=0.45)
        ax.axvline(T_IRQ_LOW,     color="#16A34A", lw=0.8, linestyle="--", alpha=0.45)
        ax.axvline(T_MAIN_RESUME, color="#6B7280", lw=0.8, linestyle="--", alpha=0.35)

    fig.suptitle(
        "Interrupt Flow: RX Byte Received  →  IRQ  →  ISR  →  IRQ Clear",
        fontsize=12, fontweight="bold", color="#111827", y=1.01,
    )

    out = os.path.join(IMG_DIR, "interrupt_flow.png")
    plt.savefig(out, dpi=180, bbox_inches="tight",
                facecolor="white", edgecolor="none")
    plt.close()
    print(f"  Saved: {out}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    print("Generating SoC visual assets...")
    gen_soc_architecture()
    gen_cpu_bus_waveform()
    gen_interrupt_flow()
    print("Done.")
