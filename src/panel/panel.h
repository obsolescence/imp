/*
 * panel.h — the IMP front panel matrix, as seen by software.
 *
 * The panel is 3 LED rows and 3 switch rows sharing 16 columns (see
 * doc/hardware.md). This layer owns the multiplexing thread and exposes nothing
 * but three 16-bit lamp words and three 16-bit switch words:
 *
 *   lamps[r] bit k = 1  →  lamp in row r, column k is lit
 *   sw[r]    bit k = 1  →  switch in row r, column k is closed
 *
 * Column numbering is the schematic's: column 0 is the rightmost column on the
 * panel, column 15 the leftmost. Mapping columns to legends is the caller's
 * job, deliberately: this layer knows about the matrix, not about the machine.
 *
 * Two invariants govern the hardware and are enforced inside panel.c:
 *
 *   1. At most ONE LED row is ever driven high. Two rows high at once would
 *      light lamps of both rows through any column that is low, which is not
 *      multiplexing any more.
 *   2. While the switches are read: all three LED rows LOW, exactly ONE switch
 *      row LOW, and the other two rows driven HIGH (or pulled up). A floated
 *      row is not acceptable — a closed switch on it would pull its column down
 *      and masquerade as a switch in the row being scanned.
 *
 * The words are plain 16-bit fields written by one thread and read by another.
 * Aligned 16-bit stores are atomic on ARM, so no locking is needed and the
 * reader can never see a torn word. It can see a value that is one frame old,
 * which at ~1 kHz does not matter.
 */
#ifndef IMP_PANEL_H
#define IMP_PANEL_H

#include <stdint.h>
#include <pthread.h>

/* panel_start() flags */
#define PANEL_HW        1u   /* drive real GPIO (otherwise simulate) */
#define PANEL_LEDS_OFF  2u   /* read switches, light nothing */

typedef struct {
    volatile uint16_t lamps[3];
    volatile uint16_t sw[3];
    volatile uint16_t fake_sw[3];  /* injected switch words when hw == 0 */
    volatile uint32_t frames;
    volatile int stop;

    int hw;                        /* 1 = driving real GPIO */
    int leds_off;                  /* 1 = switch scan only, LED rows stay low */
    int rt_ok;                     /* 1 = thread runs SCHED_FIFO */
    pthread_t tid;
    int started;
} panel_t;

/* use_hw = 0 runs the same thread against fake switches: useful on a machine
 * without a panel, and for the test program's --no-gpio mode. */
int  panel_start(panel_t *p, unsigned flags);
void panel_stop(panel_t *p);

/* Bring-up diagnostic: with no multiplexing at all, hold column low on one row
 * so that row's 16 lamps are on steadily — the state to measure with a meter.
 * Only one row may be lit, by invariant 1. panel_static_off() releases the
 * pins. Returns 0 on success. */
int  panel_static_on(int row);
void panel_static_off(void);

#endif
