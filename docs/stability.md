# What you can depend on

glowcap has no stable release yet. The table below lists the evidence for each
area and what it leaves open. Some checks run on every main or dev push and
pull request. Others need external runtimes or network access and run on
demand. None is a compatibility or security promise.

For feature coverage, read [what ships](shipped.md). For consequences that may
change a deployment, read [known limitations](boundaries.md).

## Evidence by area

| Area | Evidence | What remains |
| --- | --- | --- |
| Protocol core | The upstream OCapN suite and a live Goblins peer exercise V1.0 model, session, engine, calls, promises, and all three handoff roles. In-tree scenarios exercise the next-profile promise-listen behavior (OCapN PR 282) in `glowcap-next`. | No outside peer exercises the next profile. Community review lists the other exact gaps. |
| Syrup | Fixtures are regenerated with upstream Syrup encoders and compared byte for byte. | None known in the supported message set. |
| Cap'n Proto | In-tree golden frames and cross-codec tests run under `zig build check`. | No outside Cap'n Proto implementation reads glowcap's hand-written format. |
| `tcp` | Live Goblins interoperability runs over glowcap's cleartext TCP adapter. | Goblins ships onion rather than TCP. The channel is cleartext and the peer proves no identity. |
| `iroh` | `iroh-interop`, relay checks, and `iroh-driver-provider` use real iroh endpoints. Python and Rust also dial a real endpoint through an installed iroh provider. The on-demand `goblins-iroh` check reaches a Goblins vat through glowcap's adapter. | Two-NAT hole-punching is not in CI. Goblins ships no iroh netlayer, and `goblins-iroh` requires Cargo and Racket. |
| `keyed-tcp` and `inproc` | In-tree restart, refusal, and end-to-end netlayer tests run under `check`. | No outside peer speaks these transport symbols. `inproc` is test-only. |
| `noise-tcp` | In-tree sealed-channel and netlayer tests run under `check`. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it. | No outside CapTP peer speaks Noise. `BlockingSession` cannot apply the sealed-channel protocol. |
| `keyed-relay` | In-tree netlayer tests run under `check`. The recurring `bindings-keyed-relay-rendezvous` and `zig-keyed-relay-register` checks cold-dial a registered, non-listening peer through the reference relay. | The channel is cleartext and unauthenticated. |
| `noise-relay` | In-tree tests keep CapTP plaintext off the relay. Recurring checks cover hostname and unknown-CA refusal from every native binding, real local certificate chains, and a Chromium Wasm peer over local WSS. | No outside CapTP peer speaks this profile. Public-certificate and non-Linux evidence remain open. |
| `onion` | Fake-daemon tests drive the blocking resident, provider lifecycle, native completion loop, and every native binding. Live checks cover two glowcap peers, both Goblins directions, the portable upstream suite plus the strict abort probe, fresh-process service restoration, and Rooms with two independent clients. | Live Tor checks need Tor and outbound network, so they run on demand. No live scale run is recorded. |
| `webrtc` | Rust library tests cover inbound backpressure, partial writes, oversized-message refusal, retained capacity, runtime teardown, readiness coalescing, and exactly-once terminal publication. The recurring `webrtc-loop` and `webrtc-redeem` checks exercise Host adoption of many DataChannels and three-party redemption. | Native DataChannel browser and signaling-mesh checks run on demand. |
| C ABI | Header parity, layouts, ownership, archives, and all binding consumers run in-tree. `release-pack` also safely extracts its tarball off-tree, then compiles and runs an independent C consumer for each self-contained static archive and one across the packaged shared libraries. | The independent consumers prove packaging, linkage, version, and archive identity. Behavioral interoperability still runs through the bindings rather than an external C implementation. |
| Rooms host package | `glowcap-pack` checks the extracted runtime and skill links, then drives HTTP bootstrap, encrypted iroh, multiple rooms and DMs, observer failure and unread restart without checkout tooling. Damaged-package fixtures run in `check`. | Linux and macOS release runners exercise their own artifacts. This does not prove a particular public deployment's reachability, macOS download approval, or a model harness's continuing wake behavior. |
| Rust, Deno, Python, and Racket bindings | Each binding holds a live Goblins session as a client, accepts one as a listener, and exercises both handoff roles. The listener matrix requires Goblins to enliven and call a Host-wide actor and checks the exact reply. | Bun cannot host the native listener loop. |
| TypeScript on Bun | The `bun-dogfood` consumer check covers Host identity and lifetime, locator and sturdyref ABI calls, and fail-closed native-loop admission. | Bun's synchronous FFI cannot host the native driver or blocking transport lifecycles. No Bun-native Goblins check runs. |
| Native Zig driver and actor layer | Session, Host, handoff, turn-loop, hosting, and snapshot tests run under `check`. | These are glowcap-native APIs with no outside implementation to compare. |
| Loam storage | Record, actor, managed-access and reference-field contracts run under `zig build test`, and `loam-lmdb-test` covers LMDB storage. Process-kill tests interrupt LMDB writes, actor turns, managed changes, collection sweeps and compaction, then verify the store in a fresh process. `loam-abi-test` and `loam-rust-test` prove the C and Rust profile, and `loam-browser-test` drives it under Chromium through IndexedDB. The session codec graph passes cold LMDB reopening under `rooms-rust-test` and Chromium page reload under `rooms-rust-browser-host-test`. Example chapter 07 restarts a store under `check`. | Recovery is tested by killing processes, not by cutting power. The macOS process probes have no recorded successful run. Complete Rooms physical capacity and runtime adoption remain open. |
| Distributed GC | Goblins sends `op:gc-exports` and observes outbound release from Zig and every native binding. A weak reference proves remote reclamation after capability release and answer cleanup while the session stays open. A second held occurrence remains callable after the first release. | Automatic capability finalizers have in-tree evidence. The live binding checks finalize answer wrappers and release capability handles explicitly. |
| Relay | Every runtime runs TCP, backpressure, idle-reclaim, and iroh checks. The Deno relay also carries a live Goblins session. | The Goblins interoperability check does not run through the Python, Rust, or Racket relays. |
| Rooms | The recurring `goblins-rooms` scenario puts a real Goblins vat and a glowcap member in one room and proves their independently settled wire profiles. The recurring `demo-rooms` tour puts every one-shot client (Deno, Python, Racket, Rust, and Zig) in one room. `goblins-rooms-irc` composes that outside implementation with both shipped IRC edges. `rooms-web-proofs` runs every shipped-page journey in Chromium, including direct messages, durable and shared sessions, private rooms, routing, management, reconnect, archive, and trace lifecycles. In-tree checks cover room authority, operator revocation, the bounded browser state bundle, archives, and a durable session peer with two attached OCapN clients, room events, interaction, revocation, restart, and unresolved-effect custody. | The four-peer iroh matrix runs on demand because it needs iroh and a live Goblins vat. |
| CLI and MCP | In-tree command, exit-code, deadline, and listen/call tests run under `check`. | No independent tool drives the CLI as a compatibility test. |
| Browser WebAssembly | JavaScript-to-Wasm handshake and ABI checks run in CI. The recurring `web-peer-test` drives a Chromium Wasm peer and proves native-to-browser Noise rendezvous over local WSS. On demand, `ocapnviz-live-browser` drives the production visualizer bundle as an OCapN peer. | WebRTC and public-certificate WSS scenarios remain on-demand or unsupported as named above. |
| Linux | The full CI sequence runs on Linux. TCP completion loops exercise io_uring when the host provides its required facilities and otherwise exercise the epoll fallback. Selection and its reasons are tested separately. | The recorded 500,000-session result used io_uring. No equivalent epoll scale result or claim exists. |
| macOS | The macOS CI job runs `zig build test loam-lmdb-test` and is configured to run the record, actor, managed, tracing and compaction process-loss probes alongside those suites. | No successful macOS run of the process probes is recorded. `zig build check` and the external-runtime matrix remain Linux-only. |
| Windows | Nothing. | Windows and an IOCP completion backend are not implemented. |
| Untrusted-input and mutation tests | Bounded malformed-input tests and coverage-guided mutation runs cover codecs, framing, sessions, handoff, locators, the host, actors, and persistent collections. | The recurring fuzz budget is shallow, and most assertions are written by glowcap. |

