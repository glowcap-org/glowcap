# pancake — Build Steps

Every `zig build` step this repository declares, grouped by what it proves. Run
`zig build` from the repository root: a run started in a subdirectory leaves its
cache and output directories there and resolves relative paths wrong.

Two steps stand above the rest. `zig build check` needs no network and no
submodules, so it is the one to run while iterating on code. The other half is
`zig build check-external`, which runs every check whose authority lives
outside pancake.

`-Dport=N` pins the listening TCP port for the demo and live interop steps.
Demos default to an ephemeral port, and each interop step to the fixed port it
documents; `goblins-handoff` runs two listeners and takes N and N+1.
`-Dattach=true` works on demo steps that also get `-Dport`, and joins an
already-running server instead of spawning one. `demo-accountability` rejects
it, because each caller needs a fresh host.

## Adding a step

A new step belongs in the section that matches what it proves, beside its
closest sibling. Copy the shape the blocks below already use: the invocation,
the step name, then a `#` comment saying what the step proves, ending with the
tools it needs in parentheses when it needs anything beyond Zig. The line
`zig build web-peer-test   # the browser peer holds a keyed session (needs deno)`
is the pattern.

Line the `#` up with the other lines in the same block. Describe what the step
proves rather than how the build wires it, and leave the `part of check` and
`part of check-external` markers to the steps the build really wires that way.

## Everyday steps and checks

The steps a session reaches for most, and the two checks everything else feeds.

```sh
zig build check                # the in-tree check: no network, no submodules, no live peer; run this before calling code work complete (run it in the devcontainer — `check_runtimes` in build.zig lists what it needs on PATH)
zig build check-external       # core external protocol baseline: upstream OCapN suite, pinned-source findings, native Goblins both directions, every handoff role, the relayed give, the hinted-locator give, upstream-Syrup corpus parity (needs uv + racket + goblins)
zig build test                 # the correctness suite
zig build test -Dtest-filter=substring # only tests whose names match
zig build arch-check           # the layer boundaries: module edges, the no-I/O core, and file coverage
zig build meta-check           # the scaffolding and documentation claims, checked against the tree
zig build toolchain-check      # hold check to the runtimes it declares: no member may reach for an undeclared program
zig build oracle-check         # the protocol reference corpus and the scenario traces
zig build fmt                  # format Zig sources in place (zig fmt)
zig build fmt-check            # check Zig formatting (zig fmt --check), part of check
zig build cli-test             # in-tree pancake CLI goldens (incl. CapTP deadline hang-proof)
zig build cli                  # alias of `zig build cli-test`
zig build pancake              # run the CapTP CLI; pass `-- <command> …`
zig build examples             # the public examples
zig build consumer-check       # build a downstream package against the pancake module, the README's fetch-and-import path, as a check; part of check
zig build cross-check          # compile-only: full library for macOS (kqueue) + sans-io core for wasm32 + the browser-binding wasm Host, part of check
zig build perf-check           # ReleaseFast wall-clock cost: warm dispatch + outbound send against the docs/ladder.md step 2 ceilings, plus the gc-storm linearity ratio; part of check
zig build fuzz                 # mutation-fuzz every hostile-input target, one fuzzer run each; -Dfuzz-runs sets how long each one searches (default 500K)
zig build fuzz-run             # the fuzz worker `zig build fuzz` drives; add --fuzz yourself for Zig's coverage UI
zig build timeout-runner-test  # black-box the CI deadline wrapper and how the check sequence classifies its codes; runs before anything relies on that deadline; not in check (needs python3)
zig build c-abi-extract-check  # in-tree C-ABI extract hygiene: each resolve port's own validator against the hostile fixture set in tools/c-abi/c-abi-extract-matrix.sh (ADR-0077; part of check)
zig build ocapn-findings-check # reproduce the pinned op:listen, locator-hints, and withdrawal-lookup discrepancies against the OCapN spec, suite, and Goblins submodules; part of check-external
zig build ocapn-conformance    # run the upstream OCapN test suite against a pancake peer (needs uv + the ocapn-conformance submodule)
zig build fixture-gen-check    # regenerate the Syrup fixture corpus with the upstream Racket encoder and diff against the committed bytes (needs racket + syrup)
zig build gen-capnp-fixtures   # regenerate Cap'n Proto golden fixtures under test/codec/capnp_fixtures/
zig build racket-test          # Racket unit tests, file by file through `tools/check/racket-test.rkt`, because a bare `racket <file>` prints FAILURE, still exits 0, and never runs `module+ test` (needs racket + goblins)
zig build docs                 # generate the Zig API reference (autodoc) under zig-out/docs/
zig build site                 # build the documentation site (Zine + autodoc) under zig-out/site/
zig build docs-serve           # serve the documentation site locally at http://127.0.0.1:1990/pancake/
zig build release-pack         # stage the installed archives, headers, and licenses into one versioned, checksummed per-target tarball under zig-out/release/ (needs cargo)
```

