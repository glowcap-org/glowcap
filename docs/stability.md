# What you can depend on

glowcap has no stable release yet. The table below records the evidence
available for each area, whether it crosses into code maintained outside this
repository, and what it leaves open. Some checks run on every main or dev push
and pull request; others need external runtimes or network access and run on
demand. None is a compatibility or security promise.

For feature coverage, read [what ships](shipped.md). For consequences that may
change a deployment, read [known limitations](boundaries.md).

## Evidence by area

| Area | Evidence | What remains |
| --- | --- | --- |
| Protocol core | The upstream OCapN suite and a live Goblins peer exercise V1.0 model, session, engine, calls, promises, and all three handoff roles. In-tree scenarios exercise the next-profile promise-listen behavior (OCapN PR 282) in `glowcap-next`. | No outside peer exercises the next profile; community review lists the other exact gaps. |
| Syrup | Fixtures are regenerated with upstream Syrup encoders and compared byte for byte. | None known in the supported message set. |
| Cap'n Proto | In-tree golden frames and cross-codec tests run under `zig build check`. | No outside Cap'n Proto implementation reads glowcap's hand-written format. |
| `tcp` | Live Goblins interoperability runs over glowcap's cleartext TCP adapter. The upstream OCapN suite uses its own `tcp-testing-only` transport. | Goblins ships onion rather than TCP. The channel is cleartext and the peer proves no identity. |
| `iroh` | `iroh-interop` and relay checks use real iroh endpoints and its QUIC stack. The recurring `iroh-driver-provider` proof and its Python and Rust siblings install an iroh provider package into each native runtime's driver loop and dial a real endpoint through it. The on-demand `goblins-iroh` check reaches a Goblins vat through glowcap's adapter. | Two-NAT hole-punching is not in CI. Goblins ships no iroh netlayer, and `goblins-iroh` requires Cargo and Racket. |
| `keyed-tcp` and `inproc` | In-tree restart, refusal, and end-to-end netlayer tests run under `check`. | No outside peer speaks these transport symbols; `inproc` is test-only. |
| `noise-tcp` | In-tree sealed-channel and netlayer tests run under `check`. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it. | No outside CapTP peer speaks Noise; this is glowcap-to-glowcap. `BlockingSession` cannot apply the sealed-channel protocol. |
| `keyed-relay` | In-tree netlayer tests run under `check`. The recurring `bindings-keyed-relay-rendezvous` check cold-dials a registered, non-listening peer through the reference relay. | `zig-keyed-relay-register` is still on demand. The channel is cleartext and unauthenticated. |
| `noise-relay` | In-tree tests keep CapTP plaintext off the relay. Recurring checks cover hostname and unknown-CA refusal from every native binding, real local certificate chains, and a Chromium Wasm peer over local WSS. | No outside CapTP peer speaks this profile. Public-certificate and non-Linux evidence remain open. |
| `onion` | Fake-daemon tests drive the blocking resident, provider lifecycle, native completion loop, and every native binding. Live checks cover two glowcap peers, both Goblins directions, the portable upstream suite plus the strict abort probe, fresh-process service restoration, and Rooms with two independent clients. | Live Tor checks need Tor and outbound network, so they run on demand. No live scale run is recorded. |
| `webrtc` | Rust sidecar tests cover inbound backpressure, partial writes, oversized-message refusal, retained capacity, runtime teardown, readiness coalescing, and exactly-once terminal publication. | Native DataChannel, browser, and signaling-mesh checks run on demand. `webrtc-loop` and `webrtc-bridge-redeem` exercise Host adoption and three-party redemption and require Cargo. |
| C ABI | Header parity, layouts, ownership, archives, and all binding consumers run in-tree. `release-pack` also safely extracts its tarball off-tree, then compiles and runs an independent C consumer for each self-contained static archive and one across the packaged shared libraries. | The independent consumers prove packaging, linkage, version, and archive identity; behavioral interoperability still runs through the bindings rather than an external C implementation. |
| Rooms host package | `glowcap-pack` checks the extracted runtime and skill links, then drives HTTP bootstrap, encrypted iroh, multiple rooms and DMs, observer failure and unread restart without checkout tooling. Damaged-package fixtures run in `check`. | Linux and macOS release runners exercise their own artifacts. This does not prove a particular public deployment's reachability, macOS download approval, or a model harness's continuing wake behavior. |
| Rust, Deno, Python, and Racket bindings | Each binding holds a live Goblins session as a client, accepts one as a listener, and exercises both handoff roles. The listener matrix requires Goblins to enliven and call a Host-wide actor and checks the exact reply. | Bun cannot host the native listener loop. |
| TypeScript on Bun | The `bun-dogfood` consumer check covers Host identity and lifetime, locator and sturdyref ABI calls, and fail-closed native-loop admission. | Bun's synchronous FFI cannot host the native driver or blocking transport lifecycles. No Bun-native Goblins check runs. |
| Native Zig driver and actor layer | Session, Host, handoff, turn-loop, hosting, and snapshot tests run under `check`. | These are glowcap-native APIs with no outside implementation to compare. |
| Distributed GC | Goblins sends `op:gc-exports` and observes outbound release from Zig and every native binding. A weak reference proves remote reclamation after capability release and answer cleanup while the session stays open; a second held occurrence remains callable after the first release. | Automatic capability finalizers have in-tree evidence; the live binding checks finalize answer wrappers and release capability handles explicitly. |
| Relay | Every runtime runs TCP, backpressure, idle-reclaim, and iroh checks. The Deno relay also carries a live Goblins session. | The Goblins interoperability check does not run through the Python, Rust, or Racket relays. |
| Rooms | The recurring `goblins-rooms` scenario puts a real Goblins vat and a glowcap member in one room and proves their independently settled wire profiles. The recurring `demo-rooms` tour puts every one-shot client (Deno, Python, Racket, Rust, and Zig) in one room, so no client can drift from the room contract unseen. `goblins-rooms-irc` composes that outside implementation with both shipped IRC edges. `rooms-web-proofs` runs every shipped-page journey in Chromium, including direct messages, durable and shared sessions, private rooms, routing, management, reconnect, archive, and trace lifecycles. In-tree checks cover room authority, operator revocation, the bounded browser state bundle, archives, and a durable session peer with two attached OCapN clients, room events, interaction, revocation, restart, and unresolved-effect custody. | The four-peer iroh matrix remains on demand because it requires the iroh sidecar and a live Goblins vat. |
| CLI and MCP | In-tree command, exit-code, deadline, and listen/call tests run under `check`. | No independent tool drives the CLI as a compatibility test. |
| Browser WebAssembly | JavaScript-to-Wasm handshake and ABI checks run in CI. The recurring `web-peer-test` drives a Chromium Wasm peer and proves native-to-browser Noise rendezvous over local WSS; on demand, `ocapnviz-live-browser` drives the production visualizer bundle as an OCapN peer. | WebRTC and public-certificate WSS scenarios remain on-demand or unsupported as named above. |
| Linux | The full CI sequence runs on Linux. TCP completion loops exercise io_uring when the host provides its required facilities and otherwise exercise the epoll fallback. Selection and its reasons are tested separately. | The recorded 500,000-session result used io_uring. No equivalent epoll scale result or claim exists. |
| macOS | The macOS CI job runs `zig build test loam-lmdb-test`, covering the host-selected kqueue path and optional native storage adapter. | `zig build check` and the external-runtime matrix remain Linux-only. A Linux cross-compile does not establish macOS runtime behavior. |
| Windows | Nothing. | Windows and an IOCP completion backend are not implemented. |
| Untrusted-input and mutation tests | Bounded malformed-input tests and coverage-guided mutation runs cover codecs, framing, sessions, handoff, locators, the host, actors, and persistent collections. | The recurring fuzz budget is shallow, and most assertions are written by glowcap. |

