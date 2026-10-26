# Replica IMP front panel — circuit and layout

Everything below was read from the panel KiCad project (`imp-panel.net` and
`imp-panel.kicad_sch`). Items that still need a meter on the bench are collected
in section 8.

Conventions:

- Coordinates are millimetres from the KiCad schematic. The schematic was drawn
  over the PCB layout, so the positions correspond to the board.
- `colN` is the net name from the schematic. Columns are numbered **right to
  left** on the board: col0 is the rightmost column, col15 the leftmost.
- A lamp is lit when its column is driven **LOW**. A switch reads as closed when
  its column reads **LOW** with its row driven LOW.

## 1. What is different from the PiDP-10 panel

The multiplexing idea is the PiDP-10 one, but the panel is not the same circuit
with different pin numbers. With only three LED rows and three switch rows there
is nothing to decode, so the two 3-to-8 decoders and the phase-select line are
gone and the rows are driven directly.

| | PiDP-10 | IMP replica |
|---|---|---|
| LED rows | 7, selected by a 74HC238 from a 3-bit address | 3, one GPIO each, through a UDN2981A |
| Switch rows | 5, selected by a 74HC138 from the same 3-bit address | 3, one GPIO each |
| Phase select | GPIO22 (`xIO`) chooses which decoder owns the columns | none — the phase is implicit in the drive order |
| Columns | 18, shared | 16, shared |
| Row addressing | binary address into decoders | one-hot, drive the row pin |
| Lamps | 126 | 41 |
| Switches | 90 | 33 |

Consequence for the driver: there is no address to encode and no `xIO` line to
toggle. What replaces `xIO` is a rule: the three switch-row pins must be inputs
during the LED phase, and the three LED-row inputs must be low during the switch
phase.

## 2. GPIO assignment

22 GPIOs carry the panel. All are standard 40-pin header pins.

### LED rows — active HIGH

| Row | GPIO | Header pin | Path |
|---|---|---|---|
| led0 | 7  | 26 | P1 IN1 → OUT1 → `led0` (16 lamps) |
| led1 | 8  | 24 | P1 IN2 → OUT2 → `led1` (12 lamps) |
| led2 | 9  | 21 | P1 IN3 → OUT3 → `led2` (13 lamps) |

### Switch rows — active LOW, 820 Ω series

| Row | GPIO | Header pin | Net |
|---|---|---|---|
| row0 | 4 | 7  | 16 switches (SR0..SR15) |
| row1 | 5 | 29 | 12 switches (operator row) |
| row2 | 6 | 31 | 5 switches (4 option toggles + RESET) |

### Columns — 390 Ω series each

| Col | GPIO | Pin | Col | GPIO | Pin | Col | GPIO | Pin | Col | GPIO | Pin |
|---|---|---|---|---|---|---|---|---|---|---|---|
| col0  | 10 | 19 | col4  | 16 | 36 | col8  | 20 | 38 | col12 | 24 | 18 |
| col1  | 11 | 23 | col5  | 17 | 11 | col9  | 21 | 40 | col13 | 25 | 22 |
| col2  | 12 | 32 | col6  | 18 | 12 | col10 | 22 | 15 | col14 | 26 | 37 |
| col3  | 13 | 33 | col7  | 19 | 35 | col11 | 23 | 16 | col15 | 27 | 13 |

### Not part of the panel in this project

| Function | GPIO | Header pin | Connector |
|---|---|---|---|
| I2C SDA | 2 | 3 | J1 (4-pin `I2C/3.3V`) |
| I2C SCL | 3 | 5 | J1 |
| UART TX | 14 | 8  | P3 pin 1 (direct) |
| UART RX | 15 | 10 | P3 pin 2 (through divider R_S2/R_S3 and R_S1) |

## 3. Circuit description

### 3.1 LED rows — UDN2981A source driver

The three LED rows are driven by a UDN2981A, an 8-channel high-side Darlington
source driver (DIP-18), of which three channels are used:

- IN1..IN3 = pins 1..3 = GPIO7/8/9. The inputs are the enable: there is no
  separate output-enable pin.
