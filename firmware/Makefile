# ============================================================================
# Firmware Makefile for rv32_soc
# ============================================================================
# Two build paths:
#
#   Path A — RISC-V cross-compiler (preferred, when available):
#     make        → compiles start.S + main.c, links, produces firmware.hex
#     Detects toolchain automatically; falls back to Path B if not found.
#
#   Path B — Python generator (no toolchain required):
#     make python  → python3 firmware.py --verbose
#     Always available; produces identical observable behaviour to Path A.
#
# Targets:
#   make / make all    — auto-detect and build
#   make gcc           — force GCC path (error if toolchain not found)
#   make python        — force Python path
#   make verbose       — Python path with full listing
#   make clean         — remove generated files
#   make size          — show firmware size breakdown (requires GCC path)
# ============================================================================

# ---- Toolchain detection ----
# Try common prefixes in order; pick the first that exists.
CROSS_CANDIDATES := riscv32-unknown-elf riscv64-unknown-elf \
                    riscv32-elf riscv-none-embed
CROSS := $(firstword $(foreach p,$(CROSS_CANDIDATES),\
           $(if $(shell which $(p)-gcc 2>/dev/null),$(p),)))

CC      := $(CROSS)-gcc
OBJCOPY := $(CROSS)-objcopy
OBJDUMP := $(CROSS)-objdump
SIZE    := $(CROSS)-size

# ---- Compiler flags ----
# -march=rv32i     — RV32I only (no M, C, F, D extensions)
# -mabi=ilp32      — 32-bit integers, longs, and pointers; no FP ABI
# -Os              — optimise for size (1 KB SRAM is tight)
# -ffreestanding   — no stdlib assumptions
# -nostdlib        — no standard startup files or libraries
# -fno-builtin     — prevent GCC from substituting memcpy/memset calls
#                    (we have no libc to provide them)
# -Wall -Wextra    — treat warnings seriously
CFLAGS := -march=rv32i -mabi=ilp32 -Os -ffreestanding -nostdlib \
          -fno-builtin -Wall -Wextra -g

LDFLAGS := -T link.ld -nostdlib

SRCS := start.S main.c
OBJS := $(patsubst %.c,%.o,$(patsubst %.S,%.o,$(SRCS)))
ELF  := firmware.elf
BIN  := firmware.bin
HEX  := firmware.hex

.PHONY: all gcc python verbose clean size check

# ---- Default: auto-detect ----
all:
	@if [ -n "$(CROSS)" ]; then \
	    echo "Toolchain found: $(CROSS)-gcc"; \
	    $(MAKE) gcc; \
	else \
	    echo "No RISC-V toolchain found — using Python generator"; \
	    echo "To install: brew install riscv-gnu-toolchain (macOS)"; \
	    echo "            apt install gcc-riscv64-unknown-elf (Ubuntu)"; \
	    $(MAKE) python; \
	fi

# ---- Path A: GCC ----
gcc: $(HEX)
	@echo "GCC build complete: $(HEX)"

$(ELF): $(OBJS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

%.o: %.S
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

# Convert ELF to Verilog $readmemh hex (32-bit words, little-endian)
# riscv-elf2hex is part of the freedom-tools distribution; if unavailable,
# we use a Python one-liner to convert the raw binary instead.
$(HEX): $(BIN)
	@if command -v riscv32-unknown-elf-elf2hex >/dev/null 2>&1; then \
	    riscv32-unknown-elf-elf2hex --bit-width 32 --input $< --output $@; \
	else \
	    python3 -c "\
import sys, struct;\
data=open('$(BIN)','rb').read();\
data+=b'\\x13\\x00\\x00\\x00'*((-len(data))%4);\
[print(f'{struct.unpack_from(\"<I\",data,i)[0]:08x}') for i in range(0,len(data),4)]" > $@; \
	fi
	@echo "GCC path: $(HEX) ready"

size: $(ELF)
	$(SIZE) $<
	@echo ""
	$(OBJDUMP) -d -M no-aliases $< | head -100

# ---- Path B: Python (toolchain-free) ----
python: $(HEX)_python
	@cp $(HEX)_python $(HEX)
	@echo "Python path: $(HEX) ready"

$(HEX)_python: firmware.py
	python3 firmware.py --out $@

verbose:
	python3 firmware.py --verbose --out $(HEX)

# ---- Verification ----
check: $(HEX)
	@echo "Checking critical firmware words..."
	@python3 -c "\
lines=[l.strip() for l in open('$(HEX)') if l.strip() and not l.startswith('/')];\
w=lambda i: int(lines[i],16);\
ok=True;\
checks=[(0,0x01C0006F,'word[0] JAL x0,_start'),\
        (4,0x200000B7,'word[4] LUI x1,0x20000'),\
        (6,0x0400000B,'word[6] retirq')];\
[print(f'  PASS: {m}') if w(i)==e else (print(f'  FAIL: {m}: expected 0x{e:08X} got 0x{w(i):08X}'), setattr(sys.modules[__name__],'ok',False)) for i,e,m in checks];\
print('check: PASS' if ok else 'check: FAIL')\
"

# ---- Cleanup ----
clean:
	rm -f $(OBJS) $(ELF) $(BIN) $(HEX) $(HEX)_python *.d
