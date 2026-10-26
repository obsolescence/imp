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

## Status

Documentation and installer first, driver to follow. Everything electrical is
derived from the KiCad project for the panel; items that still need bench
confirmation are listed at the end of each document. The installer's build step
is a placeholder until the simulator source lands, and says so.

## Sources

- KiCad panel project (`imp-panel`): schematic, netlist, SVG plot.
- Honeywell, *Intermodem Processor System — Instruction Manual*, January 1970
  (the BBN IMP hardware manual; display panel controls and indicators).
- Honeywell, *DDP-516 Users Guide*, March 1967 (control console: registers,
  selectors, pushbuttons).
- The PiDP-10 front panel driver as the software template for the multiplexing
  thread.
