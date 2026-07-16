# interop/

Cross-implementation interoperability drivers: pancake talking to a *different*
implementation over a real OCapN session. Two kinds live here, pancake against
a live Spritely Goblins vat, and pancake against another pancake over real iroh
endpoints. A failure here means two implementations disagree on the wire or two
pancake peers cannot reach each other, not that a single layer's invariant
broke.

These are live drivers, not the arbiters of correct. The external authority they
lean on — the Goblins peer they dial, the OCapN spec — lives in
[`../conformance/`](../conformance/README.md). The C-ABI boundary between Zig and
its language bindings is a different seam again, exercised by `test/c_abi/` and
the binding checks (`*-dogfood`), never called interop.

The toolchains these need (Racket with Goblins, Python, `cargo` for the iroh
sidecar, the binding runtimes) come from [`../.devcontainer/`](../.devcontainer/).
None of these steps is part of the self-contained `zig build check`; each is a sibling
that runs only when its runtime is on PATH.

## Layout

| Directory                                      | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`goblins_interop/`](goblins_interop/)         | Live OCapN against a real Goblins vat: bidirectional conversation (`goblins-interop`); recipient handoff (`goblins-handoff`); gifter handoff (`goblins-gift`); inbound export GC (`goblins-gc`); binding siblings for both handoff roles. | `zig build goblins-interop` / `goblins-handoff` / `goblins-gift` / `goblins-gc` (+ `*-goblins-handoff` / `*-goblins-gift`) |
| [`iroh_interop/`](iroh_interop/)               | Live pancake-to-pancake OCapN over real iroh endpoints: direct dial, dial-by-id discovery, key unification, durable identity. | `zig build iroh-interop`                                            |
| [`iroh_reachability/`](iroh_reachability/)     | Opt-in dial-by-id over n0 relays and DNS/pkarr — real public discovery, not the in-process book; Zig driver plus per-binding siblings. | `zig build iroh-reachability` / `bindings-iroh-reachability` (`rust-iroh-reachability`, etc.) |
| [`iroh_loop/`](iroh_loop/)                     | Live iroh scale: many concurrent connections from one readiness loop (ADR-0057).                                        | `zig build iroh-loop` / binding siblings (`python-iroh-loop`, etc.) |
| [`iroh_bridge_redeem/`](iroh_bridge_redeem/)   | Live iroh redeem dial on `driver.Bridge`: recipient on one loop thread redeems a handoff via `Loop.dialLocator` (ADR-0076).            | `zig build iroh-bridge-redeem`                                      |
| [`iroh_mesh/`](iroh_mesh/)                     | Three-party handoff where the recipient reaches the exporter over iroh by the gifted node id.                                 | `zig build iroh-mesh`                                               |
| [`iroh_handoff/`](iroh_handoff/)               | Per-binding three-party handoff over iroh in one process: each binding mints and redeems an iroh handoff give (Direct posture). | `zig build bindings-iroh-handoff` / siblings (`rust-iroh-handoff`, etc.) |
| [`iroh_redeem_posture/`](iroh_redeem_posture/) | Per-binding self-contained check that a recipient's configured redeem posture governs a hint-less iroh give — redeemed by id through an in-process `local_discovery` book (the Rust client lives in `bindings/rust/examples/`). | `zig build bindings-iroh-redeem-posture` / siblings (`rust-iroh-redeem-posture`, etc.) |
| [`keyed_tcp_restart/`](keyed_tcp_restart/)     | Per-binding keyed-tcp restart check (ADR-0075): happy path, key-squatter refusal, same-seed fresh-port restart (the Rust client lives in `bindings/rust/examples/`). | `zig build bindings-keyed-tcp-restart` / siblings (`rust-keyed-tcp-restart`, etc.) |
