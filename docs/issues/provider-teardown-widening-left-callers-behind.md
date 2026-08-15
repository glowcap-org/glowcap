# Widening provider teardown to report failures left its callers behind

`zig build check` does not compile on `main`, and has not through several
commits of this work. Each one widens another teardown to report its failures
and leaves the drivers that call it discarding the result.

Failing as of `695054d63`:

```
interop/iroh_loop/driver.zig:97:24            defer server.deinit();
interop/iroh_reachability/driver.zig:156:24   defer server.deinit();
interop/goblins_interop/iroh_driver.zig:145   defer endpoint.deinit();
interop/iroh_interop/driver.zig:283:24        defer server.deinit();
interop/iroh_driver_provider/driver.zig:160   defer ci.pancake_iroh_netlayer_release(server_netlayer);
interop/webrtc_driver_provider/driver.zig:279 defer cw.pancake_webrtc_netlayer_release(offerer_netlayer);
bench/iroh_bench.zig:189:24                   defer server.deinit();
```

Every one is a `defer`, which is the shape this widening is hardest on: a
deferred teardown has nowhere to return a failure to, so each needs a decision
rather than a discard, which is the point of the change that widened them. That
is also why they keep appearing one commit at a time — the callers are only
found when something compiles them, and `check` has not got that far since the
first of these landed.

One more is mechanical: `examples/zig` moved with the same work and the site
slots extracted from it did not, so `gen-site-examples-check` reports four stale
slots in `site/content/start.smd` and `site/content/transports/iroh.smd`. The
fix is `zig build gen-site-examples`, run once the examples settle.

There is also a panic rather than a compile error, in its own note:
[a stream provider's refusal path unwraps a cancel callback it does not
require](stream-cancel-listen-unwrapped-on-refusal.md).

This is core and interop code, so it is written down here rather than fixed from
an application tree; it is owned by whoever is carrying that work.
