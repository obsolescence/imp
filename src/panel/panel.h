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
 * The words are plain 16-bit fields written by one thread and read by another.
 * Aligned 16-bit stores are atomic on ARM, so no locking is needed and the
 * reader can never see a torn word. It can see a value that is one frame old,
 * which at ~1.7 kHz does not matter.
 */
#ifndef IMP_PANEL_H
#define IMP_PANEL_H

#include <stdint.h>
#include <pthread.h>

typedef struct {
    volatile uint16_t lamps[3];
    volatile uint16_t sw[3];
    volatile uint16_t fake_sw[3];  /* injected switch words when hw == 0 */
    volatile uint32_t frames;
    volatile int stop;

    int hw;                        /* 1 = driving real GPIO */
    int rt_ok;                     /* 1 = thread runs SCHED_FIFO */
    pthread_t tid;
    int started;
} panel_t;

/* use_hw = 0 runs the same thread against fake switches: useful on a machine
 * without a panel, and for the test program's --no-gpio mode. */
int  panel_start(panel_t *p, int use_hw);
void panel_stop(panel_t *p);

#endif
