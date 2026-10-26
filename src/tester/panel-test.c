/*
 * panel-test.c — bring-up test for the replica IMP front panel.
 *
 * What it does
 *   - drives the panel through the multiplexing thread in panel.c,
 *   - reads every switch and shows its position on a TUI of the panel,
 *   - runs a test pattern on the lamps that exercises all 41 of them,
 *   - switches to manual mode the first time you touch any switch, after which
 *     the 16-lamp row mirrors the 16 switches, and RESET blanks it.
 *
 * The pattern, in three parts
 *   A row (led0, 16 lamps)  a synthetic instruction stream: 6-bit command field
 *                           in bits 15-10, 10-bit address in bits 9-0 scanning
 *                           0..1023 and wrapping, which is what a running IMP
 *                           does to its buffers. The command values are NOT the
 *                           H316 opcode table — they are pseudo-opcodes chosen
 *                           so that all six of those lamps get exercised.
 *   IMP1-4, IMP5-8          two 4-bit binary counters, 4 Hz and 2 Hz.
 *   IMP9-24 (16 lamps)      a two-lamp packet crossing left to right, wrapping,
 *                           with a gap and one all-16 flash per pass.
 *   POWER_LED               follows the power switch, always.
 *
 * Manual mode mirrors switch LEVELS rather than the edge-entry model described
 * in doc/operation.md. That is deliberate: this is a hardware test, and a level
 * mirror proves that every switch column reads correctly. The edge model
 * belongs to the simulator glue, where a held-up switch would fight the CPU.
 *
 * Build:  make          Run:  sudo not needed if you are in group gpio
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>
#include <sys/select.h>

#include "panel.h"

/* ---- switch bit positions, from doc/hardware.md ------------------------- */
#define SW1_POWER    15          /* row1 col15  POWERON-SW   */
#define SW1_PFI      14          /* row1 col14  PFI/PFH      */
#define SW1_S1       13
#define SW1_S2       12
#define SW1_S3       11
#define SW1_S4       10
#define SW1_ROT      6           /* row1 cols 9..6, col6 = LSB */
#define SW1_MCLR     5
#define SW1_SF       4
#define SW1_PP1      3
#define SW1_MA       2
#define SW1_RUN      1
#define SW1_START    0

#define SW2_RESET    11          /* row2 col11  RESET */
#define SW2_HALTINH  3
#define SW2_WDT      2
#define SW2_AUTO     1
#define SW2_MEMPRT   0

#define LED2_POWER   15          /* row2 col15  POWER_LED */

static volatile sig_atomic_t quit_flag = 0;
static void on_signal(int sig) { (void)sig; quit_flag = 1; }

static uint32_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(ts.tv_sec * 1000u + ts.tv_nsec / 1000000u);
}

/* ---- the test pattern --------------------------------------------------- */
static uint16_t packet16(uint32_t ms)
{
    /* A two-lamp packet walking left to right across the 16 traffic lamps,
     * a 4-tick gap, then one all-lit flash as the packet "arrives". */
    uint32_t t = ms / 60;
    uint32_t pos = t % 20;
    uint16_t w = 0;

    if (pos < 16) {
        w |= (uint16_t)(1u << pos);
        w |= (uint16_t)(1u << ((pos + 1) & 15));
    } else if (pos == 17) {
        w = 0xFFFF;
    }
    return w;
}

