# Live driver conversations

These drivers run glowcap peers against each other over real transports.
A failure points to the driver, transport, or binding. Cross-implementation
conversations with Goblins belong in [`interop/`](../../../interop/README.md).
Shared language clients and the Zig harness use
[`test/support/transport/`](../../support/transport/).

`zig build check` compiles the Zig drivers. The steps below run them and need
their transport runtimes. Public relay discovery and Tor tests use the network.

| Directory | What it proves | Run |
| --- | --- | --- |
| [`iroh_session/`](iroh_session/)               | Live glowcap-to-glowcap OCapN over real iroh endpoints: direct dial, dial-by-id discovery, key unification, durable identity. | `zig build iroh-session`                                            |
| [`iroh_reachability/`](iroh_reachability/)     | Opt-in dial-by-id over n0 relays and DNS/pkarr. This uses real public discovery, not the in-process book. Zig driver plus per-binding siblings. | `zig build iroh-reachability` / `bindings-iroh-reachability` (`rust-iroh-reachability`, etc.) |
| [`iroh_loop/`](iroh_loop/)                     | Live iroh scale: many concurrent connections served from one `driver.Server` thread (ADR-0019).                          | `zig build iroh-loop` / binding siblings (`python-iroh-loop`, etc.) |
| [`iroh_redeem/`](iroh_redeem/)                 | Live three-party redeem over iroh: a recipient Session dials the exporter by node id inside the introducing call.             | `zig build iroh-redeem`                                             |
| [`iroh_handoff/`](iroh_handoff/)               | Per-binding three-party handoff over iroh in one process: each binding mints and redeems an iroh handoff give (Direct posture). | `zig build bindings-iroh-handoff` / siblings (`rust-iroh-handoff`, etc.) |
| [`iroh_driver_provider/`](iroh_driver_provider/) | The ADR-0024 seam live: the driver archive carries a whole conversation over a real iroh endpoint reached only through the common provider ABI, with Python and Rust parity siblings. | `zig build iroh-driver-provider` / `python-iroh-driver-provider` / `rust-iroh-driver-provider` |
| [`tcp_loop/`](tcp_loop/)                       | Live TCP scale: many concurrent connections served from one `driver.Server` thread, with a churn wave of fresh connections. | `zig build tcp-loop`                                                |
| [`onion_session/`](onion_session/)             | Live Tor: two glowcap peers hold an OCapN conversation over a real onion service. The driver starts its own Tor, so it needs `tor` on PATH and outbound network access. | `zig build onion-session`                                           |
