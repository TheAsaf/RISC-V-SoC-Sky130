// ============================================================================
// File:    main.c
// Project: rv32_soc firmware
// Description:
//   Demonstration firmware for rv32_soc.  Exercises every major path in the
//   system:
//     1. UART polled transmit   — "rv32_soc boot\r\n"
//     2. UART interrupt receive — enable IRQ, wait for a byte, echo it back
//        with a hex annotation: "rx: XX\r\n"
//     3. Continuous echo loop   — main loop echoes all subsequent bytes
//
//   Designed to be meaningful as a simulation target and as real firmware on
//   silicon.  Assumes:
//     - Single clock domain at 50 MHz, CLKS_PER_BIT = 434 (115200 baud)
//     - 1 KB SRAM at 0x00000000 (code + stack + BSS)
//     - UART at 0x20000000 (see memory map in architecture doc)
//     - PicoRV32 ENABLE_IRQ=1, ENABLE_IRQ_QREGS=0
//
// ============================================================================

#include <stdint.h>
#include "uart_drv.h"

// ============================================================================
// IRQ ring buffer (definition — declared extern in uart_drv.h)
// ============================================================================
volatile uint8_t  irq_rx_buf[IRQ_RX_BUF_SIZE];
volatile uint32_t irq_rx_head = 0;
volatile uint32_t irq_rx_tail = 0;

// ============================================================================
// irq_handler — called from _irq_entry in start.S
//
// Arguments:
//   pending — IRQ-pending bitmap from PicoRV32 x4 (tp) register.
//             Bit i is set if irq[i] was asserted when the CPU was interrupted.
//
// We only have one interrupt source: irq[0] = UART RX ready.
// The handler reads RX_DATA (which clears rx_ready and thus deasserts irq[0]),
// then deposits the byte in the ring buffer.
//
// If the ring buffer is full, the byte is silently dropped.  In a real system
// this is a firmware bug (main() not draining fast enough); here it signals
// that the buffer sizing needs to increase.  We note it with a flag rather
// than blocking (an ISR must never block).
//
// volatile on irq_rx_head: the compiler must not cache this across the ISR
// boundary, because main() observes it without an explicit barrier.
// ============================================================================
void irq_handler(uint32_t pending)
{
    if (pending & (1U << 0)) {   // UART IRQ — irq[0]
        uint8_t byte = (uint8_t)(UART_RX & 0xFF);  // read clears rx_ready

        uint32_t next_head = (irq_rx_head + 1) & IRQ_RX_BUF_MASK;
        if (next_head != irq_rx_tail) {
            // Ring buffer has space — deposit byte
            irq_rx_buf[irq_rx_head & IRQ_RX_BUF_MASK] = byte;
            irq_rx_head = next_head;
        }
        // else: buffer full — byte dropped (not ideal; acceptable for demo)
    }
}

// ============================================================================
// Helper: print "str: XX\r\n" where XX is the hex value of byte
// Keeps main() readable.
// ============================================================================
static void print_rx_byte(uint8_t byte)
{
    uart_puts("rx: ");
    uart_put_hex8(byte);
    uart_newline();
}

// ============================================================================
// main
//
// Sequence:
//   1. Boot message via polled TX
//   2. Enable UART IRQ + unmask PicoRV32 IRQ lines
//   3. Wait for first IRQ-received byte, echo it with annotation
//   4. Echo loop — all subsequent received bytes echoed as "rx: XX\r\n"
//      plus the raw byte (so a terminal sees both the annotation and the
//      character itself)
// ============================================================================
int main(void)
{
    int c;

    // -----------------------------------------------------------------------
    // 1. Boot banner — polled TX
    //    Each uart_putc() spins on fifo_full before writing.
    //    At 50 MHz / 115200 baud, each byte takes 434 cycles; the FIFO is
    //    8 deep, so we can burst up to 8 bytes without spinning.
    // -----------------------------------------------------------------------
    uart_puts("rv32_soc boot");
    uart_newline();

    // -----------------------------------------------------------------------
    // 2. Enable interrupt-driven RX
    //    Sets UART_CTRL.irq_en=1 and calls maskirq x0,x0 to set irq_mask=0.
    //    After this returns, any received byte will fire irq[0].
    // -----------------------------------------------------------------------
    uart_irq_enable();

    // -----------------------------------------------------------------------
    // 3. Wait for first byte, echo with annotation
    //    Busy-waits on the ring buffer.  In a real RTOS this would be a
    //    semaphore pend or a WFI instruction; for bare-metal demo it's a
    //    spin — the CPU is small and has nothing else to do.
    // -----------------------------------------------------------------------
    uart_puts("waiting for rx...");
    uart_newline();

    while (!uart_irq_available())
        ;

    c = uart_irq_getc();
    print_rx_byte((uint8_t)c);

    // -----------------------------------------------------------------------
    // 4. Echo loop — run indefinitely
    //    This is the steady-state behaviour of the SoC: receive a byte via
    //    interrupt, echo it back with a hex annotation.
    //    The loop also re-transmits the raw byte so an interactive terminal
    //    sees the character echoed (standard serial console behaviour).
    // -----------------------------------------------------------------------
    uart_puts("echo mode active");
    uart_newline();

    while (1) {
        while (!uart_irq_available())
            ;
        c = uart_irq_getc();
        print_rx_byte((uint8_t)c);
        uart_putc((uint8_t)c);   // raw echo for terminal
    }

    return 0;   // unreachable; _start will spin-halt if we ever get here
}