static void pattern(uint32_t ms, int power_on, int walk, uint16_t l[3])
{
    static const unsigned cmd[] = { 001, 002, 004, 010, 020, 040 };
    uint16_t traffic, ctr_a, ctr_b;

    if (walk) {
        /* Lamp walk: one lamp at a time, all 41 of them in a fixed order. */
        static const struct { unsigned char row, col; } seq[] = {
            {1,0},{1,1},{1,2},{1,3},{1,4},{1,5},{1,6},{1,7},{1,8},{1,9},{1,10},{1,11},
            {2,0},{2,1},{2,2},{2,3},{2,4},{2,5},{2,6},{2,7},{2,8},{2,9},{2,10},{2,11},
            {0,15},{0,14},{0,13},{0,12},{0,11},{0,10},{0,9},{0,8},
            {0,7},{0,6},{0,5},{0,4},{0,3},{0,2},{0,1},{0,0},
            {2,15}
        };
        unsigned i = (ms / 120) % (sizeof(seq) / sizeof(seq[0]));
        l[0] = l[1] = l[2] = 0;
        l[seq[i].row] = (uint16_t)(1u << seq[i].col);
        return;
    }

    /* A row: command field + scanning address. */
    l[0] = (uint16_t)((cmd[(ms / 400) % 6] << 10) | ((ms / 50) % 1024));

    /* IMP1-4 and IMP5-8: two binary counters. */
    traffic = packet16(ms);
    ctr_a = (uint16_t)((ms / 250) & 0xF);
    ctr_b = (uint16_t)((ms / 500) & 0xF);

    l[1] = (uint16_t)(ctr_a | (ctr_b << 4) | ((traffic & 0x000F) << 8));
    l[2] = (uint16_t)((traffic >> 4) & 0x0FFF);

    if (power_on)
        l[2] |= (uint16_t)(1u << LED2_POWER);
}

/* ---- TUI ---------------------------------------------------------------- */
static const char *G_ON = "\xe2\x97\x8f";   /* ● */
static const char *G_OFF = "\xe2\x97\x8b";  /* ○ */
static const char *G_UP = "\xe2\x96\xb2";   /* ▲ */
static const char *G_DN = "\xe2\x96\xbc";   /* ▼ */

struct screen {
    char line[24][160];
    int used;
};

static void app(struct screen *s, int row, const char *fmt, ...)
{
    va_list ap;
    size_t n;

    if (row < 0 || row >= 24)
        return;
    n = strlen(s->line[row]);
    va_start(ap, fmt);
    vsnprintf(s->line[row] + n, sizeof(s->line[row]) - n, fmt, ap);
    va_end(ap);
    if (row >= s->used)
        s->used = row + 1;
}

static const char *sw_glyph(uint16_t w, int bit)
{
    return (w >> bit) & 1u ? G_UP : G_DN;
}

