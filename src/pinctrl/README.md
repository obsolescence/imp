# pinctrl — vendored library

This directory is **not** our code. It is the `gpiolib` half of Raspberry Pi's
`pinctrl` utility, taken from `obsolescence/pidp10` (`src/utils/pinctrl/`),
which carries it as a copy of <https://github.com/raspberrypi/utils> →
`pinctrl/`.

It is vendored because it is the smallest piece of code that knows how to talk
to the GPIO block across the whole Pi range: BCM2835 (Pi 2/3), BCM2711 (Pi 4),
BCM2712 (Pi 5) and RP1. Those SoCs disagree about pull-up registers, and about
whether the GPIO block even lives where it used to — a hand-rolled mmap backend
for one of them silently does the wrong thing on the others. The IMP panel needs
internal pull-ups on its 16 column lines, so "which register" is not a detail we
can afford to get wrong.

## Files

| File | Purpose |
|---|---|
| `gpiolib.c/.h` | the API: init, mmap, direction, level, pull, fsel |
| `gpiochip.h` | the per-SoC interface that gpiolib dispatches to |
| `gpiochip_bcm2835.c` | BCM2835/2836/2837 (Pi 2, 3) |
| `gpiochip_bcm2712.c` | BCM2712 (Pi 5) |
| `gpiochip_rp1.c` | RP1 (Pi 5 south bridge) |
| `util.c/.h` | device-tree parsing helpers used above |

Deliberately not taken: `pinctrl.c` (the command-line client), the CMake file
and the completion script. We build with a plain makefile.

## Licence

BSD-3-Clause, Copyright (c) 2023 Raspberry Pi Ltd. Full text in `LICENCE`.
The files are unmodified; if they are ever patched here, note it in this file.

## Using it

```c
#include "gpiolib.h"

if (gpiolib_init() <= 0)          /* returns the GPIO count, not 0 */
        fail;
if (gpiolib_mmap() != 0)
        fail;

gpio_set_dir(7, DIR_OUTPUT);
gpio_set(7);                       /* level + direction in one call */
gpio_set_pull(10, PULL_UP);        /* Pi 2..5 handled internally */
int level = gpio_get_level(10);
```

Access goes through `/dev/gpiomemN` when the kernel provides it, so membership
of group `gpio` is enough on Raspberry Pi OS; only the fallback path
(`/dev/mem`, used when there is no `gpiomem` node) needs root.
