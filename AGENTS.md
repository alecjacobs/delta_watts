# delta_watts

macOS TUI for laptop battery power. Shows charge, AC vs battery, time remaining / to full, watts into or out of the pack, and a 60s history plot.

Ruby 3.0+, stdlib only. Darwin only. Launch via `bin/delta_watts` or the `dwatts` alias from `install.sh`. Quit with `q` or Ctrl+C.

Visual tone: quiet and compact. Color where it encodes state. Animations should be slow (pulse / ease), never flash.

## Layout

```
bin/delta_watts              CLI, interval flag, darwin guard
lib/delta_watts.rb           requires
lib/delta_watts/
  app.rb                     loop, terminal, history, sampling
  battery.rb                 ioreg → Snapshot
  renderer.rb                layout / frame
  sparkline.rb               7-row, 0-based, right-aligned plot
  ansi.rb                    escapes, palette, truecolor
  version.rb
```

`Snapshot` is the only data contract between battery and UI. Watts are `(amperage_ma * voltage_mv) / 1_000_000.0`. Positive current = charging; negative = discharging.

## Loop

`App` runs two clocks: frames at 0.25s (animation, easing, resize), battery samples at `--interval` (default 1s). History is one watt sample per second, last 60.

On each frame: ease displayed percent toward the real value, rebuild the frame, cursor-home and rewrite. On resize, full clear first. Always restore `stty -g`, cursor, wrap, and alt screen in `ensure` — do not use `IO#raw(mode:)` or `IO#raw=`.

## Battery

Source: `ioreg -r -c AppleSmartBattery -d 1 -w 0`. Regex-parse the text; do not round-trip through JSON/plist.

`ioreg` prints SInt64 as unsigned. Convert with `value - 2**64` when `value >= 2**63`. `TimeRemaining` / `AvgTimeToFull` of `65535` means unknown — estimate from raw mAh and current instead.

`InstantAmperage` / `Amperage` are often 0 for a few seconds after launch. Fall back to `BatteryPower` (and `SystemLoad` when unplugged) from `PowerTelemetryData`, converted mW → mA. Drop samples under 0.05 W unless fully charged so the graph does not start at zero.

## UI

`Renderer` draws a box: status, one summary row (bar + % + runtime + watts in/out), then the plot. `Sparkline` is a 7-row block chart, Y from 0 to a fixed ceiling, oldest left / now right. Unobserved time is `·`, not a filling bar.

Keep width-safe: truncate with `fit`, pad with `pad_between`, never let ANSI codes count toward visible width.