- IN4..IN8 = pins 4..8, tied to ground (unused inputs must not float).
- Pin 9 (common supply) is fed from the Pi's +5 V through **D37**, a 1N4148.
- Pin 10 is ground.
- OUT1..OUT3 = pins 18..16 → `led0`, `led1`, `led2`. OUT4..OUT8 are open.

Each row net is the common **anode** of every lamp in that row. A lamp's cathode
sits on its column net, so the panel drives LEDs high-side and sinks them on the
column GPIO.

### 3.2 Columns

Each column GPIO has a 390 Ω resistor in series with the column net. The same
390 Ω sets lamp current during the LED phase and is the series element in the
switch read path, so it protects the GPIO in both phases.

### 3.3 Switch rows

Each switch-row GPIO drives a row net through 820 Ω. A row net is the common side
of every switch in that row. Scanning drives one row LOW at a time.

### 3.4 The diode matrix, and why it is there

Every switch contact has its own 1N4148: **anode on the column net, cathode at
the switch contact**, switch common on the row net.

This is what makes the shared columns legal:

- **LED phase.** Columns are outputs. A closed switch would otherwise connect a
  driven row to a column output and fight it. The diode is reverse-biased in
  that direction (row → column) and blocks it.
- **Switch phase.** Columns are inputs with pull-ups. Current flows from the
  column pull-up through the diode and the closed switch into the driven-low
  row, dragging the column down. The diode is forward-biased here, so the read
  works.

Diode count: 37 matrix diodes (D1–D36, D38) plus D37 in the LED supply.

### 3.5 Voltage budget and currents

```
Pi +5V            ~5.0 V (some supplies 5.35 V — see the note below)
- D37 drop        ~0.6 V
- UDN2981A Vce    ~1.0-1.5 V at these currents (Darlington, not a FET)
- LED Vf          ~2.0 V (3 mm LED, varies)
- column VOL      ~0.1 V
-----------------------------------------
across 390 Ω      ~1.0-1.5 V  →  roughly 3-4 mA per lit lamp
```

16 lamps in one row put roughly 50 mA through one channel; the UDN2981A is rated
500 mA per channel, so there is no thermal worry.

The schematic carries a design note about D37: the diode drops the LED supply by
0.6 V because Raspberry Pi power supplies often deliver 5.35 V rather than
5.00 V, which overdrives the lamps and causes a "Pi Glow" effect in this circuit.

Switch read current is tiny: the column pull-up is on the order of 50 kΩ, so the
current through 390 Ω + diode + 820 Ω is about 50 µA. The column node therefore
sits near 0.5 V — well under the Pi's 0.8 V V_IL. That margin is why plain
1N4148 diodes are adequate and why a diode with a much higher forward drop would
not be.

One consequence worth knowing before debugging: with a lamp's row energised the
anode sits around 3.0-3.4 V, and a column that is "off" is driven to 3.3 V. The
margin is small by design. If lamps glow faintly when they should be dark, the
first thing to check is that column HIGH is genuinely above the anode voltage.

### 3.6 Power

The panel is powered from the Pi's own 5 V and 3.3 V pins. There is no separate
supply and no power switching hardware: the POWER switch is a soft switch (see
`operation.md`).

## 4. Matrix maps

### 4.1 Lamp rows — 41 lamps

| Row | GPIO | Contents | Columns used | Spare |
|---|---|---|---|---|
| led0 | 7 | A0..A15, the 16-bit register display | col0..col15 | — |
| led1 | 8 | IMP1..IMP12, network indicators | col0..col11 | col12..col15 |
| led2 | 9 | IMP13..IMP24 (col0..col11) and POWER_LED (col15) | col0..col11, col15 | col12..col14 |

The lamps inside a row run with the column number: lamp bit *k* is on column *k*,
so column 15 is the leftmost lamp of the row and column 0 the rightmost.

Note the two halves of the panel disagree on direction: on the IMP bank the
columns increase to the right (IMP1 is leftmost), while on the A bank and the SR
bank they increase to the left. This is only a naming/layout fact — the driver
always works in column order.

