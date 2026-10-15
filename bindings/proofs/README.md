# bindings/proofs/

Each directory runs one end-to-end scenario through every language binding.
All peers are glowcap and all traffic stays on loopback, so a failure points to
the binding or C ABI and not to an interoperability disagreement.

These go deeper than the per-binding `zig_smoke.*` consumers, which touch the
whole API once. Cross-implementation tests belong in
[`interop/`](../../interop/README.md).

Rust clients live in `../rust/examples/`, where Cargo expects them. Deno,
Python, and Racket clients live with their scenario. Shared language helpers
are in [`interop/_common/`](../../interop/_common/).

| Family | What it proves | Run |
| --- | --- | --- |
| [`keyed_tcp_restart/`](keyed_tcp_restart/) | Restart, key-squatter refusal, identity continuity, and a new port with the same seed ([ADR-0075](../../docs/decisions/adr/ADR-0075-keyed-tcp-designator.md)) | `zig build bindings-keyed-tcp-restart` and language siblings |
| [`iroh_redeem_posture/`](iroh_redeem_posture/) | The recipient's redeem policy controls a hint-free iroh handoff | `zig build bindings-iroh-redeem-posture` and language siblings |
| [`keyed_relay_rendezvous/`](keyed_relay_rendezvous/) | A binding cold-dials a registered non-listening peer through the reference relay's rendezvous bridge ([ADR-0088](../../docs/decisions/adr/ADR-0088-fully-functioning-browser-peer.md)) | `zig build bindings-keyed-relay-rendezvous` and language siblings |
| [`noise_relay_listen/`](noise_relay_listen/) | Each binding registers a durable key, advertises its relay locator, and serves a Noise-sealed session dialed by one fixed client | `zig build bindings-noise-relay-listen` and language siblings |
| [`verb_spine/`](verb_spine/) | Promises, dials, listeners, and release walked against one fixed peer: a far send's handle and its `index`/`untag`/`get` results, the failed promise a send that could never be issued returns, a typed dial refusal, a listener served and closed, and a released capability refused afterwards | `zig build bindings-verb-spine` and language siblings |
| [`loam_browser/`](loam_browser/) | IndexedDB lifecycle, page reload, ownership and failure. [`_support/loam_management.rs`](_support/loam_management.rs) shares the bounded child/control, policy, restart and revocation trace with the Rust TCP/LMDB proof | `zig build loam-browser-test` and `zig build loam-rust-test` |

`zig build source-check` also reads these scripts. Every wrapped
`glowcap_host_*` verb must appear in a script that a build step runs.