## Formatting and lint outside the Zig tree

These steps need a non-Zig runtime on PATH, so they sit beside `check` rather
than inside it.

```sh
zig build bindings-fmt       # format the Rust crates and the TypeScript bindings in place (needs cargo + deno)
zig build bindings-fmt-check # Rust and TypeScript formatting, lint and type-check for both TypeScript scopes (the bindings workspace, and the root scope covering apps/, interop/, transports/, bench/, and tools/), plus ruff and mypy over the Python binding (needs cargo + deno + uv)
zig build ocapnviz-test      # the ocapnviz visualizer's own test suite; its Deno scope is excluded from the root one, so no other step reaches it. Skips when deno is absent; part of check
zig build ocapnviz-check     # everything ocapnviz answers to: tests, type-check, formatting, lint (needs deno)
zig build ocapnviz-live-browser # build production ocapnviz and prove its OCapN Live mode in Chromium (needs deno + a Playwright Chromium)
zig build ocapnviz-fmt       # format the ocapnviz sources in place (needs deno)
```

## Generated headers and binding mirrors

Each `gen-*` step writes a committed mirror, and its `-check` sibling rides
`check` so a hand-edit is caught as staleness.

```sh
zig build gen-header-ocapn       # regenerate include/pancake_ocapn.h from src/c_abi/ocapn
zig build gen-header-ocapn-check # verify that header matches src/c_abi/ocapn (fails if stale), part of check
zig build gen-header-locator       # regenerate the shared include/pancake_locator.h POD vocabulary
zig build gen-header-locator-check # verify the shared locator header (fails if stale), part of check
zig build gen-header-host        # regenerate include/pancake_host.h from src/c_abi/host
zig build gen-header-host-check  # verify include/pancake_host.h matches src/c_abi/host (fails if stale), part of check
zig build gen-header-transport-provider       # regenerate include/pancake_transport_provider.h from the shared provider ABI
zig build gen-header-transport-provider-check # verify the standalone provider ABI header (fails if stale), part of check
zig build gen-header-driver      # regenerate include/pancake_driver.h from src/c_abi/driver
zig build gen-header-driver-check # verify include/pancake_driver.h matches src/c_abi/driver (fails if stale), part of check
zig build iroh-driver-provider     # live ADR-0112 seam proof: the driver archive dials a real iroh endpoint through the common provider ABI (needs cargo)
```

The transport archives each carry their own header.

```sh
zig build gen-header-net-transport-tcp          # regenerate include/pancake_net_transport_tcp.h from src/c_abi/net_transport/tcp
zig build gen-header-net-transport-tcp-check    # verify it matches src/c_abi/net_transport/tcp (fails if stale), part of check
zig build gen-header-net-transport-inproc       # regenerate include/pancake_net_transport_inproc.h from src/c_abi/net_transport/inproc
zig build gen-header-net-transport-inproc-check # verify it matches src/c_abi/net_transport/inproc (fails if stale), part of check
zig build gen-header-net-transport-onion        # regenerate include/pancake_net_transport_onion.h from src/c_abi/net_transport/onion
zig build gen-header-net-transport-onion-check  # verify it matches src/c_abi/net_transport/onion (fails if stale), part of check
zig build gen-header-net-transport-iroh         # regenerate include/pancake_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig
zig build gen-header-net-transport-iroh-check   # verify it matches src/c_abi/net_transport/iroh/mod.zig (fails if stale), part of check
zig build gen-header-net-transport-webrtc       # regenerate include/pancake_net_transport_webrtc.h from src/c_abi/net_transport/webrtc/mod.zig
zig build gen-header-net-transport-webrtc-check # verify it matches src/c_abi/net_transport/webrtc/mod.zig (fails if stale), part of check
zig build gen-header-net-transport-relay        # regenerate include/pancake_net_transport_relay.h from src/c_abi/net_transport/relay/mod.zig
zig build gen-header-net-transport-relay-check  # verify it matches src/c_abi/net_transport/relay/mod.zig (fails if stale), part of check
```