### 4.2 Switch rows — 33 switches

| Row | GPIO | Column | Switch | Ref | Notes |
|---|---|---|---|---|---|
| row0 | 4 | col15 | SR0 | SW5 | 16-bit switch bank, SR0 leftmost |
| row0 | 4 | col14 | SR1 | SW6 | |
| row0 | 4 | col13 | SR2 | SW7 | |
| row0 | 4 | col12 | SR3 | SW8 | |
| row0 | 4 | col11 | SR4 | SW9 | |
| row0 | 4 | col10 | SR5 | SW10 | |
| row0 | 4 | col9  | SR6 | SW11 | |
| row0 | 4 | col8  | SR7 | SW12 | |
| row0 | 4 | col7  | SR8 | SW13 | |
| row0 | 4 | col6  | SR9 | SW14 | |
| row0 | 4 | col5  | SR10 | SW15 | |
| row0 | 4 | col4  | SR11 | SW16 | |
| row0 | 4 | col3  | SR12 | SW17 | |
| row0 | 4 | col2  | SR13 | SW18 | |
| row0 | 4 | col1  | SR14 | SW19 | |
| row0 | 4 | col0  | SR15 | SW20 | rightmost |
| row1 | 5 | col15 | POWERON-SW | SW22 | |
| row1 | 5 | col14 | PFI-PFH | SW23 | |
| row1 | 5 | col13 | SENSE1 | SW24 | |
| row1 | 5 | col12 | SENSE2 | SW25 | |
| row1 | 5 | col11 | SENSE3 | SW26 | |
| row1 | 5 | col10 | SENSE4 | SW27 | |
| row1 | 5 | col9  | ROTARY bit3 (MSB) | SW32 | 4-bit coded rotary, 6 detents used |
| row1 | 5 | col8  | ROTARY bit2 | SW32 | |
| row1 | 5 | col7  | ROTARY bit1 | SW32 | |
| row1 | 5 | col6  | ROTARY bit0 (LSB) | SW32 | |
| row1 | 5 | col5  | MASTER-CLEAR | SW28 | |
| row1 | 5 | col4  | STORE-FETCH | SW29 | |
| row1 | 5 | col3  | P/P+1 | SW30 | |
| row1 | 5 | col2  | MA/SI/RUN: MA | SW21 | SPDT throw |
| row1 | 5 | col1  | MA/SI/RUN: RUN | SW21 | SPDT throw; neither thrown = SI |
| row1 | 5 | col0  | START | SW31 | push button, momentary |
| row2 | 6 | col3  | ONOFF-HALTINH | SW1 | |
| row2 | 6 | col2  | WDT | SW2 | |
| row2 | 6 | col1  | AUTORESTRT | SW3 | |
| row2 | 6 | col0  | MEM.PRTCT | SW4 | |
| row2 | 6 | col11 | RESET | SW33 | toggle, used as a momentary |

Row 1 is fully populated: all sixteen columns carry something. Rows 0 and 2 leave
most of their columns unused.

### 4.3 Board layout

Positions from the schematic, in millimetres, with the panel's own grouping:

| Group | Y | X range | Pitch | Contents |
|---|---|---|---|---|
| IMP lamp row 1 | 101.60 | 171.45 → 255.27 | 7.62 | IMP1..IMP12, left to right |
| IMP lamp row 2 | 118.11 | 171.45 → 255.27 | 7.62 | IMP13..IMP24, left to right |
| IMP option toggles | 106.68 | 102.87 → 137.16 | 11.43 | ONOFF-HALTINH, WDT, AUTORESTRT, MEM.PRTCT left to right (col3 → col0) |
| A lamp row | 180.34 | 107.95 → 222.25 | 7.62 | A15..A0, left to right (col15 → col0) |
| RESET | 177.80 | 245.11 | — | right of the A lamp row |
| SR switch bank | 213.36 | 85.09 → 260.35 | 11.43 | SR0..SR15 left to right, in four groups of four (12.7 mm gaps between groups) |
| Operator row | 257.81 | 35.56 → 255.27 | ~11.43 | POWERON-SW, PFI-PFH, SENSE1..4, ROTARY, MASTER-CLEAR, STORE-FETCH, P/P+1, MA/SI/RUN, START |
| POWER_LED | 259.08 | 55.88 | — | beside the power switch |

