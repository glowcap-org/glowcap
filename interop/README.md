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
its language bindings is a different seam again, exercised by `test/c_abi/`, the
binding checks (`*-dogfood`), and the self-contained per-binding proof families in
[`../bindings/proofs/`](../bindings/proofs/README.md), never called interop.

The toolchains these need (Racket with Goblins, Python, `cargo` for the iroh
sidecar, the binding runtimes) come from [`../.devcontainer/`](../.devcontainer/).
None of these steps is part of the self-contained `zig build check`; each is a sibling
that runs only when its runtime is on PATH.

Helpers the per-language interop clients share live in [`_common/`](_common/),
one directory per language; the Zig drivers' shared harness is
[`_common/zig/harness.zig`](_common/zig/harness.zig).

## Layout

| Directory                                      | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`goblins_interop/`](goblins_interop/)         | Live OCapN against a real Goblins vat: bidirectional conversation (`goblins-interop`); recipient handoff (`goblins-handoff`); gifter handoff (`goblins-gift`); exporter handoff (`goblins-exporter`); a relayed give read out of a listener fire (`goblins-relayed-give`); inbound export GC (`goblins-gc`); the same conversation over encrypted QUIC, both directions, through the iroh netlayer this repository wrote for Goblins (`goblins-iroh`). There are also binding client-direction siblings (`*-goblins-interop`), the Deno listener step (`deno-goblins-listen`), and binding siblings for the gifter and recipient roles. | `zig build goblins-interop` / `goblins-handoff` / `goblins-gift` / `goblins-exporter` / `goblins-relayed-give` / `goblins-gc` / `goblins-iroh` (+ `*-goblins-interop` / `deno-goblins-listen` / `*-goblins-handoff` / `*-goblins-gift`) |
| [`goblins_rooms/`](goblins_rooms/)             | A real Goblins vat as an ordinary member of the rooms chat, beside a pancake member: the vat's session settles on the v1.0 Syrup baseline while the pancake member's settles on pancake-next over Cap'n Proto, and the server's own live trace is what says so. | `zig build goblins-rooms`                                           |
| [`goblins_rooms_dm/`](goblins_rooms_dm/)       | A browser tab and a real Goblins vat hold a direct message: the room introduces them and carries none of it, the tab redeems the give by dialing the vat, and the vat answers over that same connection. Both transports the vat can be reached over, with the conversation drawn on the live timeline from both ends. | `zig build goblins-rooms-dm` / `goblins-rooms-dm-iroh`              |
| [`goblins_rooms_matrix/`](goblins_rooms_matrix/) | Sparse heavyweight end gate: clean modular runs cover room topology, every DM pair, close/reopen, and restart; a final run reproduces Goblins' pinned cross-receiver count defect. | `zig build goblins-rooms-matrix-iroh` |
| [`iroh_interop/`](iroh_interop/)               | Live pancake-to-pancake OCapN over real iroh endpoints: direct dial, dial-by-id discovery, key unification, durable identity. | `zig build iroh-interop`                                            |
| [`iroh_reachability/`](iroh_reachability/)     | Opt-in dial-by-id over n0 relays and DNS/pkarr — real public discovery, not the in-process book; Zig driver plus per-binding siblings. | `zig build iroh-reachability` / `bindings-iroh-reachability` (`rust-iroh-reachability`, etc.) |
| [`iroh_loop/`](iroh_loop/)                     | Live iroh scale: many concurrent connections from one readiness loop (ADR-0057).                                        | `zig build iroh-loop` / binding siblings (`python-iroh-loop`, etc.) |
| [`iroh_bridge_redeem/`](iroh_bridge_redeem/)   | Live iroh redeem dial on `driver.Bridge`: recipient on one loop thread redeems a handoff via `Loop.dialLocator` (ADR-0076).            | `zig build iroh-bridge-redeem`                                      |
| [`iroh_handoff/`](iroh_handoff/)               | Per-binding three-party handoff over iroh in one process: each binding mints and redeems an iroh handoff give (Direct posture). | `zig build bindings-iroh-handoff` / siblings (`rust-iroh-handoff`, etc.) |
