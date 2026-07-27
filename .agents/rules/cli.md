---
description: "Zig pancake execution model, gates, generated state, and git posture."
alwaysApply: true
---

# pancake — Execution Model

## Gates

Run before calling code work complete:

```sh
zig build check
```

A gate passes by its exit code, not by its output: piping through `tail` or
`grep` reports the pipe's status and turns a failing build into a false green.
Run `zig build` from the repository root: run from a subdirectory it drops
`zig-out/` and `.zig-cache/` debris where it stands and resolves relative
manifest paths wrong. Test runs are exclusive: the suite and the interop steps
bind real loopback ports, so two concurrent runs — a second agent, an editor's
build-on-save, a stale run a crashed session left behind — wedge each other's
test binaries in silent socket waits that look like hangs. Before diagnosing a
"hung" gate, sweep for orphaned `.zig-cache/o/*/test` processes from a dead
session and run the gate alone. A `check` that fails compiling executables
which build fine alone is the same contention wearing a different face — a
live rival builder (another agent session, a `--watch` runner) racing the
cache; find it with `ps aux | grep 'zig build'` before touching code. The
test-step variant: a step fails with no printed assertion while its binary
passes standalone and the failing binary's cache hash changes on every retry.
Only an *actively compiling* rival collides — a parked `--watch` runner at 0%
CPU is innocent — so check for live compiles and link stragglers, wait them
out, and re-run before suspecting the change. When
iterating on CapTP/socket CLI tests, wrap
with `timeout N` (tens of seconds) instead of waiting forever — a silent hang
is almost always an unbounded wait (`handshake_timeout_ms` / `settle_timeout_ms`
defaulting to 0), not a slow test.

A *failed* `ocapn-conformance` run can leave its pancake peer behind on the
fixed port, and the next run inherits it: the symptom is one unrelated
`ConnectionResetError` where the suite expected a timeout. Re-run alone before
believing a conformance failure that names a test your change does not touch.

`zig build check` needs no network and no submodules, so it is the step to run
while iterating. One member, `c-abi-extract-check`, shells out to `bash` and
`tar` and skips the language ports it cannot find. The cost is that a green `check` proves only
that pancake agrees with pancake. `zig build check-external` is the other half:
every check whose authority is outside pancake, listed with its members in the
step table below. Run it before believing a protocol claim; `ci/gates.sh`
runs the same set on every push to the mirror.

`zig build check` runs the Zig-hermetic gate: architecture checks, meta
scaffolding checks, Zig formatting (`zig fmt --check`), correctness tests,
public examples, protocol/Goblins oracle checks, the accountability application
and its three-party attribution test, benchmark smoke checks, and the
ReleaseFast wall-clock tripwire (`perf-check`). Cross-language
C ABI dogfood, the live Goblins interop, and the Rust/TypeScript formatting check
run as sibling steps because they require non-Zig runtimes on PATH. Indentation
policy lives in `.editorconfig` (tabs displayed four wide, with space overrides
for the languages whose formatter or grammar forbids tabs), `rustfmt.toml`, and
the `deno.json` `fmt` blocks; Python and Racket are governed by `.editorconfig`
alone. Use focused steps while iterating:

