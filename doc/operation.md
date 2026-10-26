# Front panel — controls, indicators and operation

This is what the panel *means*: every lamp, every switch, what it did on the
original machine, and how an operator uses it.

## 1. What this panel is

The original IMP had **two separate front panels**, and the replica fuses them
into one board:

- the **IMP display panel** (assembly B8): 24 status indicators and four option
  toggles, added by BBN to the standard machine;
- the **DDP-516 control console** (assembly A8): the 16-bit register display, the
  16 data switches, the operator row, and the power controls.

Sources:

- Honeywell, *Intermodem Processor System — Instruction Manual*, January 1970,
  prepared for Bolt, Beranek and Newman. Table 3-1 (display panel controls and
  indicators) and the option descriptions in section IV.
- Honeywell, *DDP-516 Users Guide*, March 1967. Section II and Tables 2-1
  (registers displayed), 2-2 (pushbuttons), 2-3 (selector switches), 2-4 (OP
  display).

Where the replica differs from the original, it is called out and the reason
given.

## 2. Layout

Top half, left to right:

```
  +-------------------------------------------------------------+
  | IMP24 ... IMP13   (row 2, 12 lamps)                          |
  | [ONOFF][WDT][AUTO][MEM]   IMP12 ... IMP1   (row 1, 12 lamps) |
  +-------------------------------------------------------------+
  | A15 .............................. A0        [RESET]         |  16 lamps
  |  O   O   O   O   O   O   O   O   O   O   O   O   O   O  O  O |  16 switches
  +-------------------------------------------------------------+
  | [PWR][LED] [PFI] [S1][S2][S3][S4] [ROTARY] [MCLR][S/F][P+1][MA-SI-RUN][START] |
  +-------------------------------------------------------------+
```

The IMP bank runs with the column numbers increasing to the right (IMP1 is
leftmost); the A bank and the SR bank run the other way (col15 leftmost). That is
a layout fact only — the electrical map is in `hardware.md`.

## 3. Top half — IMP indicators and options

### 3.1 The 24 indicators

Per the IMP manual, Table 3-1: *"Indicators 1 through 16 display the data on the
output transfer bus (OTBxx)."*

- **IMP1..IMP16** therefore show the 16-bit word currently going out on the
  output transfer bus — the data path to the modems and hosts. This is the IMP's
  own bus display, not a CPU register.
- **IMP17..IMP24** are not described individually in the manual's table. The
  panel artwork and the simulator's status sources will decide what they show;
  treated as open until then.
- **IMP1..IMP8** (the top-left group of eight) are reserved for two octal fields
  of four lamps each. Not implemented yet.

The replica drives these from simulator state, not from real hardware, so what
they show is a decision for the simulator glue (see section 7).

### 3.2 The four option switches

All four are toggles, all four are **up = ON**, and each one enables a hardware
option that the IMP carried. None of them is read by the program as an input
bit; they gate hardware.

| Switch | Manual designation | Type | Function (manual) |
|---|---|---|---|
| ONOFF-HALTINH | HALT INH | SPDT toggle | Enables the halt inhibit logic when set to ON |
| WDT | W.D.T. | SPDT toggle | Allows the watchdog timer option to be enabled when in the ON position |
| AUTORESTRT | AUTO RESTART | DPDT toggle | Enables the automatic restart circuit when set to ON |
| MEM.PRTCT | MEMORY PRTCT | SPDT toggle | Enables the memory lockout logic when set to ON |

What they mean in practice:

- **HALT INH.** With the option enabled, a HALT cannot stop the machine. This is
  how an IMP was guaranteed to keep running: the software was not trusted to
  avoid halting, the switch was.
- **W.D.T.** The watchdog timer must be kicked by the program; if the program
  stops kicking it, the hardware restarts the machine. The manual's own note on
  the reset instruction is explicit that it only works when the switch is up:
  *"OCP '0026 resets counter in watch dog timer if panel is in the up position."*
  This is the one option with a direct instruction-level tie to the panel.
- **MEMORY PRTCT / memory lockout.** Protects memory against writes so a runaway
  program cannot destroy critical data. On the IMP this option added protection
  for locations 60, 62 and Sector I; the standard machine separately protects the
  key-in loader area (locations 1-17 octal) unless the console is in MA mode.
- **AUTO RESTART.** Relay and program-start logic that brings the machine back
  after a power failure. Invisible to the program; it only acts at power loss.

