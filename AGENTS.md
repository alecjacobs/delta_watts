# delta_watts

macOS TUI for laptop battery power. Shows charge, AC vs battery, time remaining / to full, live system draw, and a 60s history plot.

Ruby 3.0+, stdlib plus a small C helper. Darwin only. Launch via `bin/delta_watts` or the `dwatts` alias from `install.sh`. Quit with `q` or Ctrl+C.

Visual tone: quiet and compact. Color where it encodes state. Animations should be slow (pulse / ease), never flash.

## Layout

```
bin/delta_watts              CLI, interval flag, darwin guard
ext/power_sampler.c          IOReport energy deltas + SMC PSTR
libexec/power_sampler        built helper (gitignored)
lib/delta_watts.rb           requires
lib/delta_watts/
  app.rb                     loop, terminal, history, sampling
  battery.rb                 ioreg → Snapshot (charge / runtime)
  power.rb                   builds/runs the C sampler
  renderer.rb                layout / frame
  sparkline.rb               7-row, 0-based, right-aligned plot
  ansi.rb                    escapes, palette, truecolor
  version.rb
```

`Snapshot` is the battery contract: percent, charge state, time remaining. Watts on screen are **system draw**, not pack current.

## Loop

`App` runs two clocks: frames at 0.25s (animation, easing, resize, power sample), battery samples at `--interval` (default 1s). History is ~4 samples/sec for the last 60s.

On each frame: ease displayed percent, sample live watts, rebuild the frame, cursor-home and rewrite. On resize, full clear first. Always restore `stty -g`, cursor, wrap, and alt screen in `ensure` — do not use `IO#raw(mode:)` or `IO#raw=`. Stop the power sampler in teardown.

## Live watts

Do not use `InstantAmperage` / `ioreg` for the live number or chart. The pack gas gauge is cached and can sit still for many seconds.

The C helper talks to the same private APIs as macmon / `powermetrics` (no sudo):

1. `IOReport` Energy Model: `CPU Energy`, `GPU Energy`, `ANE` — energy delta / elapsed time → watts
2. SMC key `PSTR` — total system power

Display `max(PSTR, cpu+gpu+ane)`. Link with `-lIOReport` (not the IOReport framework). If the helper is missing or fails, fall back to pack watts from `Battery`.

## Battery

Source: `ioreg -r -c AppleSmartBattery -d 1 -w 0`. Regex-parse the text; do not round-trip through JSON/plist. Used for charge bar, AC/battery state, and time remaining only.

`ioreg` prints SInt64 as unsigned. Convert with `value - 2**64` when `value >= 2**63`. `TimeRemaining` / `AvgTimeToFull` of `65535` means unknown — estimate from raw mAh and current instead.

## UI

`Renderer` draws a box: status, one summary row (bar + % + runtime + system draw), then the plot. `Sparkline` is a 7-row block chart, Y from 0 to an auto-scaled ceiling (`ceil(max * 1.25)` snapped to 5/10/20/50W…), oldest left / now right. Unobserved time is `·`, not a filling bar. Do not scale to adapter watts.

Keep width-safe: truncate with `fit`, pad with `pad_between`, never let ANSI codes count toward visible width.
