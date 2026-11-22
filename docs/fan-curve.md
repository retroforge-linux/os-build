# Fan curve

The fan is driven by `retroforge-powerd`, which evaluates a temperature→PWM curve every 3
seconds. There is one curve for the device, not one per game. (Until 2026-10-03 each power
profile had its own; the profiles are gone, and the curve the default profile used, `moderate`,
is now the factory curve.)

Three factory curves ship in `/usr/share/retroforge/power.conf` (`relaxed`, `moderate`,
`aggressive`); `[fan] curve=` picks one. The curve is editable over D-Bus (below);
there is no on-screen editor yet — the shell's UI will expose one later, on top of the same
interface.

## What the daemon actually does with it

The curve is a list of points. Between two points the PWM is **linearly interpolated**;
below the first and above the last it is held flat. On top of that the fan tick applies
three things the curve does not express:

| Setting | Default | Effect |
|---|---|---|
| `smoothing` | `0.50` | EWMA over the temperature, so a one-tick spike does not audibly kick the fan |
| `ramp_up` / `ramp_down` | `36` / `6` | Max PWM change per tick — fast to spin up, slow to wind down |
| `pwm_quantum` | `8` | Rounds the result, so the fan sits on a stable speed instead of hunting |
| `min_pwm` / `max_pwm` | `51` / `255` | Hard floor and ceiling; the floor is what keeps the fan from stalling |

The temperature fed into the curve is a blended average of the hottest three of the
CPU/GPU/video/memory thermal zones. `retroforge-powerd` publishes that same number as its
`Temperature` property, so what a client shows is what the curve is evaluated against.

## The editable form: fixed temperature stops

A client edits one PWM value per **fixed temperature stop** (`60, 70, 80, 90, 100 °C` by
default, from `[fan] curve_stops`). The D-Bus property, the config file and the daemon all speak
raw PWM; a UI that shows percent does that conversion itself.

Only the fan speeds are editable. That is deliberate: with the temperatures fixed and sorted, a
curve that falls as the device heats up is unreachable rather than rejected, so there is no invalid
state and no error to report. `retroforge-powerd` enforces the non-falling rule and clamps to
`min_pwm`/`max_pwm` on anything a client sends.

A factory curve is reported resampled onto those stops — exact at each stop, since that is the
curve's own value there. `FanCurveIsCustom` says whether the curve in force is a custom one.

## Where a custom curve is stored

Config is three layers, lowest first:

1. `/usr/share/retroforge/power.conf` — factory, part of the read-only image
2. `/etc/retroforge/power.conf` — the operator's own overrides
3. `/etc/retroforge/power.conf.d/*.conf` — drop-ins, read in sorted order

`retroforge-powerd` writes only `50-fan-curves.conf` in layer 3, and rewrites that file in full on
every `FanCurve` set. Layer 2 is never touched, because `configparser` cannot round-trip comments
and a curve edit must not eat an operator's notes. An operator who wants the last word
can use a higher-numbered drop-in (`90-mine.conf`), which is read after ours.

The stored format is the ordinary curve grammar, so a hand-written curve may have any
number of points at any temperatures:

```ini
[fan_curve.custom]
label=Custom
curve=100:240,90:180,80:120,70:90,60:60

[fan]
curve=custom
```

A drop-in section merges key-by-key with the factory one, so overriding `[fan] curve=` leaves
the rest of `[fan]` alone. `curve=` may also spell the points out inline instead of naming a
`[fan_curve.*]` section.

> A curve hand-authored with points **off** the stops still applies verbatim — but writing
> `FanCurve` flattens it onto the stops.

If any layer fails to parse, `retroforge-powerd` quarantines **every** user layer to
`*.invalid-<timestamp>` and comes up on factory defaults, logging what it dropped. The
quarantine suffix goes after `.conf` so a quarantined drop-in stops matching the glob.

## From a shell

The interface is `org.retroforge.Power1` on the system bus (`org.retroforge.Power`,
`/org/retroforge/Power`). `wheel` may call it, and `player` is in `wheel`, so it needs no `sudo`.

```sh
# The stops, and the current curve
busctl get-property org.retroforge.Power /org/retroforge/Power org.retroforge.Power1 FanCurveStops
busctl get-property org.retroforge.Power /org/retroforge/Power org.retroforge.Power1 FanCurve

# Set all five speeds at once (count first, then one value per stop)
busctl set-property org.retroforge.Power /org/retroforge/Power org.retroforge.Power1 \
  FanCurve au 5 60 90 120 180 240

# Back to the factory curve
busctl call org.retroforge.Power /org/retroforge/Power org.retroforge.Power1 ResetFanCurve
```

Editing the files directly is equally supported; `busctl call ... Reload` re-reads all
three layers without restarting the daemon.

## Two-speed fans

A gpio-fan with one speed above off (`is_two_speed_fan`; the MANGMI Air X and Air Y) has no PWM to follow the
curve with: any value above 0 is full. `retroforge-powerd` switches it on where the curve reaches
`[fan] switch_on_pwm` and off once the curve at the temperature plus `switch_hysteresis` is below
that again. A board profile can instead pin the switch to fixed temperatures with
`RETROFORGE_FAN_ON_ABOVE` and `RETROFORGE_FAN_OFF_BELOW` (`[fan] on_above` / `off_below`): on
above the first, off below the second, unchanged in between. The Air X and Air Y use 60 / 50 °C,
the Air X's stock Android default fan mode (MANGMI's SystemService switches the same GPIO every 10 s).
The curve then does not affect that fan.

## Tests

`tests/test-fan-curve.sh` (part of `make test`) drives the real parse, resample, write and
reset paths against fabricated config trees: layer precedence, that an operator's comments
survive a write, that a reset falls back to the operator's curve, and that a bad drop-in is
quarantined rather than re-broken on the next boot.
