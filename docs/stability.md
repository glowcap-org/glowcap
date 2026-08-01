# What you can depend on

pancake has no stable release yet. The table below says what runs on every push,
whether that check crosses into code maintained outside this repository, and
what the check still leaves open. It is evidence, not a compatibility or
security promise.

For feature coverage, read [what ships](shipped.md). For consequences that may
change a deployment, read [known limitations](boundaries.md).

## Evidence by surface

| Surface | Evidence on every push | What remains |
| --- | --- | --- |
| Protocol core | The upstream OCapN suite and a live Goblins peer exercise model, session, engine, calls, promises, and all three handoff roles. | Community review lists the exact outside-peer gaps. |
| Syrup | Fixtures are regenerated with upstream Syrup encoders and compared byte for byte. | None known in the supported message set. |
| Cap'n Proto | In-tree golden frames and cross-codec tests run under `zig build check`. | No outside Cap'n Proto implementation reads pancake's hand-written format. |
| `tcp` | The OCapN and Goblins checks use it for live sessions. | The channel is cleartext. |
| `iroh` | `iroh-interop` and the relay checks use real iroh endpoints and its QUIC stack. | Both CapTP peers are pancake; two-NAT hole-punching is not in CI. |
| `keyed-tcp` and `inproc` | In-tree restart, refusal, and end-to-end netlayer tests run under `check`. | No outside peer speaks these transport symbols; `inproc` is test-only. |
| `webrtc` | Rust sidecar tests cover queue progress, retained capacity, runtime teardown, readiness coalescing, and exactly-once terminal publication. | The readiness-driven native DataChannel, browser, and signaling-mesh checks are manual rather than CI runs; generic Host adoption and handoff redemption are not built. |
| C ABI | Header parity, layouts, ownership, archives, and all binding consumers run in-tree. | There is no independent C consumer; live binding proofs still pass through this ABI. |
| Rust, Deno, Python, and Racket bindings | Each binding holds a live Goblins session as a client and in both handoff roles. | Only Deno has a live check in which Goblins dials the binding. |
| TypeScript on Bun | `bun-dogfood` exercises the shared TypeScript source against pancake. | No Bun-native Goblins check runs. |
| Native Zig driver and actor layer | Front-door session, host, handoff, turn-loop, hosting, and snapshot tests run under `check`. | These are pancake-native APIs with no outside implementation to compare. |
| Distributed GC | A live Goblins peer sends `op:gc-exports`; in-tree tests cover outbound release and `op:gc-answers`. | No live peer observes pancake's outbound GC or binding finalizers. |
| Relay | Every runtime runs TCP, backpressure, idle-reclaim, and iroh checks. The Deno relay also carries a live Goblins session. | The outside-peer proof does not run through the Python, Rust, or Racket relays. |
| CLI and MCP | In-tree command, exit-code, deadline, and listen/call tests run under `check`. | No independent tool drives the CLI as a compatibility test. |
| Browser WebAssembly | JavaScript-to-Wasm handshake and ABI checks run in CI. | Real Chromium peer, WebRTC, and cold-dial scenarios are manual checks. |
| Linux | The full CI sequence runs on Linux. | No claim is made for untested kernel or architecture combinations. |
| macOS | Cross-compilation checks the library and kqueue backend. | Nothing executes on macOS in CI. |
| Windows | Nothing. | Windows and an IOCP completion backend are not implemented. |
| Hostile-input and mutation tests | Bounded malformed-input tests and coverage-guided mutation runs cover codecs, framing, sessions, handoff, locators, the host, actors, and persistent collections. | The per-push fuzz budget is shallow, and most assertions are written by pancake. |

“Outside” evidence is useful only for the boundary it crosses. A live iroh
endpoint checks the transport stack, not agreement with another CapTP
implementation. A live Goblins session checks protocol interop, not API
stability. The table keeps those claims separate.

[Community review](community-review.md) is the detailed outside-peer matrix.

The evidence is current only when the
[checks workflow](https://github.com/jimisaacs/pancake/actions/workflows/check.yml)
is green for the commit you are evaluating. No row freezes an API or ABI, and
none is a security review.

## Checks run on every push

This list is compared with [`ci/gates.sh`](../ci/gates.sh) by
`zig build meta-check`, so a removed check cannot remain documented as
recurring evidence.

<!-- ci-gate-list:begin -->
- `zig build check`
- `zig build fuzz`
- `zig build iroh-sidecar-test`
- `zig build webrtc-sidecar-test`
- `zig build bindings-fmt-check`
- `zig build bindings`
- `zig build racket-test`
- `zig build wasm-driver-test`
- `zig build wasm-abi-layout-check`
- `zig build wasm-import-check`
- `zig build goblins-interop`
- `zig build bindings-goblins-interop`
- `zig build bindings-goblins-handoff`
- `zig build bindings-goblins-gift`
- `zig build goblins-handoff`
- `zig build goblins-gift`
- `zig build goblins-relayed-give`
- `zig build goblins-exporter`
- `zig build goblins-gc`
- `zig build deno-goblins-listen`
- `zig build goblins-relay`
- `zig build fixture-gen-check`
- `zig build ocapn-findings-check`
- `zig build ocapn-conformance`
- `zig build iroh-interop`
- `zig build bindings-relay`
- `zig build bindings-relay-iroh`
<!-- ci-gate-list:end -->

Checks that exist but do not appear above are manual. They may be useful
evidence, but a regression can survive until somebody runs them.