The bindings read the same facts out of generated mirrors.

```sh
zig build gen-ts-abi                    # regenerate the TypeScript ABI mirror from src/c_abi: constants into bindings/ts/abi/constants.ts, 64-bit struct layouts into bindings/ts/stack/internal/abi.ts, and the symbol-owning dlopen tables — the libpancake_host byte-fed family into bindings/ts/stack/internal/ffi/host.ts and the libpancake_driver loop family into bindings/ts/stack/internal/ffi/driver.ts (from the annotated inventories in src/c_abi/host/symbols.zig and src/c_abi/driver/symbols.zig)
zig build gen-ts-abi-check              # verify the generated TypeScript ABI mirror matches src/c_abi (fails if stale), part of check
zig build gen-site-examples             # assemble site/examples snippets into SuperMD code-tabs between page markers (Start, bindings, onion, browser)
zig build gen-site-examples-check       # verify those tabs match site/examples (fails if stale), part of check
zig build gen-binding-constants         # regenerate binding ABI constants from src/c_abi
zig build gen-binding-constants-check   # verify binding ABI constants match src/c_abi (fails if stale), part of check
zig build gen-binding-host-action       # regenerate binding HostAction decode/types from src/c_abi/host
zig build gen-binding-host-action-check # verify binding HostAction decode/types match src/c_abi/host (fails if stale), part of check
zig build gen-binding-rust-ffi          # regenerate the Rust binding's extern blocks from src/c_abi
zig build gen-binding-rust-ffi-check    # verify the generated Rust extern blocks match src/c_abi (fails if stale), part of check
zig build gen-binding-python-ffi        # regenerate the Python binding's ctypes signature tables from src/c_abi
zig build gen-binding-python-ffi-check  # verify the generated Python ctypes signature tables match src/c_abi (fails if stale), part of check
zig build gen-binding-racket-ffi        # regenerate the Racket binding's FFI tables from src/c_abi
zig build gen-binding-racket-ffi-check  # verify the generated Racket FFI tables match src/c_abi (fails if stale), part of check
zig build gen-binding-ffi-layouts       # regenerate binding FFI layout facts (sizes/offsets) from src/c_abi
zig build gen-binding-ffi-layouts-check # verify binding FFI layout facts match src/c_abi (fails if stale), part of check
```

## C ABI consumers

Each binding exercises the C ABI as a real consumer. These steps prove the ABI
is consumable; they are never the authority for Zig semantics.

```sh
zig build bindings       # all five binding checks together
zig build rust-dogfood   # the Rust binding against the pancake archives (needs cargo)
zig build deno-dogfood   # the Deno binding against the pancake archives (needs deno)
zig build bun-dogfood    # the Bun binding, the same multi-runtime JS binding as Deno (needs bun)
zig build python-dogfood # the Python binding against the pancake archives (needs python3)
zig build racket-dogfood # the Racket binding against the pancake archives (needs racket)
zig build iroh-abi       # build libpancake_net_transport_iroh, the iroh transport's C ABI companion (needs cargo)
zig build iroh-abi-test  # test that companion, including off-thread constructor diagnostics (needs cargo + deno)
zig build webrtc-abi     # build libpancake_net_transport_webrtc, the WebRTC transport's C ABI companion (ADR-0089 phase 3; needs cargo)
```

The in-tree proof families run one scenario once per binding, every peer
pancake. The `bindings-*` step runs the whole family.

```sh
zig build bindings-keyed-tcp-restart   # keyed-tcp restart: happy path, squatter refusal, same-seed fresh-port restart, every binding
zig build deno-keyed-tcp-restart       # that proof, the Deno binding
zig build python-keyed-tcp-restart     # that proof, the Python binding
zig build rust-keyed-tcp-restart       # that proof, the Rust binding (needs cargo)
zig build racket-keyed-tcp-restart     # that proof, the Racket binding (needs racket)
zig build bindings-iroh-redeem-posture # a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)
zig build deno-iroh-redeem-posture     # that proof, the Deno binding (needs cargo + deno)
zig build python-iroh-redeem-posture   # that proof, the Python binding (needs cargo + python3)
zig build rust-iroh-redeem-posture     # that proof, the Rust binding (needs cargo)
zig build racket-iroh-redeem-posture   # that proof, the Racket binding (needs cargo + racket)
zig build deno-gifter-handoff          # pancake-only 3-node three-party handoff: a broker introduces a recipient to an exporter, then the recipient messages it directly (needs deno)
```

