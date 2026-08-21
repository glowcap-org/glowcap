# What you can depend on

pancake has no stable release yet. The table below records the evidence
available for each area, whether it crosses into code maintained outside this
repository, and what it leaves open. Some checks run on every main-branch push
and pull request; others need external runtimes or network access and run on
demand. None is a compatibility or security promise.

For feature coverage, read [what ships](shipped.md). For consequences that may
change a deployment, read [known limitations](boundaries.md).

## Evidence by area

| Area | Evidence | What remains |
| --- | --- | --- |
| Protocol core | The upstream OCapN suite and a live Goblins peer exercise V1.0 model, session, engine, calls, promises, and all three handoff roles. In-tree scenarios exercise the next-profile promise-listen behavior (OCapN PR 282) in `pancake-next`. | No outside peer exercises the next profile; community review lists the other exact gaps. |
| Syrup | Fixtures are regenerated with upstream Syrup encoders and compared byte for byte. | None known in the supported message set. |
| Cap'n Proto | In-tree golden frames and cross-codec tests run under `zig build check`. | No outside Cap'n Proto implementation reads pancake's hand-written format. |
| `tcp` | Live Goblins interoperability runs over pancake's cleartext TCP adapter. The upstream OCapN suite uses its own `tcp-testing-only` transport. | Goblins ships onion rather than TCP. The channel is cleartext and the peer proves no identity. |
| `iroh` | `iroh-interop` and relay checks use real iroh endpoints and its QUIC stack. The on-demand `goblins-iroh` check reaches a Goblins vat through pancake's adapter. | Two-NAT hole-punching is not in CI. Goblins ships no iroh netlayer, and `goblins-iroh` requires Cargo and Racket. |
| `keyed-tcp` and `inproc` | In-tree restart, refusal, and end-to-end netlayer tests run under `check`. | No outside peer speaks these transport symbols; `inproc` is test-only. |
| `noise-tcp` | In-tree sealed-channel and netlayer tests run under `check`. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it. | No outside CapTP peer speaks Noise; this is pancake-to-pancake. `BlockingSession` cannot apply the sealed-channel protocol. |
| `keyed-relay` | In-tree netlayer tests run under `check`. On-demand rendezvous checks (`bindings-keyed-relay-rendezvous`, `zig-keyed-relay-register`) cold-dial a registered, non-listening peer through the reference relay. | Those checks need Deno and are not in the recurring list. The channel is cleartext and unauthenticated. |
| `noise-relay` | In-tree tests keep CapTP plaintext off the relay. Recurring checks cover hostname and unknown-CA refusal from every native binding, real local certificate chains, and a Chromium Wasm peer over local WSS. | No outside CapTP peer speaks this profile. Public-certificate and non-Linux evidence remain open. |
| `onion` | Fake-daemon tests drive the blocking resident, provider lifecycle, native completion loop, and every native binding. Live checks cover two pancake peers, both Goblins directions, the portable upstream suite plus the strict abort probe, fresh-process service restoration, and Rooms with two independent clients. | Live Tor checks need Tor and outbound network, so they run on demand. No live scale run is recorded. |
| `webrtc` | Rust sidecar tests cover inbound backpressure, partial writes, oversized-message refusal, retained capacity, runtime teardown, readiness coalescing, and exactly-once terminal publication. | Native DataChannel, browser, and signaling-mesh checks run on demand. `webrtc-loop` and `webrtc-bridge-redeem` exercise Host adoption and three-party redemption and require Cargo. |
| C ABI | Header parity, layouts, ownership, archives, and all binding consumers run in-tree. | There is no independent C consumer; binding interoperability checks still pass through this ABI. |
| Rust, Deno, Python, and Racket bindings | Each binding holds a live Goblins session as a client and in both handoff roles. | Only Deno has a live check in which Goblins dials the binding. |
| TypeScript on Bun | The `bun-dogfood` consumer check covers Host identity and lifetime, locator and sturdyref ABI calls, and fail-closed native-loop admission. | Bun's synchronous FFI cannot host the native driver or blocking transport lifecycles. No Bun-native Goblins check runs. |
| Native Zig driver and actor layer | Session, Host, handoff, turn-loop, hosting, and snapshot tests run under `check`. | These are pancake-native APIs with no outside implementation to compare. |
| Distributed GC | A live Goblins peer sends `op:gc-exports`; in-tree tests cover outbound release and `op:gc-answers`. | No live peer observes pancake's outbound GC or binding finalizers. |
| Relay | Every runtime runs TCP, backpressure, idle-reclaim, and iroh checks. The Deno relay also carries a live Goblins session. | The Goblins interoperability check does not run through the Python, Rust, or Racket relays. |
| CLI and MCP | In-tree command, exit-code, deadline, and listen/call tests run under `check`. | No independent tool drives the CLI as a compatibility test. |
| Browser WebAssembly | JavaScript-to-Wasm handshake and ABI checks run in CI. The recurring `web-peer-test` drives a Chromium Wasm peer and proves native-to-browser Noise rendezvous over local WSS; on demand, `ocapnviz-live-browser` drives the production visualizer bundle as an OCapN peer. | WebRTC and public-certificate WSS scenarios remain on-demand or unsupported as named above. |
| Linux | The full CI sequence runs on Linux. | No claim is made for untested kernel or architecture combinations. |
| macOS | Cross-compilation checks the library and kqueue backend. | Nothing executes on macOS in CI. |
| Windows | Nothing. | Windows and an IOCP completion backend are not implemented. |
| Hostile-input and mutation tests | Bounded malformed-input tests and coverage-guided mutation runs cover codecs, framing, sessions, handoff, locators, the host, actors, and persistent collections. | The recurring fuzz budget is shallow, and most assertions are written by pancake. |

