# IMP front panel — build
#
# Plain make, no autotools: the same kind of build the SIMH simulator uses.
#
#   make              build bin/imp-panel-test
#   make privileges   give that binary cap_sys_nice (and the setuid bit the
#                     PiDP-10 binaries carry) — needs sudo, run after every build
#   make clean
#
# The test program needs no root when the user is in group 'gpio': the pinctrl
# library opens /dev/gpiomem, which is root:gpio 0660. The installer sets that
# group up. cap_sys_nice is a separate thing — it is what allows the multiplexing
# thread to take SCHED_FIFO.

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11
CFLAGS  += -Isrc/pinctrl -Isrc/panel
LDLIBS  += -lpthread

BIN  = bin/imp-panel-test

# Vendored pinctrl library (see src/pinctrl/README.md). The per-SoC backends are
# all compiled in; gpiolib picks one at runtime from the device tree.
PINCTRL_SRC = src/pinctrl/gpiolib.c \
              src/pinctrl/gpiochip_bcm2835.c \
              src/pinctrl/gpiochip_bcm2712.c \
              src/pinctrl/gpiochip_rp1.c \
              src/pinctrl/util.c

SRC = $(PINCTRL_SRC) src/panel/panel.c src/tester/panel-test.c
HDR = src/panel/panel.h src/pinctrl/gpiolib.h src/pinctrl/gpiochip.h src/pinctrl/util.h

all: $(BIN)

$(BIN): $(SRC) $(HDR)
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ $(SRC) $(LDLIBS)

# --- privileges ------------------------------------------------------------
#
# Why this is a target of its own and not part of 'all':
#   * both settings live in file metadata — the setuid bit in the inode mode and
#     cap_sys_nice in a file extended attribute — and the linker REPLACES the
#     file on every relink, so they are silently lost at each build. That is
#     exactly why it has to be re-applied after every rebuild;
#   * they need root, so wiring this into 'all' would make every 'make' demand a
#     password, which breaks building in a script or a CI job.
#
#   make && make privileges          (or: sudo make privileges)
#
privileges: $(BIN)
	@if getcap $(BIN) 2>/dev/null | grep -q cap_sys_nice && [ -u $(BIN) ]; then \
		echo "$(BIN): privileges already set (cap_sys_nice, setuid)"; \
	else \
		echo "$(BIN): setting setuid + cap_sys_nice"; \
		sudo chmod +s $(BIN) && \
		sudo setcap cap_sys_nice+ep $(BIN) && \
		ls -l $(BIN) && getcap $(BIN); \
	fi

clean:
	rm -f $(BIN)
	rmdir bin 2>/dev/null || true

.PHONY: all clean privileges