## Live Goblins interop

The live wire authority. Each of these talks to a real Spritely Goblins vat.

```sh
zig build goblins-interop          # live OCapN conversation with a real Goblins vat, both directions (needs racket + goblins)
zig build goblins-handoff          # three-party handoff with Goblins, pancake as recipient (needs racket + goblins)
zig build goblins-gift             # three-party handoff with Goblins, pancake as gifter (needs racket + goblins)
zig build goblins-exporter         # three-party handoff with Goblins, pancake as exporter: a Goblins pair deposits into and withdraws from pancake's gift registry (needs racket + goblins)
zig build goblins-relayed-give     # pancake introduces a Goblins recipient to a promise a second Goblins vat has not settled, and the recipient reads the give out of the listener fire (needs racket + goblins)
zig build goblins-native-pair-gift # two pancake vats and one Goblins vat: the pancake pair settles on pancake-next over Cap'n Proto while both Goblins sessions settle on the v1.0 Syrup baseline, and the give crosses that split (needs racket + goblins)
zig build goblins-gift-hints       # the gift topology with an opaque route hint: Goblins decodes and re-encodes the mapping-shaped exporter locator byte-exactly (needs racket + goblins)
zig build goblins-gc               # live GC evidence: inbound op:gc-exports after echo consumes a near export (needs racket + goblins)
zig build goblins-iroh             # live Goblins over encrypted QUIC through the iroh netlayer this repository wrote for Goblins, both directions (needs cargo + racket + goblins)
zig build goblins-rooms            # a real Goblins vat and a pancake peer hold one room, the vat on the v1.0 Syrup baseline beside the pancake member's pancake-next over Cap'n Proto (needs deno + racket + goblins)
zig build goblins-rooms-iroh       # the same room over encrypted QUIC, with the accepting side recording the endpoint key QUIC authenticated (needs cargo + deno + racket + goblins)
zig build goblins-rooms-dm         # a browser redeems a room introduction and direct-messages a real Goblins vat off-room over cleartext TCP, the vat answers on that connection, and the vat starts a direct message of its own to a native pancake member (needs deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-dm-iroh    # the browser's direction over encrypted iroh QUIC; the vat's own direction is TCP-only, and docs/boundaries.md says why (needs cargo + deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-matrix-iroh # heavyweight four-peer end gate: pin Goblins' cross-receiver count defect, then run room topology, every DM pair, close/reopen, and restart over iroh
zig build goblins-relay            # a browser peer holds a keyed OCapN session with a real Goblins vat through the Deno reference relay (needs deno + racket + goblins)
zig build bindings-goblins-interop # per-binding live keyed conversation with a real Goblins vat, every binding (needs racket + goblins + the runtimes)
zig build deno-goblins-interop     # that conversation, the Deno binding over the C ABI (needs deno + racket + goblins)
zig build python-goblins-interop   # that conversation, the Python binding (needs python3 + racket + goblins)
zig build rust-goblins-interop     # that conversation, the Rust binding (needs cargo + racket + goblins)
zig build racket-goblins-interop   # that conversation, the Racket binding (needs racket + goblins)
zig build deno-goblins-listen      # live keyed listen: the Deno binding publishes and a real Goblins vat dials it (needs deno + racket + goblins)
zig build bindings-goblins-handoff # per-binding three-party handoff, the binding as recipient redeeming a Goblins give (needs racket + goblins + the runtimes)
zig build deno-goblins-handoff     # that handoff, the Deno binding (needs deno + racket + goblins)
zig build python-goblins-handoff   # that handoff, the Python binding (needs python3 + racket + goblins)
zig build rust-goblins-handoff     # that handoff, the Rust binding (needs cargo + racket + goblins)
zig build racket-goblins-handoff   # that handoff, the Racket binding (needs racket + goblins)
zig build bindings-goblins-gift    # per-binding three-party handoff, the binding as gifter and a Goblins recipient redeeming (needs racket + goblins + the runtimes)
zig build deno-goblins-gift        # that gift, the Deno binding (needs deno + racket + goblins)
zig build python-goblins-gift      # that gift, the Python binding (needs python3 + racket + goblins)
zig build rust-goblins-gift        # that gift, the Rust binding (needs cargo + racket + goblins)
zig build racket-goblins-gift      # that gift, the Racket binding (needs racket + goblins)
```