```sh
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build arch-check
zig build meta-check
zig build pancake            # run the CapTP CLI; pass `-- <command> …`
zig build cli-test           # hermetic pancake CLI goldens (incl. CapTP deadline hang-proof)
zig build cli                # alias of `zig build cli-test`
zig build perf-check           # gate ReleaseFast wall-clock cost: warm dispatch + outbound send vs docs/ladder.md step 2 ceilings, plus the gc-storm linearity ratio; part of check
zig build fuzz               # mutation-fuzz every hostile-input target, one fuzzer run each; -Dfuzz-runs sets how long each one searches (default 500K)
zig build fuzz-run           # the fuzz worker `zig build fuzz` drives; add --fuzz yourself for Zig's coverage UI
zig build fmt                # format Zig sources in place (zig fmt)
zig build fmt-check          # check Zig formatting (zig fmt --check), part of check
zig build timeout-runner-test # black-box the CI deadline wrapper and the gate sequence's own classification of its codes: exit codes, relayed signal, no survivors; runs before any gate relies on its deadline; not in check (needs python3)
zig build bindings-fmt       # format the Rust crates + TypeScript bindings in place (needs cargo + deno)
zig build bindings-fmt-check # check Rust and TypeScript formatting, the lint rules and type-check for both TypeScript scopes (the bindings workspace, and the root scope covering apps/, interop/, transports/, bench/, and tools/), and ruff plus mypy over the Python binding (needs cargo + deno + uv)
zig build docs              # generate the Zig API reference (autodoc) under zig-out/docs/
zig build site              # build the documentation site (Zine + autodoc) under zig-out/site/
zig build docs-serve        # serve the documentation site locally at http://127.0.0.1:1990/pancake/
zig build oracle-check
zig build check-external     # core external protocol baseline: upstream OCapN suite, pinned-source findings, native Goblins both directions and handoff roles, upstream-Syrup corpus parity (needs uv + racket + goblins)
zig build cross-check        # compile-only: full library for macOS (kqueue) + sans-io core for wasm32 + the browser-binding wasm Host, part of check
zig build wasm-driver        # build the browser binding's freestanding wasm32 Host module (ADR-0070) into zig-out/wasm/ (also folded into cross-check)
zig build wasm-driver-test   # prove the wasm32 Host holds a real keyed CapTP handshake from JS over an in-memory pipe (needs deno)
zig build wasm-abi-layout-check # prove the wasm32 Host's layout descriptor (pancake_wasm_abi_layout) decodes cleanly and agrees with the abi.ts field counts (needs deno)
zig build wasm-import-check   # prove the wasm32 Host's import set is exactly {env.pancake_behavior_trampoline}, the sole behavior-dispatch seam (needs deno)
zig build web-peer-test       # prove the @pancake/web browser peer holds a keyed OCapN session over WebSocket against a native host (needs deno; ADR-0070 Milestone 1)
zig build bindings-relay # the cross-runtime relay matrix (ADR-0086): TCP forwarding + the non-optional backpressure clause + the idle-timeout bounded-resources clause, run against every runtime's relay through one shared harness — Deno reference relay, Python relay, Rust relay, Racket relay (needs deno + uv + cargo + racket)
zig build bindings-relay-iroh # the relay matrix's iroh leg: a browser peer holds a live iroh session through each runtime's relay, dialing a real iroh endpoint over QUIC (needs deno + uv + cargo + racket)
zig build deno-relay-test # one row: a browser peer holds a keyed session through the Deno reference relay bindings/ts/relay/serve.ts (needs deno)
zig build python-relay-test # one row: a browser peer holds a keyed session through the Python relay (needs deno + uv)
zig build rust-relay-test # one row: a browser peer holds a keyed session through the Rust relay (tokio-tungstenite; needs deno + cargo)
zig build racket-relay-test # one row: a browser peer holds a keyed session through the Racket relay (net/rfc6455; needs deno + racket)
zig build deno-relay-backpressure-test # one row: a stalled reader backpressures the far sender through the Deno relay (needs deno)
zig build python-relay-backpressure-test # one row: a stalled reader backpressures the far sender through the Python relay (needs deno + uv)
zig build rust-relay-backpressure-test # one row: a stalled reader backpressures the far sender through the Rust relay (needs deno + cargo)
zig build racket-relay-backpressure-test # one row: a stalled reader backpressures the far sender through the Racket relay (needs deno + racket)
zig build deno-relay-idle-test # one row: the Deno relay reclaims a silent idle session, ADR-0086's bounded-resources clause (needs deno)
zig build python-relay-idle-test # one row: the Python relay reclaims a silent idle session (needs deno + uv)
zig build rust-relay-idle-test # one row: the Rust relay reclaims a silent idle session (needs deno + cargo)
zig build racket-relay-idle-test # one row: the Racket relay reclaims a silent idle session (needs deno + racket)
zig build deno-relay-iroh-test # one row: a browser peer holds a live iroh session through the Deno relay's iroh leg (needs deno + cargo)
zig build python-relay-iroh-test # one row: a browser peer holds a live iroh session through the Python relay, dialing iroh via the Python binding's dial_locator_for_relay (needs deno + uv + cargo)
zig build rust-relay-iroh-test # one row: a browser peer holds a live iroh session through the Rust relay, dialing iroh via the binding's IrohNetlayer::connect_owned behind an opt-in iroh feature (needs deno + cargo)
zig build racket-relay-iroh-test # one row: a browser peer holds a live iroh session through the Racket relay, dialing iroh via the binding's dial-locator-for-relay (needs deno + cargo + racket)
zig build rust-dogfood      # Rust C ABI dogfood against the pancake archives (needs cargo)
zig build deno-dogfood      # Deno C ABI dogfood against the pancake archives (needs deno)
zig build bun-dogfood       # Bun C ABI dogfood against the pancake archives, same multi-runtime JS binding as Deno (needs bun)
zig build python-dogfood    # Python C ABI dogfood against the pancake archives (needs python3)
zig build racket-dogfood    # Racket C ABI dogfood against the pancake archives (needs racket)
zig build racket-test       # Racket unit tests, run file by file since the image has no `raco test` (needs racket)
zig build bindings          # all five dogfoods together
zig build deno-gifter-handoff  # pancake-only 3-node three-party handoff: a broker introduces a recipient to an exporter, then the recipient messages it directly (needs deno)
zig build goblins-interop   # live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins)
zig build deno-goblins-interop   # live keyed conversation: Deno binding vs a real Goblins vat over the C ABI (needs deno + racket + goblins)
zig build deno-goblins-listen    # live keyed listen: Deno binding Host/listen publishes and a real Goblins vat dials it (needs deno + racket + goblins)
zig build python-goblins-interop # live keyed conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins)
zig build rust-goblins-interop   # live keyed conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins)
zig build racket-goblins-interop # live keyed conversation: Racket binding vs a real Goblins vat (needs racket + goblins)
zig build bindings-goblins-interop # per-binding live keyed conversation vs a real Goblins vat, every binding (needs racket + goblins + the runtimes)
zig build goblins-handoff   # live three-party handoff vs Goblins, pancake as recipient (needs racket + goblins)
zig build goblins-gift      # live three-party handoff vs Goblins, pancake as gifter (needs racket + goblins)
zig build goblins-gc        # live Goblins GC evidence: inbound op:gc-exports after echo consumes a near export (needs racket + goblins)
zig build deno-goblins-handoff # live three-party handoff: the Deno binding redeems a give from a real Goblins introducer and calls the exporter (needs deno + racket + goblins)
zig build python-goblins-handoff # live three-party handoff: the Python binding redeems a give from a real Goblins introducer and calls the exporter (needs python3 + racket + goblins)
zig build rust-goblins-handoff # live three-party handoff: the Rust binding redeems a give from a real Goblins introducer and calls the exporter (needs cargo + racket + goblins)
zig build racket-goblins-handoff # live three-party handoff: the Racket binding redeems a give from a real Goblins introducer and calls the exporter (needs racket + goblins)
zig build bindings-goblins-handoff # per-binding three-party handoff: binding as recipient (redeems a Goblins give), every binding (needs racket + goblins + the runtimes)
zig build deno-goblins-gift # live three-party handoff: the Deno binding mints a give a real Goblins recipient redeems, reaching the exporter (needs deno + racket + goblins)
zig build python-goblins-gift # live three-party handoff: the Python binding mints a give a real Goblins recipient redeems, reaching the exporter (needs python3 + racket + goblins)
zig build rust-goblins-gift # live three-party handoff: the Rust binding mints a give a real Goblins recipient redeems, reaching the exporter (needs cargo + racket + goblins)
zig build racket-goblins-gift # live three-party handoff: the Racket binding mints a give a real Goblins recipient redeems, reaching the exporter (needs racket + goblins)
zig build bindings-goblins-gift # per-binding three-party handoff: binding as gifter (Goblins recipient redeems), every binding (needs racket + goblins + the runtimes)
zig build iroh-lib          # build the iroh netlayer sidecar staticlib in transports/iroh (needs cargo)
zig build iroh-sidecar-test # run the iroh sidecar Rust unit tests, including the connect-timeout positive-fire proof against a bound-but-silent UDP black hole (needs cargo)
zig build webrtc-lib        # build the WebRTC DataChannel netlayer sidecar staticlib and phase-1 probe binary in transports/webrtc (ADR-0089; needs cargo)
zig build webrtc-sidecar-test # run the WebRTC sidecar Rust unit tests, including the inbound backpressure proof: a far peer that outruns the reader waits for room instead of growing the buffer (needs cargo)
zig build webrtc-datachannel-test # prove a headless Chromium RTCDataChannel carries bytes both directions to a native webrtc-crate peer on loopback (ADR-0089 phase 1, signaling out-of-band over stdio; needs cargo + deno + a Playwright Chromium)
zig build webrtc-resident-check # type-check the WebRTC DataChannel netlayer resident src/net/transport/webrtc.zig (ADR-0089 phase 2), compile-only, no cargo; also rides check
zig build webrtc-interop     # live WebRTC: two native pancake peers hold a keyed OCapN session over a real DataChannel, signaling ferried in-process (ADR-0089 phase 2; needs cargo)
zig build webrtc-mesh      # live WebRTC signaling mesh: two native peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (ADR-0089 phase 5; needs cargo)
zig build webrtc-signaling-captp # live WebRTC signaling capability over CapTP: the exporter hosts a signaling inbox behind a keyed session, the recipient drives offer/answer/candidate over it to open a DataChannel, then holds a keyed session over it (ADR-0089 phase 5; needs cargo)
zig build webrtc-handoff # live WebRTC three-party handoff: a gifter signs a give naming the exporter by webrtc designator, and the recipient redeems it by signaling-then-handshake, withdraws the gifted capability, and calls it over the DataChannel (ADR-0089; needs cargo)
zig build webrtc-answerer  # build the native answerer for the webrtc-browser-peer proof (ADR-0089 phase 6; needs cargo)
zig build webrtc-browser-peer # prove a real headless Chromium runs @pancake/web + @pancake/webrtc: a DataChannel to the native answerer carries a keyed OCapN session (ADR-0089 phase 6; needs cargo + deno + a Playwright Chromium)
zig build webrtc-browser-to-browser # prove two real headless Chromium peers bring up a direct WebRTC DataChannel and hold a keyed OCapN session over it, the signaling host out of the byte path (ADR-0089 phase 6; needs deno + a Playwright Chromium)
zig build iroh-interop      # live encrypted OCapN conversation: two pancake peers over real iroh endpoints (needs cargo)
zig build iroh-reachability # opt-in: live real-internet dial-by-id over n0 relays + DNS/pkarr discovery (needs cargo + internet)
zig build iroh-mesh         # live three-party handoff over iroh: recipient reaches the introduced exporter by node id (needs cargo)
zig build iroh-loop         # live iroh scale: many concurrent connections served from one loop thread (ADR-0057; needs cargo)
zig build iroh-bridge-redeem # live iroh redeem dial on driver.Bridge: recipient on one loop thread redeems via Loop.dialLocator (ADR-0076; needs cargo)
zig build tcp-loop          # live TCP scale: many concurrent connections served from one loop thread through the Host bridge (ADR-0076)
zig build bindings-iroh-loop # per-binding iroh scale proof: many connections served from one loop, every binding (needs cargo + the runtimes)
zig build deno-iroh-loop    # live iroh scale: the Deno binding serves many connections from one readiness loop (ADR-0057; needs cargo + deno)
zig build python-iroh-loop  # live iroh scale: the Python binding serves many connections from one readiness loop (ADR-0057; needs cargo + python3)
zig build rust-iroh-loop    # live iroh scale: the Rust binding serves many connections from one readiness loop (ADR-0057; needs cargo)
zig build racket-iroh-loop  # live iroh scale: the Racket binding serves many connections from one readiness loop (ADR-0057; needs cargo + racket)
zig build bindings-iroh-handoff # per-binding three-party handoff over iroh: every binding mints and redeems an iroh handoff give in one process (needs cargo + the runtimes)
zig build deno-iroh-handoff # three-party handoff over iroh: the Deno binding mints and redeems an iroh handoff give in one process (needs cargo + deno)
zig build python-iroh-handoff # three-party handoff over iroh: the Python binding mints and redeems an iroh handoff give in one process (needs cargo + python3)
zig build rust-iroh-handoff # three-party handoff over iroh: the Rust binding mints and redeems an iroh handoff give in one process (needs cargo)
zig build racket-iroh-handoff # three-party handoff over iroh: the Racket binding mints and redeems an iroh handoff give in one process (needs cargo + racket)
zig build bindings-iroh-redeem-posture # per-binding hermetic proof that a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)
zig build deno-iroh-redeem-posture # hermetic configured-redeem-posture proof for a hint-less iroh give: the Deno binding (needs cargo + deno)
zig build python-iroh-redeem-posture # hermetic configured-redeem-posture proof for a hint-less iroh give: the Python binding (needs cargo + python3)
zig build rust-iroh-redeem-posture # hermetic configured-redeem-posture proof for a hint-less iroh give: the Rust binding (needs cargo)
zig build racket-iroh-redeem-posture # hermetic configured-redeem-posture proof for a hint-less iroh give: the Racket binding (needs cargo + racket)
zig build bindings-keyed-tcp-restart # per-binding keyed-tcp restart proof: happy path, squatter refusal, same-seed fresh-port restart, every binding
zig build deno-keyed-tcp-restart # keyed-tcp restart proof: the Deno binding (happy, squatter, restart)
zig build python-keyed-tcp-restart # keyed-tcp restart proof: the Python binding (happy, squatter, restart)
zig build rust-keyed-tcp-restart # keyed-tcp restart proof: the Rust binding (happy, squatter, restart; needs cargo)
zig build racket-keyed-tcp-restart # keyed-tcp restart proof: the Racket binding (happy, squatter, restart; needs racket)
zig build bindings-iroh-reachability # per-binding live dial-by-id over n0 relays + DNS/pkarr discovery, every binding (opt-in; needs cargo + the runtimes + internet)
zig build deno-iroh-reachability # live dial-by-id over n0 relays + DNS/pkarr discovery: the Deno binding (opt-in; needs cargo + deno + internet)
zig build python-iroh-reachability # live dial-by-id over n0 relays + DNS/pkarr discovery: the Python binding (opt-in; needs cargo + python3 + internet)
zig build rust-iroh-reachability # live dial-by-id over n0 relays + DNS/pkarr discovery: the Rust binding (opt-in; needs cargo + internet)
zig build racket-iroh-reachability # live dial-by-id over n0 relays + DNS/pkarr discovery: the Racket binding (opt-in; needs cargo + racket + internet)
zig build iroh-abi          # build libpancake_net_transport_iroh, the iroh transport's public C ABI companion (needs cargo)
zig build webrtc-abi        # build libpancake_net_transport_webrtc, the WebRTC transport's public C ABI companion (ADR-0089 phase 3; needs cargo)
zig build gen-header-net-transport-webrtc        # regenerate include/pancake_net_transport_webrtc.h from src/c_abi/net_transport/webrtc/mod.zig
zig build gen-header-net-transport-webrtc-check  # verify include/pancake_net_transport_webrtc.h matches src/c_abi/net_transport/webrtc/mod.zig (fails if stale), part of check
zig build release-pack      # stage the installed archives, headers, and licenses into one versioned, checksummed per-target tarball under zig-out/release/ (needs cargo; .github/workflows/release.yml runs it per platform on a version tag)
zig build fixture-gen-check # regenerate the Syrup fixture corpus via the upstream Racket Syrup encoder and diff against the committed bytes (needs racket + syrup)
zig build gen-capnp-fixtures # regenerate Cap'n Proto golden fixtures under test/codec/capnp_fixtures/
zig build c-abi-extract-check # hermetic C-ABI extract hygiene: run each resolve port's own validator against the hostile fixture set in tools/c-abi/c-abi-extract-matrix.sh, accept clean lib/ (ADR-0077; part of check)
zig build ocapn-findings-check # reproduce the pinned op:listen arity discrepancy against the OCapN spec, suite, and Goblins submodules; part of check-external
zig build ocapn-conformance # run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)
zig build demo-rooms             # cross-language rooms chat: Zig/Rust/Python/Racket/Deno in one room (needs deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-iroh        # the rooms chat over iroh's encrypted QUIC: an iroh-enabled Zig client + cross-language clients through the iroh C ABI (needs cargo + deno)
zig build demo-rooms-dm          # rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)
zig build demo-rooms-dm-reply    # a host-wide giftable replies to its caller over the arriving connection via currentSession(), so a non-listening peer (a browser) receives the reply on the connection it opened (needs deno)
zig build demo-rooms-dm-back     # a member replies to a non-listening sender across a redeemed introduction: the sender hosts a reply inbox on the redeemed direct connection (sendRedeeming), room out of the path — the native, Chromium-free sibling of rooms-web-dm (needs deno)
zig build demo-rooms-dm-reredeem # sendRedeeming resolves the direct exporter from the reply's route (pancake_host_reference_exporter): a re-redeem to an already-dialed exporter resolves the same live session with no second dial (needs deno)
zig build demo-rooms-dm-iroh     # rooms DM-by-introduction over iroh's encrypted QUIC: cross-endpoint three-party handoff where the gift names the exporter's direct addresses, redeemed by a direct dial (needs cargo + deno)
zig build demo-rooms-dm-iroh-discovery # opt-in: the same rooms DM-by-introduction over iroh, but the gift names the exporter by node id ALONE and the recipient resolves it through n0 discovery (relays + DNS/pkarr), no direct-address hints (needs cargo + deno + internet)
zig build rooms-client           # run the native Zig rooms chat client (one-shot) against a room you started; pass `-- <locator> <room> <nick> <line> [roster]`
zig build rooms-peer              # run rooms presence via `pancake app rooms-peer`; pass `-- <verb> [flags]`. Install also ships a thin `rooms-peer` shim → `pancake app rooms-peer`. Source: `cli/app/rooms_peer.zig`
zig build rooms-web              # serve the rooms browser UI over TCP (public rooms + direct messages by introduction); open the printed URL (needs deno). `-Dport` pins the HTTP port (default 8000)
zig build rooms-web-relay-peer   # prove a wasm browser peer drives the room directory through web.ts's /relay byte pipe (needs deno)
zig build rooms-web-browser-peer # prove a real headless Chromium runs the @pancake/web peer through web.ts's /relay (needs deno + a Playwright Chromium)
zig build rooms-web-page      # prove the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line (needs deno + a Playwright Chromium)
zig build rooms-web-dm        # prove the rooms page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-tabs   # prove two browser tabs cold-dial each other by relay rendezvous (ADR-0088): one registers its keyed identity, the other redeems a room introduction by cold-dialing it tab-to-tab off-room, and the reply rides back over the arriving connection — browser-to-browser on a shared relay, deno-only (needs deno + a Playwright Chromium)
zig build rooms-web-iroh         # serve the rooms browser UI over iroh's encrypted QUIC (public rooms + direct messages by introduction); open the printed URL (needs cargo + deno)
zig build rooms-deploy-prep  # build everything the rooms deploy container mounts: shared libraries, iroh transport, wasm Host, and the prebuilt browser bundle (needs cargo + deno)
zig build demo-tasks             # cross-language tasks board: Zig/Rust/Python/Racket/Deno on one board (needs deno; joins python3/racket/cargo clients when present)
zig build demo-tools        # cross-language capability showcase: delegation/attenuation/revocation for AI agent harnesses (needs deno; joins python3/racket/cargo agents when present)
zig build accountability             # accountability application on pancake's own runtime over a real loopback TCP socket
zig build accountability-three-party # three-party accountability attribution across the handoff seam (in-memory, pure Zig)
zig build demo-accountability        # cross-language accountability demo: Zig host + Deno/Python callers (needs deno)
zig build examples
zig build gen-header-ocapn          # regenerate include/pancake_ocapn.h from src/c_abi/ocapn
zig build gen-header-ocapn-check    # verify that header matches src/c_abi/ocapn (fails if stale), part of check
zig build gen-header-driver         # regenerate include/pancake_driver.h from src/c_abi/driver
zig build gen-header-driver-check   # verify include/pancake_driver.h matches src/c_abi/driver (fails if stale), part of check
zig build gen-ts-abi                # regenerate the TypeScript ABI mirror from src/c_abi (the ocapn, driver, and iroh transport archives): target-independent constants into bindings/ts/abi/constants.ts (@pancake/abi), 64-bit struct layouts into bindings/ts/stack/internal/abi.ts, and the driver dlopen table into bindings/ts/stack/internal/ffi/driver.ts (from the annotated symbol inventory in src/c_abi/driver/symbols.zig)
zig build gen-ts-abi-check          # verify the generated TypeScript ABI mirror files match src/c_abi (fails if stale), part of check
zig build gen-binding-host-action   # regenerate binding HostAction decode/types from src/c_abi/driver
zig build gen-binding-host-action-check # verify binding HostAction decode/types match src/c_abi/driver (fails if stale), part of check
zig build gen-binding-constants     # regenerate binding ABI constants from src/c_abi (the ocapn, driver, and iroh transport archives)
zig build gen-binding-constants-check # verify binding ABI constants match src/c_abi (fails if stale), part of check
zig build gen-binding-rust-ffi      # regenerate the Rust binding's extern blocks from src/c_abi (types reflected, names from the generated headers)
zig build gen-binding-rust-ffi-check # verify the generated Rust extern blocks match src/c_abi (fails if stale), part of check
zig build gen-binding-python-ffi    # regenerate the Python binding's ctypes signature tables from src/c_abi (types reflected; the sigs dicts are positional)
zig build gen-binding-python-ffi-check # verify the generated Python ctypes signature tables match src/c_abi (fails if stale), part of check
zig build gen-binding-racket-ffi    # regenerate the Racket binding's FFI tables from src/c_abi (types reflected, wrapper argument names from the generated headers)
zig build gen-binding-racket-ffi-check # verify the generated Racket FFI tables match src/c_abi (fails if stale), part of check
zig build gen-binding-ffi-layouts    # regenerate binding FFI layout facts (sizes/offsets) from src/c_abi (the ocapn, driver, and iroh transport archives)
zig build gen-binding-ffi-layouts-check # verify binding FFI layout facts match src/c_abi (fails if stale), part of check
zig build gen-header-net-transport-tcp        # regenerate include/pancake_net_transport_tcp.h from src/c_abi/net_transport/tcp
zig build gen-header-net-transport-tcp-check  # verify include/pancake_net_transport_tcp.h matches src/c_abi/net_transport/tcp (fails if stale), part of check
zig build gen-header-net-transport-inproc        # regenerate include/pancake_net_transport_inproc.h from src/c_abi/net_transport/inproc
zig build gen-header-net-transport-inproc-check  # verify include/pancake_net_transport_inproc.h matches src/c_abi/net_transport/inproc (fails if stale), part of check
zig build gen-header-net-transport-iroh        # regenerate include/pancake_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig
zig build gen-header-net-transport-iroh-check  # verify include/pancake_net_transport_iroh.h matches src/c_abi/net_transport/iroh/mod.zig (fails if stale), part of check
zig build bench-frame-view
zig build bench-codec
zig build bench-dispatch-scaling # measure inbound dispatch ns/turn across N warmed peers (cold-cache regime) with p50/p99; writes a report under zig-out/bench-reports/
zig build bench-outbound     # measure the outbound engine path (send/step/takeOutbound per answered deliver) and the op:gc-answers release-storm shape; writes a report under zig-out/bench-reports/
zig build bench-peer-scaling # measure per-connection memory footprint and extrapolate to 500k connections; writes a report under zig-out/bench-reports/
zig build bench-snapshot     # measure vat snapshot/restore (S5): O(objects), flat in object size, off by default; writes a report under zig-out/bench-reports/
zig build relay-scaling      # measure the byte-transparent reference relay's per-connection footprint, prove it holds thousands of connections at once (not the demo's conservative default), and extrapolate to a host's descriptor and RAM ceiling; the relay-tier sibling of bench-peer-scaling; writes a report under zig-out/bench-reports/ (needs deno)
zig build bench-goblins      # cross-implementation benchmark: pancake's Racket binding vs Spritely Goblins, one shared app (needs racket + goblins); `-- --smoke`/`--suite=<name>` forwarded, writes a report under zig-out/bench-reports/
zig build bench-langs        # per-language consumer-cost benchmark: one fixed native Zig host, the client language swapped per row, driven by a native Zig orchestrator (no Racket on the driving path; Racket joins only as the binding and Goblins-reference rows). Zig always; joins deno/python3/cargo/racket+goblins when present; NOT a leaderboard; `-- --smoke`/`--client=<name>` forwarded, writes a report under zig-out/bench-reports/
zig build bench-iroh         # measure OCapN round-trip latency/throughput over encrypted iroh QUIC vs a same-machine cleartext TCP baseline (needs cargo); `-- --smoke` forwarded
zig build bench-site-report  # regenerate the performance page's charts and tables from live ReleaseFast runs of every bench + the Goblins comparison, splicing into site/content/performance.smd (needs racket + goblins + cargo)
```