External evidence applies only to the boundary it crosses. A live iroh
endpoint checks the transport stack, not agreement with another CapTP
implementation. A live Goblins session checks protocol interop, not API
stability. The table keeps those claims separate.

[Community review](community-review.md) is the detailed outside-peer matrix.

The evidence is current only when the
[checks workflow](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml)
is green for the commit you are evaluating. No row freezes an API or ABI, and
none is a security review.

## Checks run on main and dev pushes and pull requests

This list is compared with [`ci/gates.sh`](../ci/gates.sh) by
`zig build source-check`, so a removed check cannot remain documented as
recurring evidence.

The first three entries divide local evidence by execution cost.
`infrastructure-check` black-boxes the devcontainer and worktree tools in
temporary repositories. `check` runs self-contained Zig tests, generated,
static, compile-only, and performance evidence. `runtime-check` runs process,
socket, application, and language-workspace checks. Its side-effecting commands
take the build runner's execution lock, so shared ports and output directories
cannot overlap. Zig's 30-second timeout applies to each active test. Non-Zig
process tests retain their own process-group deadlines, and CI adds a much
wider outer deadline only to contain a wedged gate.

<!-- ci-gate-list:begin -->
- `zig build infrastructure-check`
- `zig build check`
- `zig build runtime-check`
- `zig build native-tls-build`
- `zig build fuzz`
- `zig build sidecar-common-test`
- `zig build iroh-sidecar-test`
- `zig build webrtc-sidecar-test`
- `zig build bindings-fmt-check`
- `zig build bindings`
- `zig build bindings-noise-relay-listen`
- `zig build bindings-verb-spine`
- `zig build bindings-keyed-tcp-restart`
- `zig build bindings-keyed-relay-rendezvous`
- `zig build bindings-iroh-handoff`
- `zig build bindings-iroh-redeem-posture`
- `zig build racket-test`
- `zig build wasm-driver-test`
- `zig build wasm-abi-layout-check`
- `zig build wasm-import-check`
- `zig build web-peer-test`
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
  abort probe; the raw upstream `tests.op_abort` remains diagnostic)
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