## The iroh transport

iroh is the one netlayer whose handshake proves who the far peer is, so most of
these steps run over real endpoints.

```sh
zig build iroh-lib                   # build the iroh netlayer sidecar staticlib in transports/iroh (needs cargo)
zig build iroh-sidecar-test          # the sidecar's Rust unit tests, including the connect-timeout positive-fire proof against a bound-but-silent UDP black hole (needs cargo)
zig build iroh-interop               # live encrypted OCapN conversation: two pancake peers over real iroh endpoints (needs cargo)
zig build iroh-loop                  # live iroh scale: many concurrent connections served from one loop thread (ADR-0057; needs cargo)
zig build iroh-bridge-redeem         # a recipient on one loop thread redeems via Loop.dialLocator (ADR-0076; needs cargo)
zig build tcp-loop                   # live TCP scale: many concurrent connections served from one loop thread through the Host bridge (ADR-0076)
zig build iroh-reachability          # opt-in: live real-internet dial-by-id over n0 relays and DNS/pkarr discovery (needs cargo + internet)
zig build bindings-iroh-loop         # per-binding iroh scale: many connections served from one loop, every binding (needs cargo + the runtimes)
zig build deno-iroh-loop             # that scale proof, the Deno binding (ADR-0057; needs cargo + deno)
zig build python-iroh-loop           # that scale proof, the Python binding (needs cargo + python3)
zig build python-iroh-driver-provider  # live ADR-0112 Python parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the common provider ABI (needs cargo + python3)
zig build rust-iroh-driver-provider    # that same parity, the Rust binding (needs cargo)
zig build rust-iroh-loop             # that scale proof, the Rust binding (needs cargo)
zig build racket-iroh-loop           # that scale proof, the Racket binding (needs cargo + racket)
zig build bindings-iroh-handoff      # per-binding three-party handoff over iroh, minted and redeemed in one process (needs cargo + the runtimes)
zig build deno-iroh-handoff          # that handoff, the Deno binding (needs cargo + deno)
zig build python-iroh-handoff        # that handoff, the Python binding (needs cargo + python3)
zig build rust-iroh-handoff          # that handoff, the Rust binding (needs cargo)
zig build racket-iroh-handoff        # that handoff, the Racket binding (needs cargo + racket)
zig build bindings-iroh-reachability # per-binding dial-by-id over n0 relays and DNS/pkarr discovery (opt-in; needs cargo + the runtimes + internet)
zig build deno-iroh-reachability     # that dial, the Deno binding (opt-in; needs cargo + deno + internet)
zig build python-iroh-reachability   # that dial, the Python binding (opt-in; needs cargo + python3 + internet)
zig build rust-iroh-reachability     # that dial, the Rust binding (opt-in; needs cargo + internet)
zig build racket-iroh-reachability   # that dial, the Racket binding (opt-in; needs cargo + racket + internet)
```

## The WebRTC transport

ADR-0089 brings this netlayer up in phases, and the steps follow those phases.

```sh
zig build webrtc-lib                # build the DataChannel netlayer sidecar staticlib and phase-1 probe binary in transports/webrtc (needs cargo)
zig build webrtc-sidecar-test       # the sidecar's Rust unit tests, including the inbound backpressure proof: a far peer that outruns the reader waits for room instead of growing the buffer (needs cargo)
zig build webrtc-datachannel-test   # a headless Chromium RTCDataChannel carries bytes both directions to a native webrtc-crate peer on loopback (phase 1, signaling out-of-band over stdio; needs cargo + deno + a Playwright Chromium)
zig build webrtc-resident-check     # type-check the netlayer resident src/net/transport/webrtc.zig (phase 2), compile-only, no cargo; rides check
zig build webrtc-interop            # two native pancake peers hold a keyed OCapN session over a real DataChannel, signaling ferried in-process (phase 2; needs cargo)
zig build webrtc-loop               # many concurrent DataChannels served from one loop thread through the generic Host completion adapter (needs cargo)
zig build webrtc-bridge-redeem      # the recipient's loop redeems a give naming a bare webrtc designator, dialing through its configured signaling authority (needs cargo)
zig build webrtc-driver-provider    # install the WebRTC multiplexed provider into the generic C driver and open a session through it (needs cargo)
zig build webrtc-mesh               # two native peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (phase 5; needs cargo)
zig build webrtc-signaling-captp    # the exporter hosts a signaling inbox behind a keyed session, and the recipient drives offer/answer/candidate over it (phase 5; needs cargo)
zig build webrtc-answerer           # build the native answerer for the webrtc-browser-peer proof (phase 6; needs cargo)
zig build webrtc-browser-peer       # a real headless Chromium runs @pancake/web and @pancake/webrtc, and the DataChannel to the native answerer carries a keyed OCapN session (phase 6; needs cargo + deno + a Playwright Chromium)
zig build webrtc-browser-to-browser # two headless Chromium peers bring up a direct DataChannel and hold a keyed session, the offerer dialing a bare webrtc locator through Host.setSignaling with the signaling host out of the byte path (needs deno + a Playwright Chromium)
```

