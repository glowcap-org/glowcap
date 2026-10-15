---
type: static
description: Every zig build step in the repository, grouped by what it proves.
sources:
  - resource: /build.zig
  - resource: /tools/build/
---

# glowcap: Build Steps

Every `zig build` step this repository declares, grouped by what it proves. Run
`zig build` from the repository root: a run started in a subdirectory leaves its
cache and output directories there and resolves relative paths wrong.

The aggregate checks divide evidence by the resources they own, as
[everyday steps](#everyday-steps-and-checks) lists. The side-effecting
commands in `runtime-check` take the build runner's execution lock, so their
ports and output directories cannot overlap.

Build options:

- `-Dport=N` pins the listening TCP port for the demo and live interop steps.
  Demos default to an ephemeral port, and each interop step to the fixed port it
  documents. `goblins-handoff` runs two listeners and takes N and N+1.
- `-Dattach=true` joins an already-running server instead of spawning one. It
  works on demo steps that also take `-Dport`. `demo-accountability` rejects
  it, because each caller needs a fresh host.
- `-Dtransport=iroh|tcp|onion` on `rooms-web` and `rooms-dev` picks the room
  transport, iroh by default.
- `-Dhot-reload=false` on `rooms-dev` serves compiled generations through the
  web front with the same state and grants. The default uses Vite Fast Refresh.
  Production compiler selection does not depend on this option.

The Rooms operations capabilities are server flags, passed after `--`:

- `--diagnostics` mints an inspect capability and prints its swiss number, as in
  `zig build rooms-web -- --diagnostics`.
- `--admin-listeners` mints the listener-admin capability.
- `--operator` mints the stewardship authority.
- `--peering` mints the directory-peering capability.
- `--irc` mints the IRC gateway.
- `--trace` serves the live timeline endpoint and mints its capability.
  `--trace-port` sets its port.

`rooms-dev` passes all six.

## Adding a step

Put a new step in the section that matches what it proves, beside its closest
sibling. Follow the blocks below: the invocation, then a `#` comment lined up
with its block. The comment says what the step proves and ends with the tools
it needs in parentheses when it needs more than Zig, as in
`zig build web-peer-test   # Chromium accepts a Noise-relay call from a Zig peer (needs deno + Playwright)`.
Say `part of check`, `part of runtime-check`, or `part of check-external` only
for steps the build wires to those gates.

## Everyday steps and checks

```sh
zig build check                # in-process Zig tests, static, generated, performance, and compile-only evidence
zig build runtime-check        # deterministic process, application, and language-workspace evidence without cross-step contention
zig build check-external       # outside-authority protocol conformance plus every shipped Rooms page proof (needs uv + racket + goblins + cargo + deno + Playwright)
zig build test                 # the correctness suite
zig build test -Dtest-filter=substring # only tests whose names match
zig build test -Dtest-layer=engine,driver # compile and run only these test layers (the top-level test/ directories)
zig build test-memcheck        # the protocol core and actors tests once more under valgrind, built for the baseline CPU; -Dtest-filter narrows it
zig build arch-check           # the layer boundaries: module edges, the no-I/O core, and file coverage
zig build source-check         # static cross-file source, documentation, generated-mirror, and scaffolding contracts
zig build infrastructure-check # devcontainer, worktree integration, and agent edit-hook behavior in temporary fixtures
zig build toolchain-check      # every program and toolchain target `check` declares is installed here, and no member uses an undeclared program
zig build loam-core-wasm-check # compile portable Loam calls for 32-bit Wasm without LMDB; part of check
zig build loam-abi-test        # C resource creation, ownership, portable transaction evaluation and uncertain storage recovery; part of check
zig build loam-browser-build   # compile and lint the Rust IndexedDB consumer against the Wasm C ABI (needs cargo + wasm-bindgen)
zig build loam-browser-test    # Chromium lifecycle, page reload, cold restoration, custody, cancellation, quota rollback and adapter costs; part of check-external (needs deno + Playwright)
zig build loam-rust-test       # Rust create/share/edit/restart/reopen, callback custody, cancellation, Clippy and the binding crate's formatting; part of runtime-check (needs cargo)
zig build loam-lmdb-test       # Loam record atomicity, capacity, custody, and reopen tests; part of check
zig build loam-sqlite-test     # the same Loam storage suite over SQLite, plus its refusal and foreign-file tests; part of check
zig build loam-actors-crash-test # CapTP actor recovery and cyclic references across SIGKILL; each crash step runs every disk engine; part of runtime-check
zig build loam-references-crash-test # Foreign recipe and content writes across SIGKILL, with fresh-vat role checks; part of runtime-check
zig build loam-managed-crash-test # Managed issuance, revocation, content and reference edits across SIGKILL; part of runtime-check
zig build loam-collection-crash-test # SIGKILL around a tracing sweep, then safe collection after reopen; part of runtime-check
zig build loam-lmdb-compaction-crash-test # SIGKILL through offline LMDB replacement, copy capacity refusal, and continuous writer custody; part of runtime-check
zig build loam-sqlite-compaction-crash-test # SIGKILL during and after a SQLite vacuum, then every live row in a usable store; part of runtime-check
zig build loam-storage-crash-test # SIGKILL before commit and after commit before installation; part of runtime-check (needs python3)
zig build loam-io-fault-test    # Linux write/sync faults, read faults and file truncation on both engines; part of runtime-check (needs python3)
zig build oracle-check         # the protocol reference corpus and the scenario traces
zig build fmt                  # format Zig sources in place (zig fmt)
zig build fmt-check            # check Zig formatting (zig fmt --check), part of check
zig build cli-test             # in-tree glowcap CLI goldens (incl. CapTP deadline hang-proof)
zig build cli                  # alias of `zig build cli-test`
zig build glowcap              # run the CapTP CLI; pass `-- <command> …`
zig build examples             # the public examples
zig build consumer-check       # build a downstream package against the glowcap module, the README's fetch-and-import path, as a check; part of check
zig build cross-check          # compile-only: full library for macOS (kqueue), I/O-free core for wasm32, the browser-binding wasm Host, and the Zig tree analyzed in ReleaseFast so the footprint gates also hold without std safety locks; part of check
zig build perf-check           # ReleaseFast wall-clock cost: warm dispatch + outbound send against the ceiling constants in those two bench files, plus the gc-storm linearity ratio; part of check
zig build fuzz                 # mutation-fuzz every untrusted-input target, one fuzzer run each; -Dfuzz-runs sets how long each one searches
zig build fuzz-run             # the fuzz worker `zig build fuzz` drives; add --fuzz yourself for Zig's coverage UI
zig build timeout-runner-test  # black-box the CI deadline wrapper and how the check sequence classifies its codes; runs before anything relies on that deadline; not in check (needs python3)
zig build c-abi-extract-check  # in-tree C-ABI extract hygiene: each resolve port's own validator against the malformed fixture set in tools/c-abi/c-abi-extract-matrix.sh (ADR-0077; part of check)
zig build ocapn-findings-check # reproduce the pinned op:listen, locator-hints, and withdrawal-lookup discrepancies against the OCapN spec, suite, and Goblins submodules; part of check-external
zig build ocapn-conformance    # run portable upstream OCapN modules plus the strict abort probe against glowcap (needs uv + the ocapn-conformance submodule)
zig build fixture-gen-check    # regenerate the Syrup fixture corpus with the upstream Racket encoder and diff against the committed bytes (needs racket + syrup)
zig build gen-capnp-fixtures   # regenerate Cap'n Proto golden fixtures under test/codec/capnp_fixtures/
zig build racket-test          # Racket unit tests, file by file through `raco test` (needs racket + goblins)
zig build docs                 # generate the Zig API reference (autodoc) under zig-out/docs/
zig build site                 # build the documentation site (Zine + autodoc) under zig-out/site/
zig build site-render-check    # render every built site page at phone width in the pinned Chromium; fails on console errors or horizontal overflow (needs deno + the image-baked browser)
zig build site-tabs-check      # press the code-tabs on every built site page in the pinned Chromium; fails when a tab does not open its own panel (needs deno + the image-baked browser)
zig build docs-serve           # serve the documentation site and print its address (binds 0.0.0.0 in the devcontainer; regenerates site example tabs on start and while site/examples changes)
zig build -Doptimize=ReleaseSafe release-pack -Dcpu=baseline # package the C SDK under zig-out/release/ and exercise extracted static/shared consumers (needs cargo; Debug and cross-target builds are refused)
zig build rooms-build # complete the installation under zig-out and stage zig-out/product for packaging/deployment (needs cargo + deno + wasm-bindgen)
zig build rooms-release # prepare the same complete host product with fixed ReleaseSafe and baseline CPU settings (needs cargo + deno + wasm-bindgen)
zig build glowcap-install-test # prove the checkout launcher, installed assets, skills, sessions and completion; part of runtime-check
zig build glowcap-host-test # prove verified host installation, atomic selection, refusal, and Docker deployment command handling without a daemon; part of runtime-check (needs python3)
zig build glowcap-pack -Doptimize=ReleaseSafe -Dcpu=baseline # package the complete host product under zig-out/glowcap-release/; exercise extracted browser serving, HTTP bootstrap, iroh, rooms, DMs and restart (needs cargo + deno + wasm-bindgen + python3; Debug and cross-target builds are refused)
zig build glowcap-package-test # release rollback and damaged-package fixtures cover checksums, extraction, skill links and Linux/macOS loader paths; part of check
zig build product-manifest-test # generate and parse a complete staged product manifest, rejecting unsafe members; part of check
zig build relay-tls-build     # fetch the pinned Mbed TLS release by checksum, compile the private minimal client configuration with Zig, and run engine/ownership plus pollable and completion real local WSS success/refusal tests (needs network, python3, openssl)
```

## Formatting and lint outside the Zig tree

These steps need a non-Zig runtime on PATH, so they sit beside `check`.

```sh
zig build bindings-fmt       # format the Rust crates and the TypeScript bindings in place (needs cargo + deno)
zig build bindings-fmt-check # Rust formatting and Clippy, TypeScript formatting/lint/type-check for both TypeScript scopes, plus ruff and mypy over the Python binding (needs cargo + deno + uv)
zig build rust-lint          # Clippy over every first-party Rust crate and target, including the binding async surface and Rooms service feature (needs cargo)
zig build ocapnviz-test      # the ocapnviz visualizer's own test suite, whose Deno scope is excluded from the root one (needs deno, part of runtime-check)
zig build ocapnviz-check     # everything ocapnviz answers to: tests, type-check, formatting, lint (needs deno)
zig build ocapnviz-live-browser # build production ocapnviz and prove its OCapN Live mode in Chromium (needs deno + a Playwright Chromium)
zig build ocapnviz-fmt       # format the ocapnviz sources in place (needs deno)
zig build ocapnviz-dev       # the development launch: ocapnviz from Vite under its own supervisor, so an interrupted run leaves no server on the port; open the printed URL (needs deno)
```

## Generated headers and binding mirrors

Each `gen-*` step writes a committed mirror, and its `-check` sibling is part
of `check`, so a hand edit shows up as staleness.

```sh
zig build gen-header-ocapn       # regenerate include/glowcap_ocapn.h from src/c_abi/ocapn
zig build gen-header-ocapn-check # verify that header matches src/c_abi/ocapn (fails if stale), part of check
zig build gen-header-locator       # regenerate the shared include/glowcap_locator.h POD vocabulary
zig build gen-header-locator-check # verify the shared locator header (fails if stale), part of check
zig build gen-header-loam                # regenerate the portable Loam header
zig build gen-header-loam-check          # verify the portable Loam header; part of check
zig build gen-header-loam-lmdb           # regenerate the LMDB companion header
zig build gen-header-loam-lmdb-check     # verify the LMDB companion header; part of check
zig build gen-header-loam-sqlite           # regenerate the SQLite companion header
zig build gen-header-loam-sqlite-check     # verify the SQLite companion header; part of check
zig build gen-header-loam-volatile         # regenerate the in-memory companion header
zig build gen-header-loam-volatile-check   # verify the in-memory companion header; part of check
zig build gen-binding-loam-layout        # regenerate Rust Loam layouts and fingerprints
zig build gen-binding-loam-layout-check  # verify Rust Loam layouts and fingerprints; part of check
zig build gen-header-host        # regenerate include/glowcap_host.h from src/c_abi/host
zig build gen-header-host-check  # verify include/glowcap_host.h matches src/c_abi/host (fails if stale), part of check
zig build gen-header-transport-provider       # regenerate include/glowcap_transport_provider.h from the shared provider ABI
zig build gen-header-transport-provider-check # verify the standalone provider ABI header (fails if stale), part of check
zig build gen-header-driver      # regenerate include/glowcap_driver.h from src/c_abi/driver
zig build gen-header-driver-check # verify include/glowcap_driver.h matches src/c_abi/driver (fails if stale), part of check
zig build iroh-driver-provider     # live ADR-0112 seam proof: the driver archive dials a real iroh endpoint through the common provider ABI (needs cargo)
```

The transport archives each carry their own header.

```sh
zig build gen-header-net-transport-tcp          # regenerate include/glowcap_net_transport_tcp.h from src/c_abi/net_transport/tcp
zig build gen-header-net-transport-tcp-check    # verify it matches src/c_abi/net_transport/tcp (fails if stale), part of check
zig build gen-header-net-transport-inproc       # regenerate include/glowcap_net_transport_inproc.h from src/c_abi/net_transport/inproc
zig build gen-header-net-transport-inproc-check # verify it matches src/c_abi/net_transport/inproc (fails if stale), part of check
zig build gen-header-net-transport-onion        # regenerate include/glowcap_net_transport_onion.h from src/c_abi/net_transport/onion
zig build gen-header-net-transport-onion-check  # verify it matches src/c_abi/net_transport/onion (fails if stale), part of check
zig build gen-header-net-transport-iroh         # regenerate include/glowcap_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig
zig build gen-header-net-transport-iroh-check   # verify it matches src/c_abi/net_transport/iroh/mod.zig (fails if stale), part of check
zig build gen-iroh-sidecar-constants            # regenerate the iroh sidecar Rust constants from iroh transport policy and frame-stream policy
zig build gen-iroh-sidecar-constants-check      # verify the iroh sidecar Rust constants match iroh transport policy and frame-stream policy (fails if stale), part of check
zig build gen-header-net-transport-webrtc       # regenerate include/glowcap_net_transport_webrtc.h from src/c_abi/net_transport/webrtc/mod.zig
zig build gen-header-net-transport-webrtc-check # verify it matches src/c_abi/net_transport/webrtc/mod.zig (fails if stale), part of check
zig build gen-webrtc-sidecar-constants          # regenerate the WebRTC sidecar Rust constants from src/net/transport/webrtc.zig
zig build gen-webrtc-sidecar-constants-check    # verify the WebRTC sidecar Rust constants match src/net/transport/webrtc.zig (fails if stale), part of check
zig build gen-header-net-transport-relay        # regenerate include/glowcap_net_transport_relay.h from src/c_abi/net_transport/relay/mod.zig
zig build gen-header-net-transport-relay-check  # verify it matches src/c_abi/net_transport/relay/mod.zig (fails if stale), part of check
```

The bindings read the same facts out of generated mirrors.

```sh
zig build gen-ts-abi                    # regenerate TypeScript constants, layouts, and symbol-owning dlopen tables from src/c_abi
zig build gen-ts-abi-check              # verify the generated TypeScript ABI mirror matches src/c_abi (fails if stale), part of check
zig build gen-site-examples             # assemble site/examples snippets into SuperMD code-tabs between page markers on the Start, binding, transport, and relay pages
zig build gen-site-examples-check       # verify those tabs match site/examples (fails if stale), part of check
zig build site-zig-examples-check       # compile every authoritative Zig transport snippet, rooted so each body is analyzed (`tools/check/site_example_root.zig`), plus the separately rooted iroh locator test, part of check
zig build site-ts-examples-check        # type-check every .ts transport snippet through the public package map, part of check
zig build site-python-examples-check    # type-check every .python transport snippet through the public package, part of bindings (needs python3 + uv)
zig build site-rust-examples-check      # type-check every .rust transport snippet through the public package, part of bindings (needs python3 + cargo)
zig build site-racket-examples-check    # compile every .racket transport snippet through the public package, part of bindings (needs python3 + racket)
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
zig build gen-rust-wasm-layouts         # generate Rust layout constants and fingerprints from the compiled wasm32 C ABI
zig build gen-rust-wasm-layouts-check   # verify Rust Wasm layout constants and fingerprints, part of check
```

The Rooms application and terminal clients read their wire vocabulary from
generated tables. `tools/gen/rooms_protocol.zig` declares it,
`apps/rooms/lib/protocol.ts` documents it, and
`apps/rooms/test/protocol_gen_test.ts` checks the projections against the
application's readers.

```sh
zig build gen-rooms-protocol            # regenerate the Rooms application and client protocol tables from tools/gen/rooms_protocol.zig
zig build gen-rooms-protocol-check      # verify those tables match tools/gen/rooms_protocol.zig (fails if stale), part of check
zig build gen-agent-index               # regenerate the agent index (the README beside the rules and skills) from each one's description
zig build gen-agent-index-check         # verify that index is current and every rule, skill, persona and hook states its purpose, part of source-check
zig build gen-dependencies              # regenerate docs/dependencies.md from the dep comments in every manifest
zig build gen-dependencies-check        # verify docs/dependencies.md matches those comments and every dependency has one, part of source-check
zig build gen-doc-values                # rewrite every number a doc quotes from a code constant between its value markers
zig build gen-doc-values-check          # verify each quoted value is current and its constant readable, part of source-check
zig build doc-impact                    # list the docs whose header sources name code changed since the fork from dev (`-- <base>` for another)
```

The project's mark is defined once, as the WebGPU shader in
`apps/rooms/web/ui/mark_gpu_field.ts`, and `tools/gen/mark/` traces every still
picture of it from a render of that shader. These two steps run the pinned
headless Chromium. `zig build source-check` covers the half that needs no
browser: it holds the committed files to one geometry, so a hand edit to any of
them fails in-tree.

```sh
zig build gen-mark        # re-trace the mark and rewrite the unlit and lit artwork under site/assets/ with their square rasters, and the mark's generated blocks in ui/tokens.css and ui/mark.css (needs deno + the image-baked browser)
zig build gen-mark-check  # verify those files still match a fresh trace of the shader (fails if stale; needs deno + the image-baked browser)
```

## C ABI consumers

Each binding exercises the C ABI as a consumer. These steps prove the ABI is
consumable and decide no Zig semantics.

```sh
zig build bindings       # every binding check plus the published-example checks
zig build rust-dogfood   # the Rust binding against the glowcap archives (needs cargo)
zig build rust-binding-lint # Clippy over the Rust binding library, tests, and examples with every feature enabled (needs cargo)
zig build deno-dogfood   # the Deno binding against the glowcap archives (needs deno)
zig build bun-dogfood    # the Bun binding, the same multi-runtime JS binding as Deno (needs bun)
zig build python-dogfood # the Python binding against the glowcap archives (needs python3)
zig build racket-dogfood # the Racket binding against the glowcap archives (needs racket)
zig build iroh-abi       # build libglowcap_net_transport_iroh, the iroh transport's C ABI companion (needs cargo)
zig build iroh-abi-test  # test the ABI, including optional off-thread constructor diagnostics (needs cargo + deno)
zig build webrtc-abi     # build libglowcap_net_transport_webrtc, the WebRTC transport's C ABI companion (ADR-0089, needs cargo)
```

Each in-tree proof family runs one scenario once per binding, with glowcap on
every side. The `bindings-*` step runs the whole family.

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
zig build bindings-verb-spine          # the promise, dial, listen, and GC verbs walked end to end against one fixed peer, every binding (needs deno + the runtimes)
zig build deno-verb-spine              # that walk, the Deno binding (needs deno)
zig build python-verb-spine            # that walk, the Python binding (needs deno + uv)
zig build rust-verb-spine              # that walk, the Rust binding (needs deno + cargo)
zig build racket-verb-spine            # that walk, the Racket binding (needs deno + racket)
zig build deno-gifter-handoff          # glowcap-only 3-node three-party handoff: a broker introduces a recipient to an exporter, then the recipient messages it directly (needs deno)
```

## Live Goblins interop

The live wire authority. Each step talks to a real Spritely Goblins vat.

```sh
zig build goblins-interop          # live OCapN conversation with a real Goblins vat, both directions (needs racket + goblins)
zig build goblins-differential    # accept or refuse per mutated frame, glowcap against a live Goblins vat, for a person to triage (needs racket + goblins)
zig build goblins-handoff          # three-party handoff with Goblins, glowcap as recipient (needs racket + goblins)
zig build goblins-gift             # three-party handoff with Goblins, glowcap as gifter (needs racket + goblins)
zig build goblins-exporter         # three-party handoff with Goblins, glowcap as exporter: a Goblins pair deposits into and withdraws from glowcap's gift registry (needs racket + goblins)
zig build goblins-relayed-give     # glowcap introduces a Goblins recipient to a promise a second Goblins vat has not settled, and the recipient reads the give out of the listener fire (needs racket + goblins)
zig build goblins-listen-recipient # a Goblins vat hands glowcap an unsettled promise; Session.listenTo observes its later nested-capability settlement and calls that capability (needs racket + goblins)
zig build goblins-glowcap-pair-gift # two glowcap vats and one Goblins vat: the glowcap pair settles on glowcap-next over Cap'n Proto while both Goblins sessions settle on the v1.0 Syrup baseline, and the give crosses that split (needs racket + goblins)
zig build goblins-gift-hints       # the gift topology with an opaque route hint: Goblins round-trips the mapping-shaped exporter locator byte-exactly (needs racket + goblins)
zig build goblins-gc               # live GC both ways: Goblins reclaims released exports and answers before close (needs racket + goblins)
zig build goblins-handoff-iroh     # Goblins gifter and exporter, glowcap completion-loop recipient over encrypted QUIC (needs cargo + racket + goblins)
zig build goblins-rooms-peering    # a real Goblins vat enters a foreign room through a glowcap directory publication over v1.0/Syrup, keeps the handed room after revocation, and the source reuses the name (needs deno + racket + goblins)
zig build goblins-iroh             # live Goblins over encrypted QUIC through the iroh netlayer this repository wrote for Goblins, both directions (needs cargo + racket + goblins)
zig build goblins-rooms            # a real Goblins vat and a glowcap peer hold one room, the vat on the v1.0 Syrup baseline beside the glowcap member's glowcap-next over Cap'n Proto (needs deno + racket + goblins)
zig build goblins-rooms-irc        # both IRC application edges against real Goblins: fixture IRC through the bridge both ways; ordinary IRC through the Rooms IRC server with channel traffic and an IRC-initiated DM reply (needs deno + racket + goblins)
zig build goblins-rooms-irc-bridge # the bridge half of that proof
zig build goblins-rooms-irc-server # the IRC server half of that proof
zig build goblins-rooms-iroh       # the same room over encrypted QUIC, with the accepting side recording the endpoint key QUIC authenticated (needs cargo + deno + racket + goblins)
zig build goblins-rooms-dm         # a browser redeems a room introduction and direct-messages a real Goblins vat off-room over cleartext TCP, the vat answers on that connection, and the vat starts a direct message of its own to a Zig glowcap member (needs deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-dm-iroh    # both Goblins-facing DM directions over encrypted iroh QUIC: the vat exports to the browser, then redeems a Zig member's introduction (needs cargo + deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-matrix-iroh # heavyweight four-peer end check: pin Goblins' cross-receiver count defect, then run room topology, every DM pair, close/reopen, and restart over iroh
zig build goblins-relay            # a browser peer holds a keyed OCapN session with a real Goblins vat through the Deno reference relay (needs deno + racket + goblins)
zig build bindings-goblins-interop # per-binding live keyed conversation with a real Goblins vat, every binding (needs racket + goblins + the runtimes)
zig build deno-goblins-interop     # that conversation, the Deno binding over the C ABI (needs deno + racket + goblins)
zig build python-goblins-interop   # that conversation, the Python binding (needs python3 + racket + goblins)
zig build rust-goblins-interop     # that conversation, the Rust binding (needs cargo + racket + goblins)
zig build racket-goblins-interop   # that conversation, the Racket binding (needs racket + goblins)
zig build bindings-goblins-listen  # reciprocal live conversation: Goblins dials and calls every binding listener (needs deno + racket + goblins + the runtimes)
zig build deno-goblins-listen      # that listener conversation, the Deno binding
zig build python-goblins-listen    # that listener conversation, the Python binding
zig build rust-goblins-listen      # that listener conversation, the Rust binding
zig build racket-goblins-listen    # that listener conversation, the Racket binding
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

## The shared sidecar runtime

The iroh and WebRTC sidecars are Rust crates behind a C ABI. They share
`transports/sidecar-common`: the private Tokio runtime a C call runs on, the
release barrier for tasks that outlive their handle, and the self-pipe
readiness channel. Each sidecar's cargo steps build it by path.

```sh
zig build sidecar-common-test        # the shared crate's Rust unit tests: private-runtime calls from inside an ambient runtime, and the task barrier (needs cargo)
```

## The iroh transport

```sh
zig build iroh-lib                   # build the iroh netlayer sidecar staticlib into the build cache; every artifact that links it depends on this step by path (needs cargo)
zig build iroh-sidecar-test          # the sidecar's Rust unit tests, including the connect-timeout positive-fire proof against a bound-but-silent UDP black hole (needs cargo)
zig build iroh-interop               # live encrypted OCapN conversation: two glowcap peers over real iroh endpoints (needs cargo)
zig build iroh-loop                  # live iroh scale: many concurrent connections served from one Server thread (ADR-0057; needs cargo)
zig build iroh-redeem                # a recipient Session redeems a handoff by dialing the exporter over iroh (needs cargo)
zig build tcp-loop                   # live TCP scale: many concurrent connections served from one Server thread
zig build iroh-reachability          # opt-in: live real-internet dial-by-id over n0 relays and DNS/pkarr discovery (needs cargo + internet)
zig build bindings-iroh-loop         # per-binding iroh scale: many connections served from one loop, every binding (needs cargo + the runtimes)
zig build deno-iroh-loop             # that scale proof, the Deno binding (ADR-0057; needs cargo + deno)
zig build python-iroh-loop           # that scale proof, the Python binding (needs cargo + python3)
zig build python-iroh-driver-provider  # live ADR-0112 Python parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the common provider ABI (needs cargo + python3)
zig build rust-iroh-driver-provider    # that same parity, the Rust binding (needs cargo)
zig build bindings-webrtc-driver-provider  # per-binding live WebRTC through the C provider: each binding dials the Zig answerer and accepts the Zig offerer (ADR-0244) with its own signaling (needs cargo + the runtimes)
zig build deno-webrtc-driver-provider      # that dial plus the listen, the Deno binding (needs cargo + deno)
zig build python-webrtc-driver-provider    # that dial plus the listen, the Python binding (needs cargo + python3)
zig build rust-webrtc-driver-provider      # that dial plus the listen, the Rust binding (needs cargo)
zig build racket-webrtc-driver-provider    # that dial plus the listen, the Racket binding (needs cargo + racket)
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

The WebRTC transport ([ADR-0089](decisions/adr/ADR-0089-webrtc-datachannel-netlayer.md)).

```sh
zig build webrtc-lib                # build the DataChannel netlayer sidecar staticlib and probe binary in transports/webrtc (needs cargo)
zig build webrtc-sidecar-test       # the sidecar's Rust unit tests, including the inbound backpressure proof: a far peer that outruns the reader waits for room instead of growing the buffer (needs cargo)
zig build webrtc-datachannel-test   # a headless Chromium RTCDataChannel carries bytes both directions to a Rust webrtc-crate peer on loopback (signaling out-of-band over stdio; needs cargo + deno + a Playwright Chromium)
zig build webrtc-resident-check     # type-check the netlayer resident src/net/transport/webrtc.zig, compile-only, no cargo; rides check
zig build webrtc-internal-test      # prove WebRTC resident identity, signaling-queue failure ownership, and the managed dial's and accept's exchange table against a scripted sidecar; rides check
zig build webrtc-interop            # two Zig glowcap peers hold a keyed OCapN session over a real DataChannel, signaling ferried in-process (needs cargo)
zig build webrtc-loop               # many concurrent DataChannels, each answered by the completion backend, served from one HostRuntime thread with the client identity proved (needs cargo)
zig build webrtc-redeem             # a recipient redeems a give naming a bare webrtc designator, dialing through its signaling authority while the exporter backend answers the offer (needs cargo)
zig build webrtc-driver-provider    # the generic C driver dials and listens over WebRTC through the provider's signaling callbacks, the offer is handed in with provide_offer, and releasing the loop cancels a dial still in flight (needs cargo)
zig build webrtc-mesh               # two Zig peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (needs cargo)
zig build webrtc-signaling-captp    # the exporter hosts a signaling inbox behind a keyed session, and the recipient drives offer/answer/candidate over it (needs cargo)
zig build webrtc-answerer           # build the Zig answerer the webrtc-browser-peer proof and the binding dial proofs reach (needs cargo)
zig build webrtc-offerer            # build the Zig offerer the binding listen proofs accept (needs cargo)
zig build webrtc-browser-peer       # a real headless Chromium runs @glowcap/web and @glowcap/webrtc, and the DataChannel to the Zig answerer carries a keyed OCapN session (needs cargo + deno + a Playwright Chromium)
zig build webrtc-browser-to-browser # two headless Chromium peers hold a keyed session over a direct DataChannel, one dialing through the WebRTC connector and the other accepting through the WebRTC listener, with the signaling host out of the byte path (needs deno + a Playwright Chromium)
```

## The onion transport

`onion` is the netlayer the OCapN draft standardizes and upstream Spritely
Goblins ships. Everything that exercises it inside `zig build check`, plus the
focused loop and binding checks, drives a fake daemon on loopback and needs
neither Tor nor the network. The live steps need `tor` on `PATH` and outbound
network access. In the conformance step, glowcap uses operator-supplied control
and SOCKS endpoints and the pinned upstream netlayer starts a separate Tor.

```sh
zig build onion-loop # focused OnionLoop completion tests against fake SOCKS and control daemons
zig build onion-pending-listen # the onion listener's pending publish through the completion residents, over the fake daemon
zig build bindings-onion # install and exercise the onion provider from Rust, TypeScript, Python, and Racket (needs cargo + deno + python3 + racket)
zig build onion-interop # live Tor: two glowcap peers hold an OCapN conversation over a real onion service (needs tor + network)
zig build goblins-onion # live Goblins over Tor: a real Goblins vat and a glowcap peer hold OCapN sessions over hidden service circuits, both directions (needs tor + network + racket + goblins)
zig build ocapn-conformance-onion # run the upstream suite through its onion netlayer against glowcap, using an operator-supplied Tor (needs uv + tor + network)
zig build demo-rooms-onion # run one hosted Rooms service and two independent clients over real Tor (needs deno + tor + network)
```

## The browser peer and the relays

```sh
zig build wasm-driver           # build the browser binding's freestanding wasm32 Host module (ADR-0070) into zig-out/wasm/ (also folded into cross-check)
zig build wasm-archives         # build Host, OCapN, and Loam static Wasm archives into zig-out/wasm/lib for direct Rust linking
zig build wasm-driver-test      # the wasm32 Host holds a real keyed CapTP handshake from JS over an in-memory pipe (needs deno)
zig build wasm-abi-layout-check # the wasm32 Host's layout descriptor decodes cleanly and agrees with the abi.ts field counts (needs deno)
zig build wasm-import-check     # the wasm32 Host imports exactly its behavior and hosted-retirement callbacks (needs deno)
zig build web-peer-test         # @glowcap/web holds keyed WebSocket sessions and Chromium accepts a Noise-relay call from a Zig peer (needs deno + Playwright; ADR-0070/0107)
```

ADR-0086 holds every runtime's relay to one shared harness: TCP forwarding,
the backpressure clause, and the idle-timeout bounded-resources clause.

```sh
zig build bindings-relay                  # the cross-runtime relay matrix (needs deno + uv + cargo + racket)
zig build bindings-wss-relay       # each binding projects exact WSS trust refusals, then calls and closes through one local CA fixture (needs deno + uv + cargo + racket)
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
zig build rust-relay-iroh-test            # the same through the Rust relay, dialing iroh via Netlayer::connect_owned behind an opt-in iroh feature (needs deno + cargo)
zig build racket-relay-iroh-test          # the same through the Racket relay, dialing iroh via dial-locator-for-relay (needs deno + cargo + racket)
zig build bindings-keyed-relay-rendezvous # each language binding and the glowcap CLI cold-dial a registered non-listening peer through the reference relay's rendezvous bridge (needs deno + the runtimes)
zig build deno-keyed-relay-rendezvous     # that cold dial, the Deno binding (needs deno)
zig build python-keyed-relay-rendezvous   # that cold dial, the Python binding (needs deno + uv)
zig build rust-keyed-relay-rendezvous     # that cold dial, the Rust binding (needs deno + cargo)
zig build racket-keyed-relay-rendezvous   # that cold dial, the Racket binding (needs deno + racket)
zig build bindings-noise-relay-listen     # each event-loop binding registers and serves one Noise-sealed relay session (needs deno + uv + cargo + racket)
zig build deno-noise-relay-listen         # that managed listener through Deno (needs deno)
zig build python-noise-relay-listen       # that managed listener through Python (needs deno + uv)
zig build rust-noise-relay-listen         # that managed listener through Rust (needs deno + cargo)
zig build racket-noise-relay-listen       # that managed listener through Racket (needs deno + racket)
zig build deno-wss-relay           # WSS success plus exact hostname and unknown-CA refusal through Deno (needs deno)
zig build python-wss-relay         # the same C archive through Python (needs deno + uv)
zig build rust-wss-relay           # the same C archive through Rust's static consumer (needs deno + cargo)
zig build racket-wss-relay         # the same C archive through Racket (needs deno + racket)
zig build zig-keyed-relay-rendezvous      # that cold dial, the glowcap CLI via GLOWCAP_RENDEZVOUS (needs deno)
zig build zig-keyed-relay-register        # the glowcap CLI registers at the reference relay with no listening socket and answers a cold dial (needs deno)
```

## Applications and demos

The applications glowcap ships, and cross-language demos with several runtimes
in one conversation.

```sh
zig build demo-rooms                   # cross-language rooms chat: Zig/Rust/Python/Racket/Deno in one room (needs deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-iroh              # the rooms chat over iroh's encrypted QUIC, with cross-language clients through the iroh C ABI (needs cargo + deno)
zig build demo-rooms-dm                # rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)
zig build demo-rooms-dm-reply          # a Host publication replies to its caller over the arriving session via currentSession(), so a non-listening peer receives the reply on the session it opened (needs deno)
zig build demo-rooms-dm-back           # a member replies to a non-listening sender across a redeemed introduction, hosting a reply inbox on the redeemed direct session (sendRedeeming); the Chromium-free sibling of rooms-web-dm (needs deno)
zig build rooms-dm-reredeem            # sendRedeeming resolves the direct exporter from the reply's route, so a re-redeem reaches the same live session with no second dial (needs deno, part of runtime-check)
zig build demo-rooms-dm-iroh           # the same DM-by-introduction over encrypted QUIC, the gift naming the exporter's direct addresses (needs cargo + deno)
zig build demo-rooms-dm-iroh-discovery # opt-in: the gift names the exporter by node id alone and the recipient resolves it through n0 discovery, no direct-address hints (needs cargo + deno + internet)
zig build demo-tasks                   # cross-language tasks board: Zig/Rust/Python/Racket/Deno clients on one Zig server saved in Loam (needs deno)
zig build tasks-server                 # serve a Tasks board over TCP from the repository root; pass `-- --data=DIR [--port=N]`
zig build tasks-app-test               # the Zig tasks server over TCP: add, move, an oversized task refused without a change, shares and watchers across a reopened store (part of check)
zig build tools-app-test               # the tools showcase's attenuation and revocation, held in-tree (needs deno, part of runtime-check)
zig build demo-tools                   # cross-language capability showcase: delegation, attenuation, and revocation for AI agent harnesses (needs deno)
zig build accountability               # accountability application on glowcap's own runtime over a real loopback TCP socket
zig build accountability-three-party   # three-Host accountability attribution over a live loopback TCP handoff
zig build accountability-blake3-test   # pin the accountability app's hand-rolled Blake3 (Deno and Python) against known vectors (needs deno + python3, part of runtime-check)
zig build demo-accountability          # cross-language accountability demo: Zig host with Deno and Python callers (needs deno)
zig build rooms-client                 # run the Zig rooms chat client (one-shot); pass `-- <locator> <room> <nick> <line> [roster]`
zig build rooms-chat-build             # build and install the interactive Rust rooms chat client (needs cargo)
zig build rooms-chat                   # run the interactive Rust rooms chat client; pass `-- <locator> <room> <nick>` (needs cargo)
zig build rooms-web-operations-refresh # operations pagination, search, capability removal, and reload on the shipped page (needs cargo + deno + a Playwright Chromium)
zig build rooms-trace-tail             # tail a Rooms server's live trace as lines; pass `-- <sturdyref> [--json]` (the ROOMS-TRACE-LISTENING value, needs deno)
zig build rooms-server-test            # run the in-tree Rooms server and UI contract tests (needs cargo + deno, part of runtime-check)
zig build rooms-terminal-client-test   # run the Zig, Rust, Python, and Racket client contracts for watcher parsing, the membership-ended notice, and unread backpressure (needs cargo + python3 + racket); the Zig one also rides `check`
zig build rooms-browser-build          # production Rooms application Wasm and generated JavaScript glue
zig build rooms-browser-metadata-check # verify browser limits and capability metadata against their Rust owners
zig build rooms-browser-test           # production workspace startup in Deno and Chromium
zig build rooms-rust-test              # shared Rust grant policy, persistence failures, static Host linking, and the workspace's formatting, part of runtime-check
zig build bench-rooms-admission        # admission check cost, retained policy bytes and zero steady policy allocations (part of rooms-rust-test)
zig build rooms-session-foreign-test   # maximum foreign session admission, capacity refusal and cold replacement, each under its own process deadline
zig build rooms-rust-lint              # clippy over the Rooms Rust workspace, without C archive builds (needs cargo, part of runtime-check)
zig build rooms-rust-browser-test      # shared Rust contracts and Rooms policy projection in Deno and Chromium; part of check-external; setup in apps/rooms/rust/README.md
zig build rooms-rust-contract-browser-test # focused portable declarations and linked Host contracts in Deno and Chromium
zig build rooms-rust-browser-host-test # async Rust Host, capability calls, Rooms client and browser deadlines; part of rooms-rust-browser-test
zig build rooms-managed-sharing-browser-test # exact managed use/control sharing, attenuation and lifecycle through the production Noise relay
zig build rooms-managed-rooms-browser-test # managed browser registration, room subscription, chat and exact-source incoming files through the production server
zig build rooms-session-graph-browser-test # focused Chromium session graph commit, rollback, unknown outcomes and cold reload
zig build rooms-session-executor-browser-test # focused managed receipt execution, interruption and cold recovery in Chromium
zig build rooms-session-executor-browser-test -Drooms-session-executor-group=3 # readers, access and cold opening only; the default runs all four groups in separate processes, with a deadline for each scenario
zig build rooms-session-foreign-browser-test # focused maximum foreign field restoration and disconnected preservation in Chromium
zig build rooms-session-foreign-browser-reload-test # maximum foreign fields across full source-page reload with a surviving exporter
zig build rooms-archive-test           # prove the member archive contract, bounded durable store, v1/Syrup wire path, and process restart (needs deno)
zig build rooms-archive-build          # build and install the archive peer (needs cargo)
zig build rooms-peers-test             # prove the archive peer, session peer, and room server's identity, transport, restart and signal shutdown (needs cargo, part of runtime-check)
zig build rooms-agent-test             # exercise the agent skill across multiple rooms, DMs, acknowledgement and restart (needs cargo + python3, part of runtime-check)
zig build rooms-archive                # run the durable archive peer; pass `-- --state=<directory>` (iroh by default, needs cargo)
zig build rooms-session-build          # build and install the durable Rooms session runtime (needs cargo)
zig build rooms-session                # run `glowcap apps rooms session`; pass `-- <verb> [flags]`, such as `-- serve --dir=<directory>`
zig build rooms-irc-server-build       # build and install the Rooms IRC server (needs cargo)
zig build rooms-irc-server             # ordinary IRC clients enter Rooms; loopback by default, TLS required for public bind
zig build rooms-irc-bridge-build       # build and install the standalone IRC bridge (needs cargo)
zig build rooms-irc-bridge -- --irc-realname="bridge bot; admin: YOUR_IRC_NICK" # serve an IRC channel as a Rooms directory; policy prerequisites in apps/rooms/irc/README.md
zig build rooms-server-build           # build and install the room server (needs cargo)
zig build rooms-server                 # run the Rooms room server, the directory members register with and the rooms they enter; pass `-- [--state=<directory>] [--history] [--admin-listeners] [--diagnostics] [--operator] [--peering] [--trace]` (iroh by default, needs cargo)
zig build rooms-web-build              # build and install the HTTP front (needs cargo)
zig build rooms-web-test               # the installed web front's HTTP, relay admission and startup/shutdown custody (needs cargo + deno + python3, part of runtime-check)
zig build rooms-web-tor-test           # opt-in: private Tor ownership and durable directory service key, networking disabled (needs cargo + deno + python3 + tor)
zig build rooms-web                    # serve the rooms browser UI; open the printed URL (needs cargo + deno). `-Dtransport` picks iroh (encrypted QUIC), tcp (cleartext, for a peer that speaks nothing else; `-- --bind= --announce-host=` expose it on a LAN), or onion (a Tor onion service that starts a private Tor unless GLOWCAP_ONION_SOCKS/GLOWCAP_ONION_CONTROL name one; needs tor). `-Dport` pins the HTTP port (default 8080)
zig build rooms-dev                    # React Fast Refresh by default; -Dhot-reload=false serves compiled generations through the web front, with the same operator grants, durable state, and -Dtransport (needs cargo + deno)
```

Each rooms browser proof drives a headless Chromium. The rows that need cargo
run their page's rooms on the installed Rooms server, including its
operations and timeline capabilities.

```sh
zig build rooms-web-relay-peer    # a wasm browser peer drives the room directory through the Rooms web server's /relay byte pipe (needs deno)
zig build rooms-web-page          # the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line (needs deno + a Playwright Chromium)
zig build rooms-web-admission     # configured refusal preserves drafts, attachment custody, cleanup and unrelated progress in the shipped page
zig build rooms-web-responsiveness # stable presentation and bounded input latency under delayed traffic and event bursts
zig build rooms-web-proofs        # every shipped Rooms page browser proof, run concurrently, then the timed responsiveness proof alone (needs cargo + deno + a Playwright Chromium; part of check-external and CI)
zig build rooms-web-link-preview  # link previews reconcile ready, retry, remove, image-failure, and delivered-link fallback states with the real Rooms controls (needs deno + a Playwright Chromium)
zig build rooms-web-shared-session # two browser profiles attach to the session peer and mirror one durable Rooms member, workspace, and capability vault (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-hosted-session # one browser hosts its local session and another Rooms origin attaches through the capability's iroh signaling directory (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-reconnect     # the page survives losing its room server: it reconnects, re-enters its room, keeps the conversation already delivered, and reaches the room over the new session (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm            # the page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-tabs       # two tabs DM over the default WebRTC path, including closing and reopening the introduced line (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-deno     # a Deno peer on the C library cold-dials a browser member over sealed noise-relay rendezvous through its composed relay provider (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-noise      # two browser members DM through the room relay over an end-to-end Noise-sealed rendezvous session, with the room off the message path (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-webrtc     # two browser members direct-message over a DataChannel by redeeming a webrtc handoff give, the room directory carrying only offer/answer/candidate (ADR-0089; needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-session-webrtc # the session process direct-messages a browser member over a DataChannel with no relay, signaling through the room directory that introduced the member (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-routes        # a cold /room/<name> link arrives in that room, opening a room writes its address, back and forward follow the view, following an address never moves the sidebar, and a private room's key stays out of the address (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-manager       # a reloaded workspace re-enters the rooms it manages by name and its saved manager capability still works (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-boot-theme    # the first paint uses the theme the reader left, read from the stored workspace before any application code runs, and a browser with no workspace gets the stylesheet default (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-private       # a private room is reachable only through its reference: it is in no list, its name opens a different room, and handing over the reference is the only way in (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-foreign    # a visitor starts a direct message in a room they joined: the tab holds its own page's directory and the one it went to, and the redeem signals through the directory that introduced the member (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-trace        # a browser-to-browser direct message reaches the live timeline endpoint (ADR-0104): each tab publishes its own trace, and the endpoint scopes both producers' session ids apart (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-retarget   # a nickname changing hands cannot move a direct conversation: the member leaves, another is granted the name, and a message typed into the original conversation reaches nobody and says why (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-dm-reopen     # reopening a closed direct conversation opens a second connection and that one carries: the timeline shows the first session gone and a session id nobody had seen, once over webrtc and once over noise-relay (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-trace-lifecycle # the live timeline shows a member's whole life in a room, counted through the ocapnviz converter: two tabs are three peers and two sessions, a direct message adds a session with the room off its path, leaving keeps the session and drops the nickname, and a tab going away takes its peer and both its sessions (needs cargo + deno + a Playwright Chromium)
zig build rooms-web-archive       # a reader selects a durable message-archive peer, writes history, closes the browser profile, and recovers the attributed line from the same authority in a fresh profile (needs cargo + deno + a Playwright Chromium)
```

## Benchmarks

Benchmarks print measurements or write reports under `zig-out/bench-reports/`.

```sh
zig build bench-floors -Doptimize=ReleaseFast # each primitive alone (Ed25519, Noise XK handshake and records, frame copy, loopback round trip); bench/README.md pairs product paths with these; -- --smoke under check
zig build bench-frame-view       # the borrowed frame-view path
zig build bench-host-locator     # warmed Host route replacement and accept fallback allocation traffic
zig build bench-uri -Doptimize=ReleaseFast # locator and sturdyref rendering time and allocation traffic
zig build bench-set-uniqueness -Doptimize=ReleaseFast # borrowed set validation and collision scratch on both codecs
zig build bench-rooms-projection # production Rooms projection conversation and line-custody visit counts
zig build bench-codec            # the encode and decode path
zig build bench-dispatch-scaling # inbound dispatch ns/turn across N warmed peers (cold-cache regime) with p50/p99
zig build bench-outbound         # the outbound engine path (send/step/takeOutbound per answered deliver) and the op:gc-answers release-storm shape
zig build bench-peer-scaling     # per-session memory report; add `-- --live` for authenticated socket scale (500k setup and result: bench/README.md)
zig build bench-snapshot         # vat snapshot/restore (S5): O(objects), flat in object size, off by default
zig build bench-loam -Doptimize=ReleaseFast # LMDB-backed conversation graph, sleepy actors, edits, collection, and cold reads at scale, and the Tasks app on each disk engine (`-- --tasks-only --engine=lmdb|sqlite` picks one); -- --smoke under check
zig build relay-scaling          # the reference relay's per-connection footprint and its descriptor and RAM ceiling; the relay-tier sibling of bench-peer-scaling (needs deno)
zig build bench-iroh             # OCapN round-trip latency and throughput over encrypted iroh QUIC against a same-machine cleartext TCP baseline (needs cargo); `-- --smoke`, `-- --row=greet|report|session-open`, `-- --codec=syrup|capnp`, `-- --readings=N --frame-cap=N`, and `-- --transport=tcp|noise-tcp|inproc|iroh|iroh-loop` forwarded
zig build bench-goblins          # cross-implementation benchmark: glowcap's Racket binding and Spritely Goblins on one shared app (needs racket + goblins); `-- --smoke`/`--suite=<name>` forwarded
zig build bench-capnp            # Cap'n Proto RPC echo round trip in Rust (capnp-rpc) and C++ (reference library) on one loopback socket, for the benchmarks page comparison (needs capnp, cargo, g++); `-- --smoke`/`--pin=A,B` forwarded
zig build bench-langs            # per-language consumer cost: one fixed Zig host, the client language swapped per row, driven by a Zig orchestrator; `-- --smoke`/`--client=<name>` forwarded
zig build bench-site-report      # regenerate the performance pages' charts and tables from live ReleaseFast runs (needs racket + goblins + cargo, plus capnp and g++ for `bench-capnp`)
```

A `profile-*` step runs a bench under callgrind, built ReleaseFast for the
baseline CPU, and ranks the self cost per file and per function for each phase
the bench marks. The report lands at `zig-out/bench-reports/<bench>-profile.md`
beside the callgrind parts, and `bench/README.md` says how to read it.

```sh
zig build profile-loam           # bench-loam's marked phases: the Tasks app's add, read, move, share and watch, the hot and cold reads, and the cold reads at scale; bench-loam's filters after -- (needs valgrind)
zig build profile-outbound       # bench-outbound's answered send and clone-only phases (needs valgrind)
zig build profile-dispatch-scaling # bench-dispatch-scaling's sequential and shuffled batches at each peer count (needs valgrind)
zig build profile-report-test    # the callgrind part reader behind the profile-* reports (part of check)
```
