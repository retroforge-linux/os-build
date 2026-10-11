# The hardware map: `/run/qforge/hw`

Every board names its battery, charger, backlight, thermal zones, fan and LEDs differently, because
the kernel names them after the devicetree. The MANGMI Air X keeps its battery at
`/sys/class/power_supply/battery` next to a `bq256xx-battery` node that is the charger's companion
and knows only `charge_full_design`; its CPU temperature is spread over per-core and per-cluster
zones; its stick rings are eighteen `rgb:l1..l9` / `rgb:r1..r9` multicolour LEDs. Anything that
wants to show or drive that hardware would otherwise carry a list of per-board sysfs names.

`/usr/lib/qforge/hw-map` resolves all of it, once per boot (and again when such a device appears
late), into one tree of links into sysfs:

| path | points at | read |
|---|---|---|
| `battery` | `/sys/class/power_supply/<battery>` | `capacity`, `status`, `voltage_now`, `current_now`, `temp`, `health`, `cycle_count`, `charge_full[_design]` |
| `charger` | `/sys/class/power_supply/<charger>` | `online`, `status` |
| `backlight` | `/sys/class/backlight/<panel>` | `brightness`, `max_brightness` |
| `thermal/cpu`, `thermal/gpu`, `thermal/battery`, `thermal/skin` | a thermal zone | `temp` (millidegrees); a role is absent when no zone fits |
| `thermal/all/<type>` | every zone, by its type name | `temp` |
| `fan` | the hwmon with a fan | `fan1_input` (rpm) |
| `gpu` | the GPU's devfreq directory | `cur_freq`, `min_freq`, `max_freq` |
| `cpu` | `/sys/devices/system/cpu` | `cpufreq/policy*/scaling_cur_freq`, ... |
| `leds/<group>/01..` | `/sys/class/leds/<led>` | `brightness`, `max_brightness`, `multi_intensity` |
| `hw.env` | a sourceable `KEY=value` summary of what was resolved | `QFORGE_HW_*`, `QFORGE_DEVICE_*` |

A consumer tests for a link and reads through it; a missing link means the board has no such thing.
The links point into sysfs, so values are live and nothing copies them.

## Per-board input

The board profile (`/usr/lib/qforge/devices/<id>.conf`, through `device-env`) may pin any node with
`QFORGE_HW_BATTERY`, `QFORGE_HW_CHARGER`, `QFORGE_HW_BACKLIGHT`, `QFORGE_HW_THERMAL_{CPU,GPU,BATTERY,SKIN}`
(thermal zone *type* names), `QFORGE_HW_FAN` (hwmon name), `QFORGE_HW_GPU_DEVFREQ` and
`QFORGE_HW_LED_GROUPS` (`"group=glob[,glob] ..."` over `/sys/class/leds`). Everything left empty is
detected: the first battery that reports a `capacity`, the first non-battery supply with `online`
(preferring one that also reports a `status`, i.e. the charger IC over a bare Type-C source), the
first backlight, zone types matching `^(cpu|soc)`, `^gpu`, `^batt`, `skin|xo-therm|quiet|case`, the
first hwmon with `fan1_input`, the `*gpu*` devfreq, and `power=power-led` when that LED exists.
`defaults.conf` documents the fields; the Air X profile pins its CPU zone and LED rings.

## Consumers

- The OpenGamepadUI plugin's **Quick bar > Hardware** card (`apps/ogui-qforge-plugin/plugin/hardware_card.gd`
  over `hardware_info.gd`) shows battery, charger, temperatures, fan, clocks, backlight and LED
  groups from this tree, hiding whatever the board lacks. No board-specific code.
- **qforge-powerd** drives the `fan` link's hwmon (a two-speed gpio-fan is switched on/off at
  the curve's first step) and every LED in `leds/<group>/` (colour on multicolor LEDs, brightness
  on all; off for suspend). It falls back to scanning sysfs only when the map is absent or names
  no LEDs. Its D-Bus interface (`org.qforge.Power1`) is how a UI changes them: `FanCurve`,
  `LedCount`, `LedEnabled`, `LedColor` (R, G, B), `LedBrightness` (0-255), kept in
  `/etc/qforge/power.conf.d/50-{fan-curves,leds}.conf`. `qforge-powerd.service` starts after
  `qforge-hw.service`.
- The plugin's Hardware card also carries the LED controls (Lights, Brightness, colour), through
  powerd's D-Bus interface only (`power_client.gd`), hidden when `LedCount` is 0.
- Scripts: `. /run/qforge/hw/hw.env` or read through the links.

## Layering

Board differences live in data: the profile names nodes, hw-map resolves them, the daemons
(PowerStation, InputPlumber, UPower, and qforge-powerd for fan and LEDs) drive them, and the UI
talks to the daemons over D-Bus. A new board is a profile (and DTS), not code.

## Tests

`tests/test-hw-map.sh` drives the real script against a fabricated sysfs (`QFORGE_HW_SYS`,
`QFORGE_HW_RUN`, `QFORGE_HW_DEVICE_ENV`); `tests/test-plugin.sh` runs the reader's parsing and
formatting in a stock headless Godot when one is available.