## The onion transport

`onion` is the netlayer the OCapN draft standardizes and the one upstream
Spritely Goblins ships. Everything that exercises it inside `zig build check`
drives a fake daemon on loopback, so it needs neither Tor nor the network. The
focused loop and binding checks use the same local setup. The live steps need
`tor` on `PATH` and outbound network access. During the conformance step,
pancake uses operator-supplied control and SOCKS endpoints while the pinned
upstream netlayer starts its own separate Tor.

```sh
zig build onion-loop # focused native OnionLoop completion tests against fake SOCKS and control daemons
zig build bindings-onion # install and exercise the onion provider from Rust, TypeScript, Python, and Racket (needs cargo + deno + python3 + racket)
zig build onion-interop # live Tor: two pancake peers hold an OCapN conversation over a real onion service (needs tor + network)
zig build goblins-onion # live Goblins over Tor: a real Goblins vat and a pancake peer hold OCapN sessions over hidden service circuits, both directions (needs tor + network + racket + goblins)
zig build ocapn-conformance-onion # run the upstream suite through its onion netlayer against pancake, using an operator-supplied Tor (needs uv + tor + network)
zig build demo-rooms-onion # run one hosted Rooms service and two independent clients over real Tor (needs deno + tor + network)
```

## The browser peer and the relays

The wasm Host is what a browser drives with bytes, and a relay carries those
bytes to a peer the tab cannot dial.

```sh
zig build wasm-driver           # build the browser binding's freestanding wasm32 Host module (ADR-0070) into zig-out/wasm/ (also folded into cross-check)
zig build wasm-driver-test      # the wasm32 Host holds a real keyed CapTP handshake from JS over an in-memory pipe (needs deno)
zig build wasm-abi-layout-check # the wasm32 Host's layout descriptor decodes cleanly and agrees with the abi.ts field counts (needs deno)
zig build wasm-import-check     # the wasm32 Host's import set is exactly {env.pancake_behavior_trampoline}, the sole behavior-dispatch seam (needs deno)
zig build web-peer-test         # the @pancake/web browser peer holds a keyed OCapN session over WebSocket against a native host (needs deno; ADR-0070 Milestone 1)
```

ADR-0086 holds every runtime's relay to one shared harness: TCP forwarding, the
non-optional backpressure clause, and the idle-timeout bounded-resources
clause.