Two of these, WDT and HALT INH, are the only switches on the whole panel that the
simulated machine has to *consult* rather than merely display.

## 4. Bottom half — the H316 control console

### 4.1 The 16-lamp register display

The lamps are dual-labelled: as register bits (1-16), and with the meanings of
the machine flip-flops that the same lamps show when the OP register is selected.

Left to right across the panel. "Honeywell bit" is the machine's own numbering,
in which bit 1 is the leftmost and most significant; the silkscreen uses the
modern numbering (A15 leftmost, A0 rightmost). Both describe the same lamp.

| Pos | Column | GPIO | Silkscreen | Honeywell bit | OP legend | OP meaning |
|---|---|---|---|---|---|---|
| 1  | col15 | 27 | A15 | 1  | T1 | timing level 1 |
| 2  | col14 | 26 | A14 | 2  | T2 | timing level 2 |
| 3  | col13 | 25 | A13 | 3  | T3 | timing level 3 |
| 4  | col12 | 24 | A12 | 4  | T4 | timing level 4 |
| 5  | col11 | 23 | A11 | 5  | F  | fetch cycle |
| 6  | col10 | 22 | A10 | 6  | I  | indirect cycle |
| 7  | col9  | 21 | A9  | 7  | A  | execute cycle |
| 8  | col8  | 20 | A8  | 8  | C  | c-bit (carry) |
| 9  | col7  | 19 | A7  | 9  | PI | permit interrupt |
| 10 | col6  | 18 | A6  | 10 | —  | unassigned |
| 11 | col5  | 17 | A5  | 11 | ML | memory lockout (option) |
| 12 | col4  | 16 | A4  | 12 | EA | extended addressing / bank switching (option) |
| 13 | col3  | 13 | A3  | 13 | DP | double precision (option) |
| 14 | col2  | 12 | A2  | 14 | —  | unassigned |
| 15 | col1  | 11 | A1  | 15 | MP | memory parity error |
| 16 | col0  | 10 | A0  | 16 | P  | I/O parity error |

Note the pitfall: "A" in the OP column is the *execute cycle*, not the A register.
The two unassigned positions are genuinely unassigned in the original, which is
why they are blank on the silkscreen.

### 4.2 The rotary — register select

Six detents are used, clockwise: **OP, X, B, A, P/Y, M**. Electrically the switch
is a 4-bit code on columns 6..9 of switch row 1 (col6 = LSB).

| Code (cols 9..6) | Detent | What the 16 lamps then show |
|---|---|---|
| 0 | OP | the machine flip-flops of table 4.1 (T1..P) |
| 1 | X | the index register |
| 2 | B | register B (secondary arithmetic/logic) |
| 3 | A | register A (primary arithmetic/logic) |
| 4 | P/Y | register Y, the memory address register, or P, the program counter |
| 5 | M | register M, the memory buffer — the contents of the location in Y |

Per the manual: in MA mode P and Y hold the same address; in SI or RUN mode P
holds an address one greater than Y. That is why they share a detent and why the
panel cannot show both at once.

Codes 6..15 are undefined. The physical switch may have 10 or 16 detents, so the
decoder must tolerate an out-of-range code rather than invent a mapping.

### 4.3 Switches

Everything below is a toggle unless stated. All of the operator row is on switch
row 1; the four option toggles and RESET are on switch row 2.