static void draw(const panel_t *p, int mode, int walk, int paused,
                 uint32_t fps_x10, const char *note)
{
    static char out[24][160];
    struct screen s;
    uint16_t l0 = p->lamps[0], l1 = p->lamps[1], l2 = p->lamps[2];
    uint16_t s0 = p->sw[0], s1 = p->sw[1], s2 = p->sw[2];
    unsigned rot = (s1 >> SW1_ROT) & 0xF;
    static const char *rot_name[16] = {
        "OP", "X", "B", "A", "P/Y", "M", "", "", "", "", "", "", "", "", "", ""
    };
    const char *mode_name = walk ? "lamp walk" : (mode ? "manual" : "demo");
    int i;

    memset(&s, 0, sizeof(s));
    app(&s, 0, " IMP front panel test   q quit   d demo   m manual   p walk   space pause");
    app(&s, 1, " %s", "--------------------------------------------------------------------------------");
    app(&s, 2, " IMP DISPLAY PANEL");
    for (i = 0; i < 12; i++) {
        app(&s, 3, "%s", i == 0 ? "   IMP1..IMP12   " : "");
        app(&s, 3, "%s ", (l1 >> i) & 1u ? G_ON : G_OFF);
    }
    for (i = 0; i < 12; i++) {
        app(&s, 4, "%s", i == 0 ? "   IMP13..IMP24  " : "");
        app(&s, 4, "%s ", (l2 >> i) & 1u ? G_ON : G_OFF);
    }
    app(&s, 5, "   HALTINH%s  WDT%s  AUTO%s  MEM%s      POWER %s (lamp %s)",
        sw_glyph(s2, SW2_HALTINH), sw_glyph(s2, SW2_WDT), sw_glyph(s2, SW2_AUTO),
        sw_glyph(s2, SW2_MEMPRT), sw_glyph(s1, SW1_POWER),
        (l2 >> LED2_POWER) & 1u ? G_ON : G_OFF);
    app(&s, 6, " %s", "--------------------------------------------------------------------------------");
    app(&s, 7, " H316 CONTROL CONSOLE");
    for (i = 15; i >= 0; i--) {
        app(&s, 8, "%s", i == 15 ? "   A   A15 " : "");
        app(&s, 8, "%s ", (l0 >> i) & 1u ? G_ON : G_OFF);
    }
    app(&s, 8, " A0");
    for (i = 15; i >= 0; i--) {
        app(&s, 9, "%s", i == 15 ? "   SR  SR0  " : "");
        app(&s, 9, "%s ", sw_glyph(s0, i));
    }
    app(&s, 9, " SR15");
    app(&s, 10, "   RESET %s   MASTER-CLEAR %s   STORE/FETCH %s   P/P+1 %s   START %s",
        sw_glyph(s2, SW2_RESET), sw_glyph(s1, SW1_MCLR),
        sw_glyph(s1, SW1_SF), sw_glyph(s1, SW1_PP1), sw_glyph(s1, SW1_START));
    app(&s, 11, "   PFI/PFH %s   SENSE1 %s  SENSE2 %s  SENSE3 %s  SENSE4 %s",
        sw_glyph(s1, SW1_PFI), sw_glyph(s1, SW1_S1), sw_glyph(s1, SW1_S2),
        sw_glyph(s1, SW1_S3), sw_glyph(s1, SW1_S4));
    app(&s, 12, "   ROTARY %u (%s)   MA/SI/RUN %s",
        rot, rot < 6 ? rot_name[rot] : "?",
        ((s1 >> SW1_MA) & 1u) ? "MA" : (((s1 >> SW1_RUN) & 1u) ? "RUN" : "SI"));
    app(&s, 13, " %s", "--------------------------------------------------------------------------------");
    app(&s, 14, "   mode %-9s  %s  rt %-3s  frames %u.%u kHz",
        mode_name, paused ? "PAUSED " : "running", p->rt_ok ? "yes" : "no ",
        fps_x10 / 10, fps_x10 % 10);
    app(&s, 15, "   lamps %06o %06o %06o   sw %04X %04X %04X",
        l0, l1, l2, s0, s1, s2);
    app(&s, 16, "   %s", note ? note : "");

    /* Paint. Reuse the previous frame's scratch to avoid flicker: rewrite every
     * line in place and clear to end of line. */
    fputs("\033[H", stdout);
    for (i = 0; i < s.used; i++) {
        if (strcmp(out[i], s.line[i]) != 0) {
            fputs(s.line[i], stdout);
            fputs("\033[K", stdout);
            snprintf(out[i], sizeof(out[i]), "%s", s.line[i]);
        }
        fputs("\r\n", stdout);
    }
    fflush(stdout);
}

/* ---- terminal ----------------------------------------------------------- */
static struct termios saved_tio;
static int tio_saved = 0;

static void tui_enter(void)
{
    struct termios t;

    fputs("\033[?1049h\033[?25l\033[2J", stdout);   /* alt screen, no cursor */
    if (tcgetattr(0, &saved_tio) == 0) {
        tio_saved = 1;
        t = saved_tio;
        t.c_lflag &= (tcflag_t)~(ICANON | ECHO);
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;
        tcsetattr(0, TCSANOW, &t);
    }
    fflush(stdout);
}

static void tui_leave(void)
{
    fputs("\033[?25h\033[?1049l", stdout);
    fflush(stdout);
    if (tio_saved)
        tcsetattr(0, TCSANOW, &saved_tio);
}

static int key_wait(unsigned ms)
{
    fd_set fds;
    struct timeval tv;

    FD_ZERO(&fds);
    FD_SET(0, &fds);
    tv.tv_sec = (time_t)(ms / 1000);
    tv.tv_usec = (suseconds_t)((ms % 1000) * 1000);
    return select(1, &fds, NULL, NULL, &tv) > 0 ? 1 : 0;
}