```sh
zig build bindings-relay                  # the cross-runtime relay matrix (needs deno + uv + cargo + racket)
zig build bindings-relay-iroh             # the matrix's iroh leg: a browser peer holds a live iroh session through each runtime's relay, dialing a real iroh endpoint over QUIC (needs deno + uv + cargo + racket)
zig build deno-relay-test                 # one row: a browser peer holds a keyed session through the Deno reference relay bindings/ts/relay/serve.ts (needs deno)
zig build python-relay-test               # one row: the same through the Python relay (needs deno + uv)
zig build rust-relay-test                 # one row: the same through the Rust relay (tokio-tungstenite; needs deno + cargo)
zig build racket-relay-test               # one row: the same through the Racket relay (net/rfc6455; needs deno + racket)
zig build deno-relay-backpressure-test    # a stalled reader backpressures the far sender through the Deno relay (needs deno)
zig build python-relay-backpressure-test  # the same through the Python relay (needs deno + uv)
zig build rust-relay-backpressure-test    # the same through the Rust relay (needs deno + cargo)
zig build racket-relay-backpressure-test  # the same through the Racket relay (needs deno + racket)
zig build deno-relay-idle-test            # the Deno relay reclaims a silent idle session (needs deno)
zig build python-relay-idle-test          # the Python relay reclaims a silent idle session (needs deno + uv)
zig build rust-relay-idle-test            # the Rust relay reclaims a silent idle session (needs deno + cargo)
zig build racket-relay-idle-test          # the Racket relay reclaims a silent idle session (needs deno + racket)
zig build deno-relay-iroh-test            # a browser peer holds a live iroh session through the Deno relay's iroh leg (needs deno + cargo)
zig build python-relay-iroh-test          # the same through the Python relay, dialing iroh via dial_locator_for_relay (needs deno + uv + cargo)
zig build rust-relay-iroh-test            # the same through the Rust relay, dialing iroh via IrohNetlayer::connect_owned behind an opt-in iroh feature (needs deno + cargo)
zig build racket-relay-iroh-test          # the same through the Racket relay, dialing iroh via dial-locator-for-relay (needs deno + cargo + racket)
zig build bindings-keyed-relay-rendezvous # each language binding and the native CLI cold-dial a registered non-listening peer through the reference relay's rendezvous bridge (needs deno + the runtimes)
zig build deno-keyed-relay-rendezvous     # that cold dial, the Deno binding (needs deno)
zig build python-keyed-relay-rendezvous   # that cold dial, the Python binding (needs deno + uv)
zig build rust-keyed-relay-rendezvous     # that cold dial, the Rust binding (needs deno + cargo)
zig build racket-keyed-relay-rendezvous   # that cold dial, the Racket binding (needs deno + racket)
zig build zig-keyed-relay-rendezvous      # that cold dial, the native pancake CLI via PANCAKE_RENDEZVOUS (needs deno)
zig build rooms-web-noise-relay-provenance # browser relay session reports sealed-channel provenance
zig build zig-keyed-relay-register        # the native CLI registers at the reference relay with no listening socket and answers a cold dial (needs deno)
```

## Applications and demos

The applications pancake ships, and the cross-language demos that put several
runtimes in one conversation.

```sh
zig build demo-rooms                   # cross-language rooms chat: Zig/Rust/Python/Racket/Deno in one room (needs deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-iroh              # the rooms chat over iroh's encrypted QUIC, with cross-language clients through the iroh C ABI (needs cargo + deno)
zig build demo-rooms-dm                # rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)
zig build demo-rooms-dm-reply          # a host-wide giftable replies to its caller over the arriving session via currentSession(), so a non-listening peer receives the reply on the session it opened (needs deno)
zig build demo-rooms-dm-back           # a member replies to a non-listening sender across a redeemed introduction, hosting a reply inbox on the redeemed direct session (sendRedeeming); the native, Chromium-free sibling of rooms-web-dm (needs deno)
zig build demo-rooms-dm-reredeem       # sendRedeeming resolves the direct exporter from the reply's route, so a re-redeem reaches the same live session with no second dial (needs deno)
zig build demo-rooms-dm-iroh           # the same DM-by-introduction over encrypted QUIC, where the gift names the exporter's direct addresses (needs cargo + deno)
zig build demo-rooms-dm-iroh-discovery # opt-in: the gift names the exporter by node id alone and the recipient resolves it through n0 discovery, no direct-address hints (needs cargo + deno + internet)
zig build demo-tasks                   # cross-language tasks board: Zig/Rust/Python/Racket/Deno on one board (needs deno)
zig build demo-tools                   # cross-language capability showcase: delegation, attenuation, and revocation for AI agent harnesses (needs deno)
zig build accountability               # accountability application on pancake's own runtime over a real loopback TCP socket
zig build accountability-three-party   # three-party accountability attribution across the handoff seam (in-memory, pure Zig)
zig build demo-accountability          # cross-language accountability demo: Zig host with Deno and Python callers (needs deno)
zig build rooms-client                 # run the native Zig rooms chat client (one-shot); pass `-- <locator> <room> <nick> <line> [roster]`
zig build rooms-peer                   # run rooms presence via `pancake app rooms-peer`; pass `-- <verb> [flags]`. Install ships a thin `rooms-peer` shim. Source: `cli/app/rooms_peer.zig`
zig build rooms-web-iroh               # serve the rooms browser UI over iroh's encrypted QUIC; open the printed URL (needs cargo + deno). `-Dport` pins the HTTP port (default 8000)
zig build rooms-web-tcp                # serve the same UI over cleartext TCP, for a peer that speaks nothing else (needs deno)
zig build rooms-deploy-prep            # build everything the rooms deploy container mounts: shared libraries, iroh transport, wasm Host, prebuilt browser bundle (needs cargo + deno)
```

