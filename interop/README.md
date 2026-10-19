# interop/

Cross-implementation interoperability drivers. They run glowcap against a live
Spritely Goblins vat over a real OCapN session, and against another glowcap over
a running transport (real iroh endpoints or a real Tor hidden service). A
failure here means two implementations disagree on the wire or two glowcap peers
cannot reach each other, not that a single layer's invariant broke.

Protocol fixtures under [`../conformance/`](../conformance/README.md) remain the
reference for wire correctness. The C ABI boundary between Zig and its
language bindings is a different seam, covered by `test/c_abi/`, the
binding checks that use the C ABI as a real consumer (`*-dogfood`), and the
per-binding proof families in
[`../bindings/proofs/`](../bindings/proofs/README.md). None of those is called
interop.

The toolchains these need (Racket with Goblins, Python, `cargo` for the iroh
sidecar, the binding runtimes) come from [`../.devcontainer/`](../.devcontainer/).
`zig build check` compiles these drivers but runs none of them. Each live step
needs its outside runtime on PATH.

Helpers the per-language interop clients share live in [`_common/`](_common/),
one directory per language. The Zig drivers' shared harness is
[`_common/zig/harness.zig`](_common/zig/harness.zig).

## Layout

| Directory                                      | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`goblins_interop/`](goblins_interop/)         | Live OCapN against a real Goblins vat: bidirectional conversation (`goblins-interop`). Recipient handoff (`goblins-handoff`). Gifter handoff (`goblins-gift`). Exporter handoff (`goblins-exporter`). A relayed give read out of a listener fire (`goblins-relayed-give`). Inbound export GC (`goblins-gc`). One corpus of mutated frames fed to the vat and to a glowcap listener, printing accept, refuse, or silent per side for a person to triage (`goblins-differential`). The same conversation over encrypted QUIC, both directions, through the iroh netlayer this repository wrote for Goblins (`goblins-iroh`). Binding matrices cover the client direction, the reciprocal listener direction, and both application-facing handoff roles in Deno, Python, Rust, and Racket. | `zig build goblins-interop` / `goblins-handoff` / `goblins-gift` / `goblins-exporter` / `goblins-relayed-give` / `goblins-gc` / `goblins-differential` / `goblins-iroh` (+ `bindings-goblins-interop` / `bindings-goblins-listen` / `bindings-goblins-handoff` / `bindings-goblins-gift`) |
| [`goblins_rooms/`](goblins_rooms/)             | A real Goblins vat as an ordinary member of the rooms chat, beside a glowcap member: the vat's session settles on the v1.0 Syrup baseline while the glowcap member's settles on glowcap-next over Cap'n Proto, and the server's own live trace is what says so. | `zig build goblins-rooms`                                           |
| [`goblins_rooms_dm/`](goblins_rooms_dm/)       | A browser tab and a real Goblins vat hold a direct message: the room introduces them and carries none of it, the tab redeems the give by dialing the vat, and the vat answers over that same connection. Both transports the vat can be reached over, with the conversation drawn on the live timeline from both ends. | `zig build goblins-rooms-dm` / `goblins-rooms-dm-iroh`              |
| [`goblins_rooms_irc/`](goblins_rooms_irc/)     | Both shipped IRC edges composed with real Goblins: a TLS/SASL IRC fixture exchanges room lines through the bridge, then an ordinary IRC client and Goblins exchange room traffic through the front before Goblins replies on the IRC-initiated direct session. | `zig build goblins-rooms-irc` (`-bridge` / `-front`) |
| [`goblins_rooms_peering/`](goblins_rooms_peering/) | A real Goblins vat enters a glowcap foreign listing over the v1.0 Syrup baseline, discovery is revoked, and the vat keeps using the room it was handed. | `zig build goblins-rooms-peering` |
| [`goblins_rooms_matrix/`](goblins_rooms_matrix/) | Sparse heavyweight end check: clean modular runs cover room topology, every DM pair, close/reopen, and restart. A final run reproduces Goblins' pinned cross-receiver count defect. | `zig build goblins-rooms-matrix-iroh` |
| [`iroh_interop/`](iroh_interop/)               | Live glowcap-to-glowcap OCapN over real iroh endpoints: direct dial, dial-by-id discovery, key unification, durable identity. | `zig build iroh-interop`                                            |
| [`iroh_reachability/`](iroh_reachability/)     | Opt-in dial-by-id over n0 relays and DNS/pkarr. This uses real public discovery, not the in-process book. Zig driver plus per-binding siblings. | `zig build iroh-reachability` / `bindings-iroh-reachability` (`rust-iroh-reachability`, etc.) |
| [`iroh_loop/`](iroh_loop/)                     | Live iroh scale: many concurrent connections served from one `driver.Server` thread (ADR-0019).                          | `zig build iroh-loop` / binding siblings (`python-iroh-loop`, etc.) |
| [`iroh_redeem/`](iroh_redeem/)                 | Live three-party redeem over iroh: a recipient Session dials the exporter by node id inside the introducing call.             | `zig build iroh-redeem`                                             |
| [`iroh_handoff/`](iroh_handoff/)               | Per-binding three-party handoff over iroh in one process: each binding mints and redeems an iroh handoff give (Direct posture). | `zig build bindings-iroh-handoff` / siblings (`rust-iroh-handoff`, etc.) |
| [`iroh_driver_provider/`](iroh_driver_provider/) | The ADR-0024 seam live: the driver archive carries a whole conversation over a real iroh endpoint reached only through the common provider ABI, with Python and Rust parity siblings. | `zig build iroh-driver-provider` / `python-iroh-driver-provider` / `rust-iroh-driver-provider` |
| [`tcp_loop/`](tcp_loop/)                       | Live TCP scale: many concurrent connections served from one `driver.Server` thread, with a churn wave of fresh connections. | `zig build tcp-loop`                                                |
| [`webrtc_interop/`](webrtc_interop/)           | Two glowcap peers hold a keyed OCapN session over a real DataChannel, signaling ferried in-process (ADR-0035).         | `zig build webrtc-interop`                                          |
| [`webrtc_mesh/`](webrtc_mesh/)                 | The capability-routed signaling shape: an in-process hub introduces two peers, then a keyed session runs over the DataChannel it brought up. | `zig build webrtc-mesh`                                             |
| [`webrtc_signaling_captp/`](webrtc_signaling_captp/) | The signaling object as a real OCapN capability: offer, answer, and candidates all cross a keyed CapTP session before the DataChannel exists. | `zig build webrtc-signaling-captp`                                  |
| [`webrtc_loop/`](webrtc_loop/)                 | Live WebRTC scale: many concurrent DataChannels served from one loop thread through the generic Host completion adapter.      | `zig build webrtc-loop`                                             |
| [`webrtc_redeem/`](webrtc_redeem/)             | WebRTC three-party redeem: a give naming a bare webrtc designator settles over a real DataChannel the recipient's runtime signals. | `zig build webrtc-redeem`                                           |
| [`webrtc_driver_provider/`](webrtc_driver_provider/) | The generic C driver dials WebRTC through the provider's signaling callbacks, the answerer is signaled by hand and adopted, and `glowcap_driver_step` is the only progress after that. The Rust, Python, Racket, and Deno clients dial the same answerer through their `webrtc.provider`, and the Rust client also listens, accepting `offerer.zig` through `webrtc::listen`. | `zig build webrtc-driver-provider` / `bindings-webrtc-driver-provider` |
| [`webrtc_browser_peer/`](webrtc_browser_peer/) | A real headless Chromium runs the wasm Host and dials the answerer over a DataChannel carrying a keyed session (`webrtc_common.zig` holds the shared sidecar plumbing). | `zig build webrtc-browser-peer` (+ `webrtc-answerer`)               |
| [`webrtc_browser_to_browser/`](webrtc_browser_to_browser/) | Two headless Chromium peers bring up a direct DataChannel through a byte-transparent signaling relay and hold a keyed session end to end. | `zig build webrtc-browser-to-browser`                               |
| [`onion_interop/`](onion_interop/)             | Live Tor: two glowcap peers hold an OCapN conversation over a real onion service. The driver starts its own Tor, so it needs `tor` on PATH and outbound network access. | `zig build onion-interop`                                           |

`zig build goblins-onion`, in [`goblins_interop/`](goblins_interop/), runs a
real Goblins vat and a glowcap peer over hidden service circuits in both
directions. `onion` is the netlayer the OCapN draft standardizes and upstream
Goblins ships, so this is the only live interop here over a transport this
repository did not write for the partner.