/* ---- coverage self-check (headless) ------------------------------------- */
static void coverage(void)
{
    uint16_t l[3], or0 = 0, or1 = 0, or2 = 0;
    uint32_t t;

    /* The A row's address field scans 0..1023 at 50 ms per step, so one full
     * sweep takes ~51 s of pattern time. Simulate 60 s — this is arithmetic,
     * not wall-clock, so it costs nothing. */
    for (t = 0; t < 60000; t += 7) {
        pattern(t, 1, 0, l);
        or0 |= l[0];
        or1 |= l[1];
        or2 |= l[2];
    }
    printf("pattern coverage over 60 s of demo time (simulated), power lamp forced on:\n");
    printf("  A row     %06o  expected 177777  %s\n", or0,
           or0 == 0xFFFF ? "all 16 lamps used" : "INCOMPLETE");
    printf("  IMP1-12   %06o  expected 007777  %s\n", or1,
           or1 == 0x0FFF ? "all 12 lamps used" : "INCOMPLETE");
    printf("  IMP13-24  %06o  expected 107777  %s\n", or2,
           or2 == 0x8FFF ? "all 13 lamps used" : "INCOMPLETE");

    /* the lamp walk must touch exactly 41 distinct lamps */
    {
        uint16_t w0 = 0, w1 = 0, w2 = 0;
        int n = 0;
        for (t = 0; t < 41u * 120u; t += 120) {
            pattern(t, 0, 1, l);
            w0 |= l[0]; w1 |= l[1]; w2 |= l[2];
            n += __builtin_popcount((unsigned)l[0]) + __builtin_popcount((unsigned)l[1])
               + __builtin_popcount((unsigned)l[2]);
        }
        printf("  lamp walk %06o %06o %06o  %d lamps touched (expect 41)\n",
               w0, w1, w2, n);
    }
}

