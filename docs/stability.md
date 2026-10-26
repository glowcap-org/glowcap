---
type: living
description: The checks behind each area of glowcap and what they leave open.
sources: []
---

# What you can depend on

glowcap has no stable release yet. Some checks run on every main or dev push.
Others need external runtimes or network access and run on demand. None is a
compatibility or security promise.

For feature coverage, read [what ships](shipped.md). For consequences that may
change a deployment, read [known limitations](boundaries.md).

## Checks by area

| Area | Evidence | What remains |
| --- | --- | --- |
| Protocol core | The upstream OCapN suite and live Goblins peers exercise the V1.0 model, session, engine, calls, promises, and all three handoff roles. [Community review](community-review.md) lists each check. The next conformance lane adapts upstream assertions to the merged operation shapes and adds draft wire cases with the retained hello. | No independent production peer exercises the next profile. The crypto transition remains deferred. Community review lists the other exact gaps. |
| Syrup | Fixtures are regenerated with upstream Syrup encoders and compared byte for byte. | None known in the supported message set. |
| Cap'n Proto | In-tree golden frames and cross-codec tests run under `zig build check`. | No check uses an outside Cap'n Proto implementation to validate the wire format. |
| `tcp` | Live Goblins interoperability runs over glowcap's cleartext TCP adapter. | Goblins ships onion rather than TCP. The channel is cleartext and the peer proves no identity. |
| `iroh` | `iroh-interop`, relay checks, and `iroh-driver-provider` use real iroh endpoints. Python and Rust also dial a real endpoint through an installed iroh provider. The on-demand `goblins-iroh` check reaches a Goblins vat through glowcap's adapter. | Two-NAT hole-punching is not in CI. Goblins ships no iroh netlayer, and `goblins-iroh` requires Cargo and Racket. |
| `keyed-tcp` and `inproc` | In-tree restart, refusal, and end-to-end netlayer tests run under `check`. | No outside peer speaks these transport symbols. `inproc` is test-only. |
| `noise-tcp` | In-tree sealed-channel and netlayer tests run under `check`. `driver.Session` and `Server`, the C driver loop, and all four bindings dial and listen on it. | Interoperability with another CapTP implementation is untested. |
| `keyed-relay` | In-tree netlayer tests run under `check`. The recurring `bindings-keyed-relay-rendezvous` and `zig-keyed-relay-register` checks cold-dial a registered, non-listening peer through the reference relay. | The channel is cleartext and unauthenticated. |
| `noise-relay` | In-tree tests keep CapTP plaintext off the relay. Recurring checks cover hostname and unknown-CA refusal from every binding, real local certificate chains, and a Chromium Wasm peer over local WSS. | Interoperability with another CapTP implementation is untested. Public-certificate and non-Linux checks remain open. |
| `onion` | Fake-daemon tests drive the blocking resident, provider lifecycle, completion adapter, and every binding. Live checks cover two glowcap peers, both Goblins directions, the portable upstream suite plus the strict abort probe, fresh-process service restoration, and Rooms with two independent clients. | Live Tor checks need Tor and outbound network, so they run on demand. No live scale run is recorded. |
| `webrtc` | Rust library tests cover inbound backpressure, partial writes, oversized-message refusal, retained capacity, runtime teardown, readiness coalescing, and exactly-once terminal publication. The recurring `webrtc-loop` and `webrtc-redeem` checks exercise Host adoption of many DataChannels and three-party redemption. | Browser and signaling-mesh checks for the Rust WebRTC DataChannel run on demand. |
| C ABI | Header parity, layouts, ownership, archives, and all binding consumers run in-tree. `release-pack` also safely extracts its tarball off-tree, then compiles and runs an independent C consumer for each self-contained static archive and one across the packaged shared libraries. These test programs are maintained in this repository. | These consumers check packaging, linkage, version, and archive identity. Behavioral interoperability still runs through the bindings rather than an external C implementation. |
| Rooms host package | `glowcap-pack` checks the extracted runtime and skill links, then drives HTTP bootstrap, encrypted iroh, multiple rooms and DMs, observer failure and unread restart without checkout tooling. Damaged-package fixtures run in `check`. | Linux and macOS release runners exercise their own artifacts. This does not prove a particular public deployment's reachability, macOS download approval, or a model harness's continuing wake behavior. |
| Rust, Deno, Python, and Racket bindings | Each binding holds live Goblins sessions in both directions and takes both handoff roles, as community review details. | Bun cannot host the driver loop. |
| TypeScript on Bun | The `bun-dogfood` consumer check covers Host identity and lifetime, locator and sturdyref ABI calls, and that Bun refuses driver listeners before allocating a loop. | Bun's synchronous FFI cannot host the C driver or blocking transport lifecycles. No Goblins check runs on Bun. |
| Zig driver and actor layer | Session, Host, handoff, turn-loop, hosting, and snapshot tests run under `check`. | These are glowcap's own APIs with no outside implementation to compare. |
| Loam storage | Shared storage scenarios run on SQLite and LMDB. Crash and I/O-fault probes check recovery, and C, Rust, and browser tests exercise the foreign interfaces. [Storage failure coverage](#storage-failure-coverage) details their scope. | Power loss and arbitrary corruption are untested. macOS process probes and some managed-access failure cases lack evidence, as detailed below. |
| Distributed GC | Live Goblins checks prove release in both directions from Zig and every binding, as community review details. | Automatic capability finalizers have in-tree checks. The live binding checks finalize answer wrappers and release capability handles explicitly. |
| Relay | Every runtime runs TCP, backpressure, idle-reclaim, and iroh checks. The Deno relay also carries a live Goblins session. | The Goblins interoperability check does not run through the Python, Rust, or Racket relays. |
| Rooms | `goblins-rooms` and `goblins-rooms-irc` put a real Goblins vat in a room, as community review details. The recurring `demo-rooms` tour puts every one-shot client in one room. `rooms-web-proofs` runs every shipped-page journey in Chromium, including direct messages, durable and shared sessions, private rooms, routing, management, reconnect, archive, and trace lifecycles. In-tree checks cover room authority, operator revocation, the bounded browser state bundle, archives, and a durable session peer with two attached OCapN clients, room events, interaction, revocation, restart, and effects whose outcome is unknown. | The four-peer iroh matrix runs on demand because it needs iroh and a live Goblins vat. |
| CLI and MCP | In-tree command, exit-code, deadline, and listen/call tests run under `check`. | No independent tool drives the CLI as a compatibility test. |
| Browser WebAssembly | JavaScript-to-Wasm handshake and ABI checks run in CI. The recurring `web-peer-test` drives a Chromium Wasm peer and proves Zig-peer-to-browser Noise rendezvous over local WSS. On demand, `ocapnviz-live-browser` drives the production visualizer bundle as an OCapN peer. | WebRTC and public-certificate WSS scenarios remain on-demand or unsupported as named above. |
| Linux | The full CI sequence runs on Linux. TCP completion loops exercise io_uring when the host provides its required facilities and otherwise exercise the epoll fallback. Selection and its reasons are tested separately. | The recorded 500,000-session result used io_uring. No equivalent epoll scale result or claim exists. |
| macOS | The macOS CI job runs `infrastructure-check`, then `zig build test loam-lmdb-test loam-sqlite-test` and the `loam-*-crash-test` process-loss probes. | No successful macOS run of the process probes is recorded. `zig build check` and the external-runtime matrix remain Linux-only. |
| Windows | Nothing. | Windows and an IOCP completion backend are not implemented. |
| Untrusted-input and mutation tests | Bounded malformed-input tests and coverage-guided mutation runs cover codecs, framing, the Noise handshake and sealed channel, sessions, handoff, locators, the host, actors, and persistent collections. The protocol core and actors tests also run under valgrind, and the whole suite runs in ReleaseSafe. | The per-push fuzz budget is shallow and the nightly search is one machine for a few hours, and most assertions are written by glowcap. |

An outside check covers only the boundary it crosses. A live iroh endpoint
tests the transport stack and says nothing about agreeing with another CapTP
implementation. A live Goblins session tests protocol interop and says nothing
about API stability.

These results hold only when the
[checks workflow](https://github.com/glowcap-org/glowcap/actions/workflows/check.yml)
is green for the commit you are evaluating.

## Storage failure coverage

Loam's process-kill probes interrupt writes, actor turns, managed changes,
collection and compaction, then reopen the store in a fresh process. Linux
I/O-fault probes inject failed and short reads and writes, failed syncs, and
truncated data files. They check atomic records, commit outcomes, and reads
whose backing file changes while the caller still holds a value.

These tests do not cover power loss, reordered writes, faults in the engines'
mapped coordination files, or arbitrary damaged pages. Read tests empty
Loam's record cache, not the OS file cache. No successful macOS process-probe
run is recorded. Managed access also lacks tests for a panic during commit
and owner retirement while unrelated actors run.

The [C/Rust guide](loam/c-and-rust.md#tests) owns foreign-interface test
coverage, including the browser. Rooms additionally checks cold session
graph reopening on both disk engines and page reload under Chromium.
The [roadmap](roadmap.md) tracks work to extend this evidence.

## Which checks recur

[`ci/gates.sh`](../ci/gates.sh) owns the full validation sequence.
The [CI guide](../CONTRIBUTING.md#continuous-integration) explains when the
workflow runs the full sequence and how development runs select checks by
changed files. A successful development run covers only its selected jobs.
A check outside the full sequence is manual. It may still be useful, but a
regression can survive until somebody runs it.