| Control | Ref | Row/col | GPIO | Type | Function (manual) |
|---|---|---|---|---|---|
| POWERON-SW | SW22 | row1 col15 | 27 | toggle, latching | Power. Up = on. |
| PFI-PFH | SW23 | row1 col14 | 26 | toggle | PFI = let the machine take a program interrupt when power fails. PFH = let it halt. |
| SENSE1 | SW24 | row1 col13 | 25 | toggle | Program-readable sense switch 1. Up = set, down = reset. |
| SENSE2 | SW25 | row1 col12 | 24 | toggle | Sense switch 2 |
| SENSE3 | SW26 | row1 col11 | 23 | toggle | Sense switch 3 |
| SENSE4 | SW27 | row1 col10 | 22 | toggle | Sense switch 4 |
| ROTARY | SW32 | row1 col9..6 | 21,20,19,18 | coded rotary | Register select, section 4.2 |
| MASTER-CLEAR | SW28 | row1 col5 | 17 | toggle | MSTR CLEAR: clears A, B, P, Y and M; forces timing to the state after a HLT; initialises standard peripherals and options. Leaves memory and X alone. |
| STORE-FETCH | SW29 | row1 col4 | 16 | toggle | In MA mode: STORE = write to memory, FETCH = read from memory. Ignored outside MA. |
| P/P+1 | SW30 | row1 col3 | 13 | toggle | In MA mode: P = access one specific address, P+1 = access consecutive addresses. Ignored outside MA. |
| MA/SI/RUN | SW21 | row1 col2 = MA, col1 = RUN | 12, 11 | 3-position | MA = memory access, and it disables the protection of locations 1-17 octal. SI = single instruction. RUN = normal. Centre position closes neither throw and is SI. |
| START | SW31 | row1 col0 | 10 | push button | Starts the machine in all modes. Its indicator is lit in RUN mode. |
| RESET | SW33 | row2 col11 | 23 | toggle, used as momentary | CLEAR: clears the register currently displayed (A, B, P/Y or M only). |
| ONOFF-HALTINH | SW1 | row2 col3 | 13 | toggle | HALT INH option, section 3.2 |
| WDT | SW2 | row2 col2 | 12 | toggle | Watchdog timer option |
| AUTORESTRT | SW3 | row2 col1 | 11 | toggle | Auto restart option |
| MEM.PRTCT | SW4 | row2 col0 | 10 | toggle | Memory lockout option |

The rotary and MA/SI/RUN are the only multi-position controls; both are decoded,
not read as single bits.

### 4.4 The two clears — do not confuse them

The original machine has two separate clears with very different scope, and the
replica keeps both:

| | RESET | MASTER-CLEAR |
|---|---|---|
| Original name | CLEAR | MSTR CLEAR |
| Scope | the register currently selected for display | the machine |
| Clears | A, B, P/Y or M — whichever the rotary points at | A, B, P, Y and M |
| Also does | nothing | forces timing to the post-HLT state; initialises standard peripherals and options |
| Leaves alone | everything else | memory, and register X |
| Type | momentary | level |
| Placement | right of the lamp row, next to what it acts on | in the operator row with the other machine controls |

Register X is never cleared by either: it can only be written through memory
location 000008 octal.

For the simulator this means two different actions, not one: MASTER-CLEAR is the
equivalent of a machine reset, while RESET is a small, register-selected clear.

## 5. Operating the panel

The procedures below are the manual's, adapted where the replica's hardware
differs. The one real difference is data entry — see 5.3.

### 5.1 Power on

Set POWERON-SW up. On the original, applying power also performs a master clear,
so the replica does the same: power on implies a machine reset. The POWER_LED
shows the state of the switch.

### 5.2 Display a register

Turn the rotary to X, A, B, OP, P/Y or M. The 16 lamps show that register. No
other action is needed; the display follows the machine state continuously.

### 5.3 Load a register

On the original, the 16 lamps *are* illuminated pushbuttons: you press CLEAR,
then press the buttons for the bits you want as 1s, and each press sets that bit.

The replica replaces the illuminated pushbuttons with 16 toggle switches, so the
replica treats **flipping a switch up as the press**: it sets that bit in the
currently displayed register, and the lamp lights. The switch must be flipped
back down before it can set another bit — it is a pushbutton that stays pressed
until released.

Procedure:

1. Set the rotary to A, B, P/Y or M. (X and OP cannot be entered this way.)
2. Press RESET to clear the register. All 16 lamps go dark.
3. Flip up the toggles for the 1 bits, one at a time, returning each to down.
   Each flip lights its lamp as it sets the bit.
4. The register holds the word, and the lamps show it.

### 5.4 Display memory

1. MA/SI/RUN to MA.
2. STORE-FETCH to FETCH.
3. P/P+1 to P.
4. Rotary to P/Y, press RESET, enter the address with the toggles (5.3).
5. Rotary to M, press START. The lamps show the contents of that location.

With P/P+1 set to P+1, each press of START displays the next location.

### 5.5 Load memory

1. MA/SI/RUN to MA.
2. STORE-FETCH to STORE.
3. P/P+1 to P.
4. Rotary to P/Y, press RESET, enter the address.
5. Rotary to M, press RESET.
6. Enter the data word with the toggles.
7. Press START. The word is written to the addressed location.

Set P/P+1 to P+1 to keep loading consecutive locations.

Note the safety property: the hardware protects locations 1-17 octal from a
running program, and MA mode is what lifts that protection. That is deliberate —
it is how the key-in loader survives.

### 5.6 Single instruction