int main(int argc, char **argv)
{
    panel_t p;
    int use_hw = 1, walk = 0, mode = 0, paused = 0, solid = 0, static_mode = 0;
    long headless = -1;
    uint32_t t0, t1, prev[3] = { 0, 0, 0 };
    int i, have_prev = 0;
    const char *note = "";

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--no-gpio")) {
            use_hw = 0;
        } else if (!strcmp(argv[i], "--ascii")) {
            G_ON = "#"; G_OFF = "."; G_UP = "^"; G_DN = "v";
        } else if (!strcmp(argv[i], "--solid")) {
            solid = 1;
        } else if (!strcmp(argv[i], "--static")) {
            static_mode = 1;
        } else if (!strcmp(argv[i], "--headless") && i + 1 < argc) {
            headless = strtol(argv[++i], NULL, 10);
        } else if (!strcmp(argv[i], "--help")) {
            printf("usage: %s [--no-gpio] [--ascii] [--solid] [--headless N]\n\n"
                   "  --no-gpio    run the mux thread without touching GPIO\n"
                   "  --ascii      ASCII glyphs instead of UTF-8 lamps\n"
                   "  --solid      light every lamp continuously (meter/bring-up check)\n"
                   "  --static     no multiplexing at all: hold all lamps on (measure this)\n"
                   "  --headless N run N mux frames with the demo pattern, print timing, exit\n",
                   argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown option: %s\n", argv[i]);
            return 2;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (static_mode) {
        if (panel_static_on() != 0) {
            fprintf(stderr, "panel_static_on failed: %s\n", strerror(errno));
            return 1;
        }
        printf("static: all three rows HIGH, all 16 columns LOW — every lamp "
               "should be on steadily.\n");
        printf("measure now. Ctrl-C to release.\n");
        while (!quit_flag)
            sleep(1);
        panel_static_off();
        printf("released.\n");
        return 0;
    }

    if (headless >= 0) {
        coverage();
        if (panel_start(&p, use_hw) != 0) {
            fprintf(stderr, "panel_start failed: %s\n", strerror(errno));
            return 1;
        }
        t0 = now_ms();
        while (p.frames < (uint32_t)headless && !quit_flag) {
            uint32_t ms = now_ms() - t0;
            uint16_t l[3];

            if (solid) {
                l[0] = l[1] = l[2] = 0xFFFF;
            } else {
                pattern(ms, 1, 0, l);   /* power lamp forced on */
            }
            p.lamps[0] = l[0];
            p.lamps[1] = l[1];
            p.lamps[2] = l[2];
            usleep(5000);
        }
        t1 = now_ms();
        printf("last lamp words:   %06o %06o %06o\n",
               (unsigned)p.lamps[0], (unsigned)p.lamps[1], (unsigned)p.lamps[2]);
        panel_stop(&p);
        printf("\nmux: %u frames in %u ms = %.1f frames/s (%.2f ms/frame), rt=%s, hw=%s\n",
               (unsigned)p.frames, (unsigned)(t1 - t0),
               (t1 > t0) ? (float)p.frames * 1000.0f / (float)(t1 - t0) : 0.0f,
               (t1 > t0) ? (float)(t1 - t0) / (float)p.frames : 0.0f,
               p.rt_ok ? "yes" : "no", use_hw ? "yes" : "no");
        printf("last switch words: %04X %04X %04X  (all zeros = no switch closed, "
               "or no panel attached)\n",
               (unsigned)p.sw[0], (unsigned)p.sw[1], (unsigned)p.sw[2]);
        return 0;
    }

    if (!isatty(0) || !isatty(1)) {
        fprintf(stderr, "not a terminal — use --headless N for a non-interactive run\n");
        return 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    if (panel_start(&p, use_hw) != 0) {
        fprintf(stderr, "panel_start failed: %s\n", strerror(errno));
        return 1;
    }
    tui_enter();

    t0 = now_ms();
    while (!quit_flag) {
        uint32_t ms = now_ms() - t0;
        uint32_t fps_x10;
        uint32_t f0 = p.frames;
        uint16_t s1 = p.sw[1];

        if (!paused) {
            uint16_t l[3];
            int power_on = (int)((s1 >> SW1_POWER) & 1u);

            if (solid) {
                l[0] = l[1] = l[2] = 0xFFFF;
            } else {
                pattern(ms, power_on, walk, l);
            }
            if (!walk && mode)
                l[0] = ((p.sw[2] >> SW2_RESET) & 1u) ? 0 : p.sw[0];
            p.lamps[0] = l[0];
            p.lamps[1] = l[1];
            p.lamps[2] = l[2];
        }

        /* First switch change takes us out of the demo. */
        if (have_prev &&
            (p.sw[0] != prev[0] || p.sw[1] != prev[1] || p.sw[2] != prev[2])) {
            if (!mode && !walk) {
                mode = 1;
                note = "switch change seen — manual mode: lamps mirror the 16 switches, RESET blanks them";
            }
        }
        prev[0] = p.sw[0]; prev[1] = p.sw[1]; prev[2] = p.sw[2];
        have_prev = 1;

        /* Frames per second, refreshed once a second. */
        {
            static uint32_t last_ms = 0, last_f = 0;
            static uint32_t fps10 = 0;
            if (ms - last_ms >= 1000) {
                fps10 = (p.frames - last_f) / 100;   /* /100 → x10 kHz reading */
                last_ms = ms;
                last_f = p.frames;
            }
            fps_x10 = fps10;
        }
        draw(&p, mode, walk, paused, fps_x10, note);
        (void)f0;

        if (key_wait(50)) {
            char c;
            if (read(0, &c, 1) == 1) {
                if (c == 'q' || c == 3) { quit_flag = 1; }
                else if (c == 'd') { mode = 0; walk = 0; note = ""; }
                else if (c == 'm') { mode = 1; walk = 0; note = ""; }
                else if (c == 'p') { walk = !walk; mode = 0; note = walk ? "lamp walk" : ""; }
                else if (c == ' ') { paused = !paused; note = paused ? "paused" : ""; }
            }
        }
    }

    tui_leave();
    panel_stop(&p);
    printf("panel test stopped. %u frames; switches last seen %04X %04X %04X\n",
           (unsigned)p.frames, (unsigned)p.sw[0], (unsigned)p.sw[1], (unsigned)p.sw[2]);
    return 0;
}
