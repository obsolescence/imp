# IMP replica — front panel

Hardware and operating notes for the 1:2 scale replica of the BBN/Honeywell IMP
(the ARPANET Interface Message Processor), plus the code that drives its front
panel from a SIMH-based IMP simulator.

The panel is a matrix of LEDs and switches driven directly from Raspberry Pi
GPIOs, in the tradition of the PiDP machines: 3 LED rows, 3 switch rows and 16
shared columns, with a real-time multiplexing thread inside the simulator.

## Documents

- `doc/hardware.md` — the circuit: GPIO assignment, the diode matrix and why it
  exists, the Darlington LED-row driver, matrix maps, and the scan timing the
  driver must respect.
- `doc/operation.md` — what every lamp and switch means, its function on the
  original machine, and how the panel is operated.

## Installer

This repository lives in `/opt/imp`, like the other Obsolescence projects. The
installer derives every path from its own location, so a checkout elsewhere works
too, but `/opt/imp` is the convention and everything below assumes it.

```
./install.sh                 interactive menu
./install.sh --install       dependency check + install, then the privileges
./install.sh --privileges    re-apply setuid + cap_sys_nice (after every rebuild)
./install.sh --check         report the state of the machine, change nothing
DRY_RUN=1 ./install.sh       simulate the whole flow, change NOTHING
```

Same style as the agent-pdp1 installer: two-zone VT-100 screen, streaming log,
plain mode when there is no terminal, safe to re-run. It sets the two things the
panel driver needs — group `gpio` for `/dev/gpiomem`, and `cap_sys_nice` plus the
setuid bit on the simulator binary — and states that both must be re-applied
after every recompilation, because a new binary loses them.

## Test program

```
make                 # builds bin/imp-panel-test
make privileges      # cap_sys_nice + setuid on the binary (sudo, after every build)
bin/imp-panel-test   # TUI: reads the switches, drives the lamps
```

No root needed to run it if you are in group `gpio`.

Bring-up aids: `--static` holds every lamp on with no multiplexing at all — that
is the state to put a meter on; `--solid` lights everything through the normal
mux; `--headless N` runs N frames with the demo pattern and prints timing plus a
coverage check.

Keys: `q` quit, `d` demo pattern, `m` manual, `p` lamp walk, `space` pause.
The first time you move any switch it drops out of the demo pattern by itself:
from then on the 16-lamp row mirrors the 16 switches and RESET blanks it.

Patterns: the A row runs a synthetic instruction stream (6-bit command field,
10-bit address scanning 0..1023), IMP1-4 and IMP5-8 are two slow binary
counters, IMP9-24 show a two-lamp packet crossing the panel with a flash as it
arrives, and POWER_LED follows the power switch. `--headless N` runs N mux
frames without the TUI and prints timing plus a coverage check proving that all
41 lamps are exercised.

## Status

Documentation, installer and a panel test program. The simulator itself is not
here yet; the test program is the bring-up step before the panel driver moves
into it. Items that still need bench confirmation are listed at the end of each
document.

## Sources

- KiCad panel project (`imp-panel`): schematic, netlist, SVG plot.
- Honeywell, *Intermodem Processor System — Instruction Manual*, January 1970
  (the BBN IMP hardware manual; display panel controls and indicators).
- Honeywell, *DDP-516 Users Guide*, March 1967 (control console: registers,
  selectors, pushbuttons).
- The PiDP-10 front panel driver as the software template for the multiplexing
  thread.