`-Dport=N` pins the listening TCP port for the demo and live interop steps
(default: ephemeral for demos, each step's documented fixed port for interop;
`goblins-handoff` runs two listeners and takes N and N+1). `-Dattach=true` (demo
steps only, requires `-Dport`) joins an already-running server on that port
instead of spawning one; `demo-accountability` rejects it because each caller
needs a fresh host.

## Devcontainer

The committed `.devcontainer/` is the canonical ready-to-build environment.
Versions and paths live in
[`.devcontainer/pins.sh`](../../.devcontainer/pins.sh); per-arch checksums in
[`checksums.sh`](../../.devcontainer/checksums.sh).
[`check-env-sync.sh`](../../.devcontainer/check-env-sync.sh) keeps `Dockerfile`
and `devcontainer.json` aligned with `pins.sh`. Install scripts are host
orchestration only, the project gate remains `zig build check`. After container
open: `bash .devcontainer/post-create.sh`, then `zig build check`. See
[`.devcontainer/README.md`](../../.devcontainer/README.md). Serena MCP is
client-started (stdio); see [serena-mcp](serena-mcp.md).

Put first-class project commands in `build.zig`; devcontainer scripts handle
image build, cache ownership, and toolchain pin checks only.

## Generated State

Generated state is ignored and must not be committed:

- `.zig-cache/`
- `zig-out/`
- `zig-pkg/` (Zig's extracted-package dir; appears at `site/zig-pkg/` for the
  site sub-build)
- `.serena/cache/`
- `.serena/logs/`
- `.serena/memories/` unless a maintainer explicitly asks to share a memory
- `bindings/rust/target/`
- `bindings/rust/Cargo.lock`

If generated cache appears in status, fix `.gitignore` rather than relying on
manual cleanup.

The committed FFI tiers are generated too, and are never hand-edited:
`bindings/python/pancake/_sigs_gen.py`, `bindings/racket/private/ffi-*-gen.rkt`,
`bindings/rust/src/sys/*_fns_gen.rs`, `bindings/ts/**/internal/ffi/*.ts`, and
`include/pancake_*.h`. Changing a C signature means editing the Zig export, its
row in that archive's `symbols.zig` inventory, and the header prose in _both_ the
export's doc comment and `tools/gen/header/*.zig`, then running the `gen-*` steps
above. The paired `gen-*-check` steps ride `check`, so a hand-edit is caught, but
it is caught as staleness rather than as the signature change it was meant to be.

## Git Posture

Agents do not mutate git history. Read-only git commands are fine: `status`,
`diff`, `log`, `show`, `blame`, `branch`, `rev-parse`, `ls-files`.

