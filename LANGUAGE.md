# Should this be rewritten in Rust / C?

No. Not for this.

The only part that needed to leave Ruby already did: `power_sampler.c` talking to IOReport and SMC. Everything else is “read a JSON line, keep ~240 samples, print ~20 ANSI lines, four times a second.” Ruby is idle most of that interval. A rewrite would not make the watts more honest or the chart less jumpy.

**C for the TUI** would be a downgrade. You would re-litigate unicode width, `stty`, alt screen, and resize, which is where this project actually hurt. The C you have is the right C: a small, boring helper with a one-line protocol.

**Rust** is the serious alternative, and the reason is not speed or “AI.” It is distribution: one `dwatts` binary, no Ruby 3, no `cc` on first launch. `ratatui` would be fine. That is a product/install argument, not a technical one. You do not have that problem yet. You have an alias and an install script on one Mac.

**“But AI”** slightly lowers the cost of a rewrite and does not change the cost of owning it. You still debug terminal restoration, private Apple APIs, and font metrics. Rust’s compiler would catch some mistakes; it would not have prevented the jumping chart, the `ioreg` SInt64, or `IO#raw=`. Those were domain bugs. AI is also already effective in the Ruby you like, so the leverage is not locked behind a new language.

Keep the split: Ruby for the UI and loop, C for the sensors. If you ever rewrite, do it for a single binary you want to hand to other people — not because the TUI is “too slow” or because a model is better at Rust.
