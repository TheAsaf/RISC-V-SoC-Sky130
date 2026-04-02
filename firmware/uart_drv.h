// ============================================================================
// File:    uart_drv.h
// Project: rv32_soc firmware
// Description:
//   Memory-mapped UART driver for uart_top peripheral at 0x20000000.
//
//   Provides:
//     - Register definitions (base address, offsets, bit masks)
//     - Polling transmit: uart_putc(), uart_puts(), uart_put_hex()
//     - Polling receive:  uart_getc()
//     - Interrupt control: uart_irq_enable(), uart_irq_disable()
//     - ISR hook: irq_rx_buf[] ring buffer, updated by irq_handler()
//
//   Design decisions:
//     - All register accesses use volatile uint32_t* to prevent the compiler
//       from caching or reordering memory-mapped I/O reads/writes.
//     - Transmit path spins on fifo_full before each write — this is the
//       correct policy for a UART with no hardware stall (see architecture
//       doc section 3: Backpressure & UART).
//     - Receive path: blocking uart_getc() polls rx_ready; for interrupt-
//       driven receive the ISR fills irq_rx_buf[] and main() drains it.
//     - No dynamic allocation, no stdlib dependency: this driver can run on
//       bare metal with only start.S as the C runtime.
// ============================================================================

#ifndef UART_DRV_H
#define UART_DRV_H

#include <stdint.h>

// ============================================================================
// Register map (byte offsets from UART_BASE, word-stride = 4 bytes)
// ============================================================================
#define UART_BASE       0x20000000UL

#define UART_TX         (*(volatile uint32_t *)(UART_BASE + 0x00))  // [W]    TX_DATA
#define UART_RX         (*(volatile uint32_t *)(UART_BASE + 0x04))  // [R]    RX_DATA
#define UART_STATUS     (*(volatile uint32_t *)(UART_BASE + 0x08))  // [RW1C] STATUS
#define UART_CTRL       (*(volatile uint32_t *)(UART_BASE + 0x0C))  // [RW]   CTRL

// STATUS register bit positions
#define STATUS_TX_BUSY    (1U << 0)  // serialiser is transmitting
#define STATUS_FIFO_EMPTY (1U << 1)  // TX FIFO empty (safe to send another burst)
#define STATUS_FIFO_FULL  (1U << 2)  // TX FIFO full  (must not write TX_DATA)
#define STATUS_RX_READY   (1U << 3)  // received byte waiting in RX_DATA
#define STATUS_FRAME_ERR  (1U << 4)  // W1C: bad stop bit detected
#define STATUS_PARITY_ERR (1U << 5)  // W1C: parity mismatch

// CTRL register bit positions
#define CTRL_PARITY_EN    (1U << 0)  // 0=8N1 (default), 1=parity enabled
#define CTRL_PARITY_ODD   (1U << 1)  // 0=even, 1=odd  (only valid if PARITY_EN)
#define CTRL_IRQ_EN       (1U << 2)  // assert irq when rx_ready=1

// ============================================================================
// Interrupt-driven RX ring buffer
//
// irq_handler() (in main.c) deposits received bytes here.
// main() or other code drains it with uart_irq_getc().
//
// Buffer size: power of two for cheap modulo with bitwise AND.
// Declared here as extern; defined in main.c.
// ============================================================================
#define IRQ_RX_BUF_SIZE  16   // must be power of two
#define IRQ_RX_BUF_MASK  (IRQ_RX_BUF_SIZE - 1)

extern volatile uint8_t  irq_rx_buf[IRQ_RX_BUF_SIZE];
extern volatile uint32_t irq_rx_head;  // producer index (written by ISR)
extern volatile uint32_t irq_rx_tail;  // consumer index (written by main)

// ============================================================================
// Transmit — polling
// ============================================================================

// Send one byte.  Spins on fifo_full before writing to prevent silent data
// loss (see architecture analysis: backpressure behaviour).
static inline void uart_putc(uint8_t c)
{
    while (UART_STATUS & STATUS_FIFO_FULL)
        ;
    UART_TX = c;
}

// Send a null-terminated string.
static inline void uart_puts(const char *s)
{
    while (*s)
        uart_putc((uint8_t)*s++);
}

// Send a newline (CRLF for terminal compatibility).
static inline void uart_newline(void)
{
    uart_putc('\r');
    uart_putc('\n');
}

// Send a 32-bit value as 8 hex digits, no prefix.
static inline void uart_put_hex32(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    int i;
    for (i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xF]);
}

// Send a byte as 2 hex digits.
static inline void uart_put_hex8(uint8_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    uart_putc(hex[(v >> 4) & 0xF]);
    uart_putc(hex[v & 0xF]);
}

// ============================================================================
// Receive — polling
// Blocks until rx_ready is set, then reads RX_DATA (which clears rx_ready).
// Use this only in polling mode (when IRQ is disabled).
// ============================================================================
static inline uint8_t uart_getc(void)
{
    while (!(UART_STATUS & STATUS_RX_READY))
        ;
    return (uint8_t)(UART_RX & 0xFF);
}

// ============================================================================
// Receive — interrupt-driven ring buffer
// Returns -1 if buffer is empty, else the next byte (0–255).
// Non-blocking: caller must handle the -1 case.
// ============================================================================
static inline int uart_irq_getc(void)
{
    if (irq_rx_tail == irq_rx_head)
        return -1;
    uint8_t c = irq_rx_buf[irq_rx_tail & IRQ_RX_BUF_MASK];
    irq_rx_tail++;
    return c;
}

// Returns 1 if at least one byte is available in the IRQ ring buffer.
static inline int uart_irq_available(void)
{
    return irq_rx_head != irq_rx_tail;
}

// ============================================================================
// Interrupt control
// ============================================================================

// Enable UART RX interrupt and unmask all PicoRV32 IRQ lines.
// Call this when main() is ready to receive interrupt-driven bytes.
// The maskirq instruction is a PicoRV32 custom instruction —
// it cannot be expressed in standard C; we use inline assembly.
static inline void uart_irq_enable(void)
{
    UART_CTRL = CTRL_IRQ_EN;    // set irq_en in UART peripheral

    // maskirq x0, x0  →  irq_mask = 0  (unmask all 32 IRQ lines)
    // PicoRV32 resets with irq_mask = ~0 (fully masked).
    // Without this call, no interrupt will ever be delivered.
    // Encoding: 0x0600000B  (verified: picorv32.v line 1092, 1682)
    __asm__ volatile (".word 0x0600000B" ::: "memory");
}

// Mask all PicoRV32 interrupts (does NOT clear UART_CTRL.irq_en).
// maskirq x0, t0 where t0=~0  →  irq_mask = ~0
static inline void uart_irq_disable(void)
{
    register uint32_t all_ones __asm__("t0") = ~0U;
    (void)all_ones;
    __asm__ volatile (".word 0x0620000B" ::: "memory");
    // 0x0620000B: maskirq x0, t0  (t0=x5, bits[19:15]=00101)
    // Result: irq_mask = ~0, old mask returned in x0 (discarded)
}

// Clear sticky error flags (W1C: write 1 to clear).
static inline void uart_clear_errors(void)
{
    UART_STATUS = STATUS_FRAME_ERR | STATUS_PARITY_ERR;
}

#endif // UART_DRV_H
