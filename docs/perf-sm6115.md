# SM6115 (MANGMI Air X) performance audit: settings and pitfalls

Measured on an Air X MQ66 (Snapdragon 662: 4x Cortex-A73 @ 2.11 GHz + 4x Cortex-A53 @ 2.02 GHz,
Adreno 610 at 320-1050 MHz, 1080x1920 portrait panel scanned out rotated), 2026-10-10. GPU time
per process is from the `drm_msm_gpu:msm_gpu_submit_retired` tracepoint; CPU loads from a 60 fps
frame-loop stand-in (`tools/perf/framesim.c`, ~6 ms of work per frame on an A73 at full clock,
two threads, 15 s per run).

## Defaults that are right (keep them)

| Setting | Why |
|---|---|
| CPU governor **ondemand** (qforge-powerd) | 7.8 ms/frame, 1% missed, game threads on the A73s |
| Stock scheduler (EEVDF), no sched_ext | see LAVD below |
| **Animated Effects off** (OGUI, patch 0006) | the idle shell otherwise pins the GPU at 1050 MHz |
| `--composite-blit` + `--force-composition-rotation` (session.conf) | single layers and two layers (a HUD) scan out pre-rotated, UBWC, on the DPU planes; ~1.1 ms of GPU per layer per frame for the rotated copy |
| `TU_DEBUG=noconform` | turnip only offers Vulkan 1.3 on the A610 with it |
| Mesa ISA floor `armv8-a+crc` + outline atomics | ARMv8.2 code SIGILLs here |

## Pitfalls found (and what now guards them)

| Pitfall | Measured | Guard |
|---|---|---|
| Touch on the SPI touchscreen | taps unrotated: axes swapped, scrolling inverted | gamescope patch 0033 |
| OGUI home banner's animated god-rays shader | idle shell: 40 submits/s at 47 ms GPU each, GPU at 1050 MHz, ~20 fps; with it hidden: zero submits, GPU runtime-suspended at 320 MHz | OGUI patch 0006: Settings > General > Animated Effects, default off |
| **schedutil** turns on energy-aware scheduling | EAS packs game threads onto the A53s: 36 ms/frame, **95% missed** | qforge-powerd writes `sched_energy_aware=0` after every governor change (`[cpu] energy_aware=off`). schedutil with EAS off: 7.8 ms, 1-2% missed, 15-20% lower average clocks than ondemand |
| **scx_lavd** | puts one of two game threads on the A53s: 35-48 ms, 76-86% missed, under every governor | SM6115 profiles set `QFORGE_CPU_SCHEDULERS=none` |
| OGUI **core count** slider | PowerStation offlined from the top: "4 cores" kept the four A53s | PowerStation patch 0003: fastest cores (cpu_capacity) kept online first |
| Screenshots (gamescope) | every screenshot crashed gamescope (no cached+coherent memory type on the A610) | gamescope patch 0032 |
| Battery state in OGUI | 50% / charging on a full battery: UPower averaged in the charger's empty companion supply; also drove the docked/undocked performance profile | kernel patch 0967 (built, not yet booted) |
| GPU load in OGUI / PowerStation | `gpu_busy_percent` "not supported" | kernel patch 0265 (built, not yet booted) |

## OpenGamepadUI's frame cost (why navigation lagged)

Profiled with Godot's own viewport GPU timer (`RenderingServer.viewport_get_measured_render_time_gpu`)
from a throwaway probe plugin, OGUI forced to redraw continuously, hiding one branch at a time:

| Change | GPU per frame | Menu navigation, frames on screen |
|---|---|---|
| stock, 1920x1080 | 19.6 ms | 27/s |
| + banner collage clipped by scissor (OGUI patch 0007) | 13.9 ms | |
| + rendered at the 1280x800 design size (`QFORGE_UI_VIEWPORT_RENDER=1`) | 7.9 ms | 34/s |
| + low-processor mode off for 1.5 s after input (plugin) | 7.9 ms | **61/s** |

- The home banner's collage used `clip_children` with an all-opaque mask: an offscreen canvas
  group every frame for what is a rectangle clip (~6 ms).
- The rest is overdraw: each full-screen layer costs the Adreno 610 ~2 ms at 1920x1080 (background
  panel, banner, its black base, card shelf); the empty window costs 1.1 ms.
- Godot's low-processor mode keeps the idle shell at zero cost but paces animations at ~35 fps.
- Not the cause: renderer choice (Forward+, Mobile equal; GL compatibility worse), vsync, the
  gamescope WSI layer, or the GPU clock ramp after idle (full clock within ~70 ms).
- Left alone: the cards' and icons' `clip_children` masks are real shape masks (rounded corners);
  replacing them saves ~1.3 ms but squares the cards.

## Measured, no change needed

- **Godot renderer for OGUI**: Forward Mobile 17.9 ms/submit (26 fps, CPU 74%), GL compatibility
  10.8 ms/submit but CPU-bound at 20 fps (CPU 94%); Forward+ is fine once the god-rays are off.
- **TU_DEBUG sysmem / gmem / noubwc**: no effect on the shell's cost (not a tiling or bandwidth issue).
- **OGUI max_fps 30 vs 60** at idle: CPU 21% vs 27% (it no longer renders at idle anyway).
- **GPU manual clock range** (OGUI performance menu -> PowerStation -> devfreq): applies (max 600
  held at 600 under load) and returns to 320-1050 in automatic.
- **SMT toggle**: sysfs reports `notsupported`; PowerStation 0001 already keeps the core count whole.
- **Interrupts**: all device IRQs land on cpu0; worst case (Wi-Fi download) cpu0 spends ~9% of one
  A53 on irq+softirq (Wi-Fi ~2,100/s, GPU ~240/s, joypad UART ~250/s). Spreading them over
  cpu1-3 is a small, low-priority gain.
- **Fan**: the gpio fan reported 8,600 rpm at 36 C on the factory curve's 64/255 PWM floor;
  gpio-fan has few steps -- worth a listen and a curve check, not a performance issue.

## Steam on this SoC

See `docs/steam-arm64.md`. Its Big Picture sign-in screen alone holds the GPU ~80% busy.