`git checkout -- <path>` and `git restore` are working-tree writes, not reads:
on a tree carrying uncommitted work they destroy that work. To undo a probe
edit, restore from a copy saved beside the scratchpad before probing, never
from git.

A commit made when directed stages explicit paths, never `-a`/`-u`/`add .`:
other sessions work this tree concurrently, and a sweep commit that picks up
half of another session's in-flight edits ships a HEAD that does not compile.
Read `git status` immediately before staging and claim only your own files.

## Live CapTP (product CLI)

When CapTP must happen live in the session — call/fetch/tell a peer, host a
temporary listener, open a REPL, or script `--json` — load the
[pancake-cli skill](../skills/pancake-cli/SKILL.md): `zig build`, put
`zig-out/bin` on `PATH`, then use `pancake`. CapTP through the agent host's MCP
tools uses the project server (`.cursor/mcp.json` / `.mcp.json` →
`./pancake mcp`); load [pancake-mcp](../skills/pancake-mcp/SKILL.md).
Do not invent a Zig harness or binding stub for a shell-shaped CapTP act.
Room presence wake-loops stay in [rooms-peer](../skills/rooms-peer/SKILL.md).
Human walkthrough: [`docs/cli.md`](../../docs/cli.md). Hermetic goldens:
`zig build cli-test`.

## Product CapTP waits (cli/)

`SessionOptions` defaults handshake and settle budgets to `0` (unbounded). In
`cli/` that is a hang: dial/listen against a silent peer parks the process and
any goldens that dial without a budget. Product paths use
`cli/ocapn.sessionOpts()` (finite ms). Tests that dial CapTP pass an explicit
positive `handshake_timeout_ms`. `meta-check` refuses `handshake_timeout_ms: 0`,
`settle_timeout_ms: 0`, and empty `SessionOptions` on `connectUriOwned` /
`driver.listen` under `cli/`; `test/cli/session_cases.zig` pins the
silent-partner timeout. The same refusal covers `examples/zig/**`, where an
unbounded default is worse than a hang because a reader copies it. Map `HandshakeTimedOut` / `WaitTimedOut` to exit code
`timeout`.