The rooms browser proofs each drive a real headless Chromium.

```sh
zig build rooms-web-relay-peer    # a wasm browser peer drives the room directory through serve.ts's /relay byte pipe (needs deno)
zig build rooms-web-browser-peer  # a real headless Chromium runs the @pancake/web peer through serve.ts's /relay (needs deno + a Playwright Chromium)
zig build rooms-web-page          # the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line (needs deno + a Playwright Chromium)
zig build rooms-web-reconnect     # the page survives losing its room server: it notices, reconnects, re-enters its room untouched, keeps the conversation the dead session delivered, and reaches the room again over the new one (needs deno + a Playwright Chromium)
zig build rooms-web-dm            # the page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-tabs       # two tabs cold-dial each other by relay rendezvous (ADR-0088): one registers its keyed identity, the other redeems a room introduction tab-to-tab off-room, and the reply rides back over the arriving connection (needs deno + a Playwright Chromium)
zig build rooms-web-dm-native     # a native peer cold-dials a browser member by relay rendezvous through its configured rendezvous mapping (Host.setRendezvousUrl; needs deno + a Playwright Chromium)
zig build rooms-web-dm-webrtc     # two browser members direct-message over a DataChannel by redeeming a webrtc handoff give, the room directory carrying only offer/answer/candidate (ADR-0089; needs deno + a Playwright Chromium)
zig build rooms-web-dm-viz        # a browser-to-browser direct message reaches the live timeline endpoint (ADR-0104): each tab publishes its own trace, and the endpoint scopes both producers' session ids apart (needs deno + a Playwright Chromium)
zig build rooms-web-dm-retarget   # a nickname changing hands cannot move a direct conversation: the member leaves, another is granted the name, and a message typed into the original conversation reaches nobody and says why (needs deno + a Playwright Chromium)
zig build rooms-web-dm-reopen     # reopening a closed direct conversation opens a second connection and that one carries: the timeline shows the first session gone and a session id nobody had seen, once over webrtc and once over keyed-relay (needs deno + a Playwright Chromium)
zig build rooms-web-viz-lifecycle # the live timeline draws a member's whole life in a room, counted through ocapnviz's own converter: two tabs are three peers and two sessions, a direct message adds a session with the room off its path, leaving keeps the session and drops the nickname, and a tab going away takes its peer and both its sessions (needs deno + a Playwright Chromium)
```

## Benchmarks

Benchmarks keep performance budgets visible. They are never an authority for
behavior. Each writes a report under `zig-out/bench-reports/`.

```sh
zig build bench-frame-view       # the borrowed frame-view path
zig build bench-codec            # the encode and decode path
zig build bench-dispatch-scaling # inbound dispatch ns/turn across N warmed peers (cold-cache regime) with p50/p99
zig build bench-outbound         # the outbound engine path (send/step/takeOutbound per answered deliver) and the op:gc-answers release-storm shape
zig build bench-peer-scaling     # per-connection memory footprint, extrapolated to 500k connections
zig build bench-snapshot         # vat snapshot/restore (S5): O(objects), flat in object size, off by default
zig build relay-scaling          # the reference relay's per-connection footprint and its descriptor and RAM ceiling; the relay-tier sibling of bench-peer-scaling (needs deno)
zig build bench-iroh             # OCapN round-trip latency and throughput over encrypted iroh QUIC against a same-machine cleartext TCP baseline (needs cargo); `-- --smoke` forwarded
zig build bench-goblins          # cross-implementation benchmark: pancake's Racket binding and Spritely Goblins on one shared app (needs racket + goblins); `-- --smoke`/`--suite=<name>` forwarded
zig build bench-langs            # per-language consumer cost: one fixed native Zig host, the client language swapped per row, driven by a native Zig orchestrator. Not a leaderboard; `-- --smoke`/`--client=<name>` forwarded
zig build bench-site-report      # regenerate the performance page's charts and tables from live ReleaseFast runs (needs racket + goblins + cargo)
```
