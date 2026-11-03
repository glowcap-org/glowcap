# interop/

Cross-implementation interoperability drivers. They run glowcap against a live
Spritely Goblins vat over a real OCapN session. Tests between glowcap peers
live in [`test/driver/transports`](../test/driver/transports/README.md).

Protocol fixtures under [`../conformance/`](../conformance/README.md) remain the
reference for wire correctness. The C ABI boundary between Zig and its
language bindings is a different seam, covered by `test/c_abi/`, the
binding test suites that use the C ABI as a real consumer (`*-test`), and the
per-binding proof families in
[`../bindings/proofs/`](../bindings/proofs/README.md). None of those is called
interop.

The toolchains these need (Racket with Goblins, Python, `cargo` for the iroh
sidecar, the binding runtimes) come from [`../.devcontainer/`](../.devcontainer/).
`zig build check` compiles these drivers but runs none of them. Each live step
needs its outside runtime on PATH.

Shared language helpers and the Zig conversation harness live in
[`test/support/transport/`](../test/support/transport/).

## Layout

| Directory                                      | What it is                                                                                                                    | Run                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [`goblins_interop/`](goblins_interop/)         | Live OCapN against a real Goblins vat: bidirectional conversation, including a pending answer passed in argument position each way (`goblins-interop`). Recipient handoff (`goblins-handoff`). Gifter handoff (`goblins-gift`). Exporter handoff (`goblins-exporter`). A relayed give read out of a listener fire (`goblins-relayed-give`). Inbound export GC (`goblins-gc`). One corpus of mutated frames fed to the vat and to a glowcap listener, printing accept, refuse, or silent per side for a person to triage (`goblins-differential`). The same conversation over encrypted QUIC, both directions, through the iroh netlayer this repository wrote for Goblins (`goblins-iroh`). Binding matrices cover the client direction, the reciprocal listener direction, and both application-facing handoff roles in Deno, Python, Rust, and Racket. | `zig build goblins-interop` / `goblins-handoff` / `goblins-gift` / `goblins-exporter` / `goblins-relayed-give` / `goblins-gc` / `goblins-differential` / `goblins-iroh` (+ `bindings-goblins-interop` / `bindings-goblins-listen` / `bindings-goblins-handoff` / `bindings-goblins-gift`) |
| [`goblins_rooms/`](goblins_rooms/)             | A real Goblins vat as an ordinary member of the rooms chat, beside a glowcap member: the vat's session settles on the v1.0 Syrup baseline while the glowcap member's settles on glowcap-next over Cap'n Proto, and the server's own live trace is what says so. | `zig build goblins-rooms`                                           |
| [`goblins_rooms_dm/`](goblins_rooms_dm/)       | A browser tab and a real Goblins vat hold a direct message: the room introduces them and carries none of it, the tab redeems the give by dialing the vat, and the vat answers over that same connection. Both transports the vat can be reached over, with the conversation drawn on the live timeline from both ends. | `zig build goblins-rooms-dm` / `goblins-rooms-dm-iroh`              |
| [`goblins_rooms_irc/`](goblins_rooms_irc/)     | Both shipped IRC edges composed with real Goblins: a TLS/SASL IRC fixture exchanges room lines through the bridge, then an ordinary IRC client and Goblins exchange room traffic through the front before Goblins replies on the IRC-initiated direct session. | `zig build goblins-rooms-irc` (`-bridge` / `-front`) |
| [`goblins_rooms_peering/`](goblins_rooms_peering/) | A real Goblins vat enters a glowcap foreign listing over the v1.0 Syrup baseline, discovery is revoked, and the vat keeps using the room it was handed. | `zig build goblins-rooms-peering` |
| [`goblins_rooms_matrix/`](goblins_rooms_matrix/) | Sparse heavyweight end check: clean modular runs cover room topology, every DM pair, close/reopen, and restart. A final run reproduces Goblins' pinned cross-receiver count defect. | `zig build goblins-rooms-matrix-iroh` |

`zig build goblins-onion`, in [`goblins_interop/`](goblins_interop/), runs a
real Goblins vat and a glowcap peer over hidden service circuits in both
directions. `onion` is the netlayer the OCapN draft standardizes and upstream
Goblins ships, so this is the only live interop here over a transport this
repository did not write for the partner.
