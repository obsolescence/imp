/*
 * panel.c — the multiplexing thread.
 *
 * Hardware access goes through the vendored pinctrl library in src/pinctrl
 * (Raspberry Pi's pinctrl utility, gpiolib layer). That library finds the GPIO
 * controller from the device tree and knows the differences between the
 * BCM2835/2711/2712 and RP1 register layouts, so this file never touches a
 * register and the same binary works on a Pi 2 through a Pi 5.
 *
 * Layout, from doc/hardware.md:
 *
 *   LED rows    GPIO 7, 8, 9   through a UDN2981A, active HIGH
 *   switch rows GPIO 4, 5, 6   active LOW, 820 R series
 *   columns     GPIO 10,11,12,13,16,17,18,19,20,21,22,23,24,25,26,27, 390 R
 *
 * A lamp is lit when its column is driven LOW with its row HIGH. A switch reads
 * closed when its column is LOW with its row driven LOW.
 *
 * Two rules make the shared columns safe, and both are enforced below:
 *   1. the switch rows are inputs for the whole LED phase, so a closed switch
 *      can never sink current out of a column that is driving a lamp;
 *   2. the LED rows are all low for the whole switch phase, so nothing is
 *      fighting the pull-ups the columns rely on.
 */
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "gpiolib.h"
#include "panel.h"

static const unsigned led_row[3] = { 7, 8, 9 };
static const unsigned sw_row[3]  = { 4, 5, 6 };
static const unsigned col_pin[16] = {
    10, 11, 12, 13, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27
};

/* Timing. 150 us of dwell per row gives ~26 % duty at a 570 us frame; the
 * blanking gap after each row is the guard time the UDN2981A wants before the
 * columns change for the next row (see doc/hardware.md section 5.3). */
#define DWELL_NS   150000
#define BLANK_NS    20000
#define SETTLE_NS   20000

static void nsleep(long ns)
{
    struct timespec t;

    t.tv_sec = 0;
    t.tv_nsec = ns;
    clock_nanosleep(CLOCK_MONOTONIC, 0, &t, NULL);
}

/* Column word to pin levels: bits set in w are lamps that must be lit, and a
 * lit lamp needs its column LOW. gpio_set()/gpio_clear() set the drive level
 * and the direction together, so one call per column is enough. */
static void cols_write(uint16_t w)
{
    unsigned k;

    for (k = 0; k < 16; k++) {
        if (w & (1u << k))
            gpio_clear(col_pin[k]);
        else
            gpio_set(col_pin[k]);
    }
}

static void panel_init_pins(void)
{
    unsigned r, k;

    /* LED row drivers: outputs, all off. */
    for (r = 0; r < 3; r++) {
        gpio_set_dir(led_row[r], DIR_OUTPUT);
        gpio_clear(led_row[r]);
    }
    /* Switch rows: inputs (tri-stated) until we scan them. */
    for (r = 0; r < 3; r++)
        gpio_set_dir(sw_row[r], DIR_INPUT);
    /* Columns: inputs with a pull-up. The board has no pull-ups of its own —
     * the read path relies on the SoC's internal ones, and how to ask for them
     * differs per SoC, which is exactly why this goes through the library. */
    for (k = 0; k < 16; k++) {
        gpio_set_dir(col_pin[k], DIR_INPUT);
        gpio_set_pull(col_pin[k], PULL_UP);
    }
}