External evidence applies only to the boundary it crosses. A live iroh
endpoint checks the transport stack, not agreement with another CapTP
implementation. A live Goblins session checks protocol interop, not API
stability.

[Community review](community-review.md) is the detailed outside-peer matrix.

The evidence is current only when the
[checks workflow](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml)
is green for the commit you are evaluating. No row freezes an API or ABI, and
none is a security review.

## Checks run on main and dev pushes and pull requests

`zig build source-check` keeps this list equal to [`ci/gates.sh`](../ci/gates.sh).
`infrastructure-check` tests the devcontainer and worktree tools. `check` runs
self-contained Zig tests and static, generated, compile, and performance
evidence. `runtime-check` runs process, socket, application, and
language-workspace checks. Each Zig test has a 30-second timeout.

<!-- ci-gate-list:begin -->
- `zig build infrastructure-check`
- `zig build check`
- `zig build runtime-check`
- `zig build native-tls-build`
- `zig build fuzz`
- `zig build sidecar-common-test`
- `zig build iroh-sidecar-test`
- `zig build webrtc-sidecar-test`
- `zig build webrtc-loop`
- `zig build webrtc-redeem`
- `zig build bindings-fmt-check`
- `zig build bindings`
- `zig build bindings-noise-relay-listen`
- `zig build bindings-verb-spine`
- `zig build bindings-keyed-tcp-restart`
- `zig build bindings-keyed-relay-rendezvous`
- `zig build zig-keyed-relay-register`
- `zig build bindings-iroh-handoff`
- `zig build bindings-iroh-redeem-posture`
- `zig build racket-test`
- `zig build wasm-driver-test`
- `zig build wasm-abi-layout-check`
- `zig build wasm-import-check`
- `zig build web-peer-test`
- `zig build loam-browser-test`
- `zig build rooms-rust-browser-test`
- `zig build rooms-web-proofs`
- `zig build goblins-interop`
- `zig build goblins-rooms`
- `zig build demo-rooms`
- `zig build goblins-rooms-irc`
- `zig build bindings-goblins-interop`
- `zig build bindings-goblins-handoff`
- `zig build bindings-goblins-gift`
- `zig build goblins-handoff`
- `zig build goblins-handoff-iroh`
- `zig build goblins-gift`
- `zig build goblins-gift-hints`
- `zig build goblins-relayed-give`
- `zig build goblins-listen-recipient`
- `zig build goblins-exporter`
- `zig build goblins-gc`
- `zig build bindings-goblins-listen`
- `zig build goblins-relay`
- `zig build fixture-gen-check`
- `zig build ocapn-findings-check`
- `zig build ocapn-conformance` (upstream modules plus the portable pre-setup
  abort probe, the raw upstream `tests.op_abort` remains diagnostic)
- `zig build iroh-interop`
- `zig build iroh-driver-provider`
- `zig build python-iroh-driver-provider`
- `zig build rust-iroh-driver-provider`
- `zig build bindings-relay`
- `zig build bindings-native-wss-relay`
- `zig build bindings-relay-iroh`
<!-- ci-gate-list:end -->

Checks that exist but do not appear above are manual. They may be useful
evidence, but a regression can survive until somebody runs them.