The four option toggles sit vertically between the two IMP lamp rows, to their
left. The rotary is noticeably wider than the toggles: it occupies 40 mm of the
operator row on its own.

### 4.4 Columns shared between halves

Two columns are used by both the IMP and the H316 halves, which looks like a
wiring error at first glance and is not:

- column 15 (GPIO27): POWERON-SW on row1, POWER_LED on row2.
- column 11 (GPIO23): SENSE3 on row1, RESET on row2.

## 5. Scanning sequence

The multiplex runs in its own real-time thread, in the same process as the
simulator, with no locks: the lamp and switch words are single aligned
half-word stores, so the panel can never see a torn value. The panel is allowed
to display state that is a fraction of a millisecond stale.

#### The two rules that govern the matrix

Neither is an optimisation; both prevent readings that look like hardware faults.

1. **At most one LED row is HIGH at any instant.** Two rows high at once means a
   column that is LOW lights a lamp in each of them, and the display is no
   longer addressed. Every row is therefore driven LOW before the next one is
   enabled, never simply handed over.
2. **While the switches are read: all LED rows LOW, exactly ONE switch row LOW,
   and every other switch row driven HIGH.** The LED rows must be low or a driven
   column would fight the row through a closed switch's diode. The unscanned
   switch rows must be HIGH rather than left as inputs, because an input pin's
   pull is whatever the pad happens to have — on the Pi 4 the power-on default
   is pull-down, and a row sitting at ground pulls its column down through a
   closed switch exactly like a switch in the row being scanned would. That is a
   phantom reading, and it is indistinguishable from a real one. Driving the
   row high reverse-biases that switch's diode, so the column stays where the
   pull-up put it.

### 5.1 LED phase — for each row r = 0, 1, 2

1. all three LED rows LOW; switch rows tri-stated for this phase (see below)
2. columns = OUTPUT
3. drive the 16 column levels from the lamp word for row r
4. row r HIGH — and it is the only row that is high
5. dwell
6. row r LOW again, before anything else changes

Steps 3-5 are the ghost-free order: data is loaded while dark, the row is
enabled only once the columns have settled, and it is switched off before the
data changes for the next row.

The switch rows are tri-stated for the whole LED phase rather than driven high:
a closed switch on a row driven high would sink current out of a column GPIO
that is driving high for a lamp that is off — about 2.4 mA per switch through
390 Ω + diode + 820 Ω, and sixteen of them on one row would sum to roughly
38 mA into a single pin.

### 5.2 Switch phase

1. all three LED rows LOW (lamps dark, so nothing competes for the columns)
2. columns = INPUT with pull-ups
3. all three switch rows = OUTPUT HIGH, so that no unscanned row can sink
4. for each row r: switch row r LOW, settle, read the 16 columns, switch row r
   HIGH again; the other two rows stay HIGH throughout
5. restart the LED phase, which tri-states the switch rows again

### 5.3 Blanking interval

A guard time after each row is switched off, before the columns change, is kept
in the code. It is probably not needed: the UDN2981A is a Darlington array with a
finite storage time, and the intent is to let the output stage finish turning off
before the next row's data appears on the shared columns. It costs almost
nothing at these speeds.

### 5.4 Timing budget

| | PiDP-10 | IMP replica |
|---|---|---|
| Rows to scan | 7 LED + 5 switch | 3 LED + 3 switch |
| Dwell per row | 50 µs | choose; 100-200 µs is comfortable |
| Frame at 100 µs dwell | ~450 µs | ~330 µs |
| Frame at 200 µs dwell | — | ~630 µs |
| Duty per row | ~12 % | ~30 % |

Fewer rows and a much lighter matrix mean this panel can afford a longer dwell
than the PiDP-10 for the same frame rate, which is why the lamps should come out
noticeably brighter at the same or lower thread load.

### 5.5 Thread and privileges