static void *mux_thread(void *arg)
{
    panel_t *p = (panel_t *)arg;

    while (!p->stop) {
        uint16_t l[3];
        int r;
        unsigned k;

        l[0] = p->lamps[0];
        l[1] = p->lamps[1];
        l[2] = p->lamps[2];

        if (p->hw) {
            /* --- LED phase -------------------------------------------------- */
            for (r = 0; r < 3; r++)
                gpio_set_dir(sw_row[r], DIR_INPUT);
            for (k = 0; k < 16; k++)
                gpio_set_dir(col_pin[k], DIR_OUTPUT);

            for (r = 0; r < 3; r++) {
                cols_write(l[r]);        /* data first ... */
                gpio_set(led_row[r]);    /* ... then enable the row */
                nsleep(DWELL_NS);
                gpio_clear(led_row[r]);  /* blank before the columns change */
                nsleep(BLANK_NS);
            }

            /* --- switch phase ----------------------------------------------- */
            for (k = 0; k < 16; k++)
                gpio_set_dir(col_pin[k], DIR_INPUT);

            for (r = 0; r < 3; r++) {
                uint16_t w = 0;

                gpio_set_dir(sw_row[r], DIR_OUTPUT);
                gpio_clear(sw_row[r]);
                nsleep(SETTLE_NS);
                for (k = 0; k < 16; k++)
                    if (gpio_get_level(col_pin[k]) == 0)
                        w |= (uint16_t)(1u << k);
                p->sw[r] = w;
                gpio_set_dir(sw_row[r], DIR_INPUT);   /* release the row */
            }
        } else {
            p->sw[0] = p->fake_sw[0];
            p->sw[1] = p->fake_sw[1];
            p->sw[2] = p->fake_sw[2];
            nsleep(DWELL_NS);
        }
        p->frames++;
    }
    return NULL;
}

/* --- static bring-up mode -------------------------------------------------
 *
 * No multiplexing: all three rows driven HIGH and all 16 columns driven LOW, so
 * every lamp is on continuously. This is the state to put a meter on, and the
 * quickest way to ask "can this panel light at all?". About 150 mA from 5 V,
 * well inside the UDN2981A ratings (three channels, ~50 mA each).
 */
int panel_static_on(void)
{
    unsigned r, k;

    if (gpiolib_init() <= 0)
        return -1;
    if (gpiolib_mmap() != 0)
        return -1;

    for (r = 0; r < 3; r++)
        gpio_set_dir(sw_row[r], DIR_INPUT);
    for (k = 0; k < 16; k++) {
        gpio_set_dir(col_pin[k], DIR_OUTPUT);
        gpio_clear(col_pin[k]);
    }
    for (r = 0; r < 3; r++) {
        gpio_set_dir(led_row[r], DIR_OUTPUT);
        gpio_set(led_row[r]);
    }
    return 0;
}

void panel_static_off(void)
{
    unsigned r, k;

    for (r = 0; r < 3; r++)
        gpio_clear(led_row[r]);
    for (k = 0; k < 16; k++)
        gpio_set_dir(col_pin[k], DIR_INPUT);
}

int panel_start(panel_t *p, int use_hw)
{
    pthread_attr_t attr;
    struct sched_param sp;
    int rc;

    memset(p, 0, sizeof(*p));
    p->hw = use_hw;

    if (use_hw) {
        /* gpiolib_init() returns the number of GPIOs it found: 0 or less is a
         * failure, not success. gpiolib_mmap() returns 0 on success. */
        if (gpiolib_init() <= 0)
            return -1;
        if (gpiolib_mmap() != 0)
            return -1;
        panel_init_pins();
    }

    pthread_attr_init(&attr);
    pthread_attr_setschedpolicy(&attr, SCHED_FIFO);
    sp.sched_priority = 98;
    pthread_attr_setschedparam(&attr, &sp);
    pthread_attr_setinheritsched(&attr, PTHREAD_EXPLICIT_SCHED);

    rc = pthread_create(&p->tid, &attr, mux_thread, p);
    if (rc == 0) {
        p->rt_ok = 1;
    } else {
        /* No cap_sys_nice? Carry on at normal priority and say so — the panel
         * will still scan, it just loses its timing guarantee. */
        p->rt_ok = 0;
        rc = pthread_create(&p->tid, NULL, mux_thread, p);
        if (rc != 0) {
            pthread_attr_destroy(&attr);
            return -1;
        }
    }
    pthread_attr_destroy(&attr);
    p->started = 1;
    return 0;
}

void panel_stop(panel_t *p)
{
    unsigned k;

    if (!p->started)
        return;
    p->stop = 1;
    pthread_join(p->tid, NULL);
    p->started = 0;
    if (p->hw) {
        for (k = 0; k < 16; k++)
            gpio_set_dir(col_pin[k], DIR_INPUT);
    }
}