1. MA/SI/RUN to SI.
2. Press MASTER-CLEAR.
3. Load any parameters into A, B or P/Y.
4. Press START. The first instruction is fetched into M and the machine halts.
5. Each further press of START executes the fetched instruction, fetches the next
   one, and halts.

### 5.7 Run

1. MA/SI/RUN to RUN.
2. Press MASTER-CLEAR.
3. Load any parameters.
4. Press START. The machine runs until a HALT, or until the switch is moved to SI.

### 5.8 Master clear

Press MASTER-CLEAR. Machine state is reset as described in 4.4. Memory and X are
untouched.

## 6. Design decisions recorded here

These are decisions, not manual quotes, and they are recorded so the code and the
panel do not drift apart.

1. **The 16 toggles are edge inputs, not a switch register.** A rising edge sets
   the corresponding bit of the register the rotary has selected. A falling edge
   does nothing at all; it only re-arms the switch.
   Reason: a level wiring is electrically impossible on the real machine. During
   RUN the CPU writes A, B, P and M every instruction; a switch held up would
   force its bit and fight the CPU. The original pushbuttons were momentary
   "set bit n" pulses into the selected register, and a toggle plus re-arm is
   simply that pushbutton made mechanical.
2. **No debounce.** Setting a bit is idempotent, so contact bounce on the way up
   sets the same bit twice and does no harm. Bounce on the way down is inert by
   decision 1.
3. **A down-flip never clears a bit.** The manual documents press = set only,
   with CLEAR for zeroing. A down-flip that cleared would teach the wrong
   workflow; to undo a bit, do what a 1967 operator did — RESET and start again.
4. **Switch levels are diagnostic only.** The raw 16 switch bits are readable for
   the debug console, but they are never an input port to the machine: the 516
   has no instruction that reads console switches, because the buttons were wired
   to register flip-flops.
5. **RESET is a toggle in hardware but momentary in effect.** Software acts on
   the rising edge only; sliding it back sends nothing. The user is the one who
   re-arms it.
6. **POWERON-SW is a latching soft switch.** Up = on, down = off. Power on
   implies master clear. There is no power-switching hardware.
7. **MA/SI/RUN decoding**: MA = col2 closed, RUN = col1 closed, SI = neither.
   Both closed is impossible on this switch; treat it as a fault.
8. **Rotary decoding**: the six used detents are assumed to be codes 0..5 in the
   order OP, X, B, A, P/Y, M. Codes 6..15 are invalid and must be tolerated.
   Code 0 is electrically identical to "row 1 not reaching the switch", so a
   broken row-1 line will look like the OP position — worth remembering while
   debugging.

## 7. Open questions

1. **Rotary codes.** Confirm by measurement at each detent; the table above is an
   assumption.
2. **IMP1..IMP24 sources.** Which simulator state feeds each indicator, and what
   the two octal fields on IMP1..IMP8 are. The original's 16 OTB lamps are the
   output transfer bus; for a simulator the natural source is the last 16-bit
   word written to the modem/host interface.
3. **PFI/PFH in the simulator.** Decide whether it is a configuration flag or an
   input the machine tests. It only matters at power loss.
4. **Legend reconciliation.** The schematic's working names differ from the
   manual's designations; the silkscreen should use the manual's or an
   intentional variant. Differences to settle:

   | Schematic value | Manual designation |
   |---|---|
   | ONOFF-HALTINH | HALT INH |
   | WDT | W.D.T. |
   | AUTORESTRT | AUTO RESTART |
   | MEM.PRTCT | MEMORY PRTCT |
   | P-P1 | P/P+1 |
   | MA-S1-RUN | MA/SI/RUN (SI = single instruction) |
   | MASTER-CLEAR | MSTR CLEAR |
   | RESET | CLEAR |

5. **Was the IMP panel really toggles?** The 1967 console uses illuminated
   pushbuttons. If the ruggedized IMP panel had them too, then the toggle bank is
   the replica's own invention and the edge model is a reasonable stand-in rather
   than a reproduction. The ruggedized DDP-516 manual (Honeywell 70130072185,
   cited in the IMP manual) would settle it.
6. **RESET semantics.** This document takes RESET = CLEAR and MASTER-CLEAR =
   MSTR CLEAR. The alternative, that the IMP panel's RESET is the machine reset
   and our MASTER-CLEAR is an addition, would require a photo or drawing of an
   IMP console showing no separate master clear.