External evidence applies only to the boundary it crosses. A live iroh
endpoint checks the transport stack, not agreement with another CapTP
implementation. A live Goblins session checks protocol interop, not API
stability. The table keeps those claims separate.

[Community review](community-review.md) is the detailed outside-peer matrix.

The evidence is current only when the
[checks workflow](https://github.com/jimisaacs/pancake/actions/workflows/check.yml)
is green for the commit you are evaluating. No row freezes an API or ABI, and
none is a security review.

## Checks run on main pushes and pull requests

This list is compared with [`ci/gates.sh`](../ci/gates.sh) by
`zig build source-check`, so a removed check cannot remain documented as
recurring evidence.

<!-- ci-gate-list:begin -->
- `zig build check`
- `zig build native-tls-build`
- `zig build fuzz`
- `zig build iroh-sidecar-test`
- `zig build webrtc-sidecar-test`
- `zig build bindings-fmt-check`
- `zig build bindings`
- `zig build racket-test`
- `zig build wasm-driver-test`
- `zig build wasm-abi-layout-check`
- `zig build wasm-import-check`
- `zig build web-peer-test`
- `zig build goblins-interop`
- `zig build bindings-goblins-interop`
- `zig build bindings-goblins-handoff`
- `zig build bindings-goblins-gift`
- `zig build goblins-handoff`
- `zig build goblins-gift`
- `zig build goblins-gift-hints`
- `zig build goblins-relayed-give`
- `zig build goblins-exporter`
- `zig build goblins-gc`
- `zig build deno-goblins-listen`
- `zig build goblins-relay`
- `zig build fixture-gen-check`
- `zig build ocapn-findings-check`
- `zig build ocapn-conformance` (upstream modules plus the portable pre-setup
  abort probe; the raw upstream `tests.op_abort` remains diagnostic)
- `zig build iroh-interop`
- `zig build bindings-relay`
- `zig build bindings-native-wss-relay`
- `zig build bindings-relay-iroh`
<!-- ci-gate-list:end -->

Checks that exist but do not appear above are manual. They may be useful
evidence, but a regression can survive until somebody runs them.