Same approach as PiDP-10: a pthread on SCHED_FIFO for the multiplexing loop.

Hardware access goes through the `pinctrl` library of Raspberry Pi's `utils`
package, vendored in `src/pinctrl/` (BSD-3, taken from the PiDP-10 tree). It
finds the GPIO controller from the device tree and hides the per-SoC
differences, which matter here for one specific reason: the panel's 16 column
lines have no pull-up resistors of their own, so the read path depends on the
SoC's internal pull-ups — and the register that selects them is not the same on
BCM2835/2711/2712. A hand-written mmap backend for one Pi is silently wrong on
the others; this one covers Pi 2 through Pi 5.

Access is through `/dev/gpiomemN`, which on Raspberry Pi OS is `root:gpio 0660`,
so membership of group `gpio` is all that is needed. Only the `/dev/mem`
fallback path needs root. Raising the thread to SCHED_FIFO is a separate
privilege: `cap_sys_nice` on the binary, which is what `install.sh` and
`make privileges` set. The setuid bit PiDP-10 also sets is harmless and kept for
consistency, but on current Raspberry Pi OS the group membership is what
actually gets the panel talking.

## 6. Pins reserved by other functions — read this before enabling anything

- **SPI is impossible on this pinout.** SPI0 uses GPIO7/8/9/10/11, which are our
  three LED rows and col0/col1; SPI1 (aux) uses GPIO16-21, which are col4..col9.
  Both hardware SPI peripherals collide with the matrix. Any future SPI device
  needs a pinout revision or bit-banging on spare pins.
- **UART** (GPIO14/15) goes to P3 only. If the Pi's serial console is enabled —
  the default on Raspberry Pi OS, `console=serial0,115200` in `cmdline.txt` — the
  console owns those pins. It must be disabled before the serial link is used.
- **I2C** (GPIO2/3) goes to J1 only and does not touch the matrix. Note the Pi has
  no on-board pull-ups on those pins suitable for a bus; J1 is labelled
  `I2C/3.3V`, so the pull-ups presumably live on the attached board.
- **P3 serial divider**: `R_S2` and `R_S3` (820 Ω each, in parallel = 410 Ω) in
  series from P3 pin 2, with `R_S1` (820 Ω) to ground on the GPIO side, gives a
  5 V → 3.3 V divider. The schematic note says: leave out `R_S2` and fit a jumper
  in place of `R_S1` when using a 3.3 V adapter.

## 7. Bill of materials (panel board)

| Part | Count | Note |
|---|---|---|
| LED, 3 mm | 41 | 16 + 12 + 13 across the three rows |
| Switch | 33 | 31 × SPDT symbol used as SPST, 1 × SPDT (MA/SI/RUN), 1 × 4-bit coded rotary |
| 1N4148 | 38 | 37 matrix diodes + D37 in the LED supply |
| Resistor 390 Ω | 16 | one per column |
| Resistor 820 Ω | 6 | three switch rows, three in the serial divider |
| UDN2981A | 1 | DIP-18, 3 of 8 channels used |
| 40-pin header | 1 | Raspberry Pi |
| 4-pin header | 2 | J1 I2C, P3 TTL serial |
| Mounting hole | 20 | M1..M20 |

## 8. To confirm on the bench

1. Rotary detent codes. The four contacts are coded, not one-per-position; the
   code table in `operation.md` assumes the first six values. Turn the switch
   through all detents and record which of col6..col9 read low at each.
2. The 4-position and 3-position switches may be the "cheap" variety that can
   briefly close two contacts while passing through. If so, the decoder needs
   cleanup logic (ignore transient double closures) rather than trusting a
   single scan.
3. Lamp current and brightness: measure the voltage across one 390 Ω resistor
   with a lamp lit, and confirm the off-state margin of section 3.5.
4. Blanking interval: confirm the UDN2981A turn-off behaviour by shortening the
   guard time until ghosting appears, then keep a comfortable margin.
5. Switch-row tri-state: verify in firmware that a full row of closed switches
   with the rows tri-stated during the LED phase really draws nothing.
