---
type: static
description: The zig build steps of the library, its bindings, and its transports, grouped by what each proves.
sources:
  - resource: /build.zig
  - resource: /tools/build/
---

# glowcap: Build Steps

The `zig build` steps of the library, its bindings, and its transports, grouped
by what each proves. The applications, demos, and benchmarks have
[their own inventory](build-steps-apps.md). Run `zig build` from the repository
root: a run started in a subdirectory leaves its cache and output directories
there and resolves relative paths wrong.

Bare command rows describe the default host build graph. Generation and checks
use that reference graph even when invoked with build options. Configured
examples state their options separately. Gate membership can differ in those
configurations, such as the release packages that require optimized builds.

The aggregate checks divide evidence by the resources they own, as
[everyday steps](#everyday-steps-and-checks) lists. The side-effecting
commands in `runtime-check` take the build runner's execution lock and run
one at a time, so no proof shares the CPU with another while its deadline runs.

Build options:

- `-Dport=N` pins the listening TCP port for the demo and live interop steps.
  Demos default to an ephemeral port, and each interop step to the fixed port it
  documents. `goblins-handoff` runs two listeners and takes N and N+1.
- `-Dattach=true` joins an already-running server instead of spawning one. It
  works on demo steps that also take `-Dport`. `demo-accountability` rejects
  it, because each caller needs a fresh host.

[Developing Rooms](../apps/rooms/developing.md#build-steps) describes its transport
and hot-reload options. [Operating Rooms](../apps/rooms/operating.md) lists the
server flags passed after `--`. `rooms-dev` enables every operations capability.

To add a build step, follow [Contributing](../CONTRIBUTING.md#adding-a-build-step).

## Everyday steps and checks

```sh
zig build check                             # Run in-process Zig, static, generated, performance, and compile-time checks
zig build check-build                       # Compile everything check runs, so its deadline measures only the runs; part of check
zig build runtime-check                     # Run deterministic process, application, and language-workspace checks without cross-step contention
zig build runtime-check-build               # Compile everything runtime-check runs, so its deadline measures only the runs; part of runtime-check
zig build runtime-toolchain-check           # Check runtime gate declarations and installed tools before compiling its proofs; part of runtime-check
zig build runtime-check -Doptimize=ReleaseSafe # Run against CI's optimized product archives
zig build check-external                    # Run outside-authority protocol conformance and every shipped Rooms page browser proof (needs uv + racket + goblins + cargo + deno + Playwright)
zig build test                              # Run the unit and scenario test suite (test/all_test.zig); part of check
zig build test -Dtest-filter=substring # only tests whose names match
zig build test -Dtest-layer=engine,driver # compile and run only these test layers (the top-level test/ directories)
zig build check -Dcompile-only -Dcompile-shard=1/2 # compile the first of two slices of what check would run, and run nothing (CI build jobs)
zig build test-memcheck                     # Run the protocol core and actors tests under valgrind, built for the baseline CPU (-Dtest-filter narrows it)
zig build test-memcheck-build               # Compile the test-memcheck suite without running it; part of test-memcheck
zig build arch-check                        # Enforce the layer dependency DAG over src/; part of check
zig build source-check                      # Enforce formatting and cross-file source, generated, documentation, and scaffolding contracts; part of check
zig build infrastructure-check              # Run devcontainer, worktree, and agent hook behavior checks (needs bash, git, python3, jq, rustfmt, and deno)
zig build toolchain-check                   # Hold `zig build check` to the external runtimes it declares, and to their presence here; part of check
zig build loam-core-wasm-check              # Compile portable Loam record and transaction calls for 32-bit Wasm without LMDB; part of check-build
zig build loam-abi-test                     # Check Loam C ownership and atomic resource creation through atomic storage; part of check
zig build loam-browser-build                # Build the Loam Rust browser consumer and check its compiled Wasm contract (needs cargo + wasm-bindgen); part of loam-browser-test
zig build loam-browser-test                 # Prove Loam atomic browser storage, ownership, cancellation, sharing and cold restoration after page reload (needs deno + Playwright); part of check-external
zig build loam-rust-test                    # Prove Loam create/share/edit/restart/reopen and ownership through Rust (needs cargo); part of runtime-check
zig build loam-lmdb-test                    # Exercise Loam atomicity, bounded reads, and LMDB reopen recovery; part of check
zig build loam-sqlite-test                  # Run the durable Loam suite over SQLite and prove each commit refusal changed nothing; part of check
zig build loam-actors-crash-test            # Kill a CapTP actor turn around commit and restore callable cyclic capabilities, on every disk engine; part of runtime-check
zig build loam-references-crash-test        # Kill checked foreign reference writes and restore exact authority roles in fresh vats, on every disk engine; part of runtime-check
zig build loam-managed-crash-test           # Kill managed CapTP mutations around commit, installation, and reply delivery, on every disk engine; part of runtime-check
zig build loam-collection-crash-test        # Kill a tracing collection pass around commit and safely restart collection, on every disk engine; part of runtime-check
zig build loam-lmdb-compaction-crash-test   # Interrupt offline LMDB replacement and refuse duplicate owners and incomplete copies; part of runtime-check
zig build loam-sqlite-compaction-crash-test # Kill a SQLite vacuum mid-run and after it, then find every live row in a usable store; part of runtime-check
zig build loam-storage-crash-test           # Kill Loam writers before commit and after commit before local installation, on every disk engine (needs python3); part of runtime-check
zig build loam-io-fault-test                # Fail Linux writes, syncs and reads, and cut data files short, on both disk engines (needs python3); part of runtime-check
zig build oracle-check                      # Run the protocol oracle: message-arm coverage, Syrup corpus parity, and whole-conversation scenario traces (test/oracle_check.zig); part of check
zig build fmt                               # Format Zig sources in place (zig fmt)
zig build build                             # Build and install the glowcap C ABI archives; part of bench-capnp, bench-goblins, bench-interface, bench-interface-builds, bench-interface-diagnostics, bench-langs, bench-site-report, bindings-package-check, bun-test, check-build, demo-accountability, demo-rooms, demo-rooms-dm, demo-rooms-dm-back, demo-rooms-dm-iroh, demo-rooms-dm-iroh-discovery, demo-rooms-dm-reply, demo-rooms-iroh, demo-rooms-onion, demo-tasks, demo-tools, deno-gifter-handoff, deno-goblins-gift, deno-goblins-handoff, deno-goblins-interop, deno-goblins-listen, deno-iroh-handoff, deno-iroh-loop, deno-iroh-reachability, deno-iroh-redeem-posture, deno-keyed-relay-rendezvous, deno-keyed-tcp-restart, deno-noise-relay-listen, deno-relay-backpressure-test, deno-relay-idle-test, deno-relay-iroh-test, deno-relay-test, deno-test, deno-verb-spine, deno-webrtc-driver-provider, deno-wss-relay, glowcap-install, goblins-glowcap-pair-gift, goblins-handoff-iroh, goblins-iroh, goblins-relay, goblins-rooms, goblins-rooms-dm, goblins-rooms-dm-iroh, goblins-rooms-irc-bridge, goblins-rooms-iroh, goblins-rooms-matrix-iroh, goblins-rooms-peering, interface-authoring-check, interface-authoring-lint, interface-bench-lint, interface-conversation-check, interface-goblins-check, interface-test, iroh-abi-test, iroh-sidecar-test, loam-rust-test, ocapnviz-check, ocapnviz-live-browser, ocapnviz-test, profile-interface, python-goblins-gift, python-goblins-handoff, python-goblins-interop, python-goblins-listen, python-iroh-driver-provider, python-iroh-handoff, python-iroh-loop, python-iroh-reachability, python-iroh-redeem-posture, python-keyed-relay-rendezvous, python-keyed-tcp-restart, python-noise-relay-listen, python-relay-backpressure-test, python-relay-idle-test, python-relay-iroh-test, python-relay-test, python-test, python-verb-spine, python-webrtc-driver-provider, python-wss-relay, racket-goblins-gift, racket-goblins-handoff, racket-goblins-interop, racket-goblins-listen, racket-iroh-handoff, racket-iroh-loop, racket-iroh-reachability, racket-iroh-redeem-posture, racket-keyed-relay-rendezvous, racket-keyed-tcp-restart, racket-noise-relay-listen, racket-relay-backpressure-test, racket-relay-idle-test, racket-relay-iroh-test, racket-relay-test, racket-test, racket-verb-spine, racket-webrtc-driver-provider, racket-wss-relay, rooms-dev, rooms-dm-reredeem, rooms-session, rooms-terminal-client-test, rooms-web, rooms-web-relay-peer, rust-binding-lint, rust-goblins-gift, rust-goblins-handoff, rust-goblins-interop, rust-goblins-listen, rust-iroh-driver-provider, rust-iroh-handoff, rust-iroh-loop, rust-iroh-reachability, rust-iroh-redeem-posture, rust-keyed-relay-rendezvous, rust-keyed-tcp-restart, rust-noise-relay-listen, rust-relay-backpressure-test, rust-relay-idle-test, rust-relay-iroh-test, rust-relay-test, rust-verb-spine, rust-webrtc-driver-provider, rust-wss-relay, sidecar-runtime-test, site-rust-examples-check, tasks-mutation-check, web-peer-test, webrtc-sidecar-test, zig-keyed-relay-register, zig-keyed-relay-rendezvous
zig build fmt-check                         # Check Zig formatting without writing (zig fmt --check); part of source-check
zig build python-check                      # Check the formatting and lint of every first-party Python file with the pinned ruff; part of check-build, source-check
zig build python-fmt                        # Format every first-party Python file in place with the pinned ruff
zig build cli-test                          # Run the in-tree glowcap CLI registry and session/capture tests; part of check
zig build glowcap                           # Run the glowcap CapTP CLI; pass `-- <command> ...` (ocapn, repl, mcp, apps rooms session, and so on)
zig build examples                          # Build and run examples; part of check
zig build quick-start                       # Run the first Zig example: publish a greeter and call it over encrypted TCP
zig build consumer-check                    # Build a downstream package against the glowcap module (the README's fetch/import path); part of check-build
zig build cross-check                       # Type-check non-host targets, macOS/kqueue (full) and wasm32 (sans-io core), compile-only, and analyze the Zig tree in ReleaseFast; part of check
zig build perf-check                        # Gate ReleaseFast wall-clock cost: warm inbound dispatch and the outbound answered-send path against the ceilings in the bench files, plus the gc-storm linearity ratio; part of check
zig build fuzz                              # Mutation-fuzz every untrusted-input target (-Dfuzz-runs to change how long each one searches)
zig build fuzz-run                          # Fuzz worker: `zig build fuzz` drives this, or add --fuzz yourself for Zig's coverage UI
zig build timeout-runner-test               # Black-box the CI deadline wrapper: exit codes, relayed signal, no survivors (needs python3)
zig build c-abi-extract-check               # In-tree C-ABI extract hygiene matrix: refuse archive path escape/symlink, accept clean lib/ (ADR-0023); part of check
zig build ocapn-adoption-check              # Validate adopted, deferred, and pending draft and upstream suite accounting without claiming behavioral conformance; part of ocapn-conformance, ocapn-conformance-onion
zig build ocapn-findings-check              # Reproduce neutral protocol discrepancies across the pinned OCapN spec, suite, and Goblins sources; part of check-external
zig build ocapn-conformance-next            # Run manifest-selected upstream and local draft cases on negotiated next with the retained hello; part of check-external
zig build ocapn-conformance                 # Run portable upstream OCapN modules plus the strict abort probe against glowcap (needs uv + the ocapn-conformance submodule); part of ocapn-conformance-next
zig build fixture-gen-check                 # Regenerate Syrup fixtures via the upstream Racket Syrup encoder and diff against the committed corpus (needs racket + syrup); part of check-external
zig build gen-capnp-fixtures                # Regenerate Cap'n Proto golden fixtures under test/codec/capnp_fixtures/
zig build docs                              # Generate the Zig API reference (autodoc) under zig-out/docs/
zig build site                              # Build and validate the documentation site (Zine + autodoc) under zig-out/site/, with the Rooms page at rooms/app/: the website the pages workflow deploys (needs cargo + deno + wasm-bindgen + Playwright's Chromium)
zig build site-captures                     # Capture the Rooms pictures the website shows into site/assets from the shipped page (needs cargo + deno + a Playwright Chromium); part of site, site-render-check, site-tabs-check
zig build site-captures-rooms               # Capture the team room, direct line, IRC, operations, and shared-session pictures (needs cargo + deno + a Playwright Chromium); part of site-captures
zig build site-captures-directories         # Capture the three-directory session and its phone pictures (needs cargo + deno + a Playwright Chromium); part of site-captures
zig build site-rooms-page                   # Export the Rooms page into site/assets/rooms/app from the prepared browser generation, where the site and its preview serve it at /rooms/app/ with no Rooms server behind it (needs cargo + deno + wasm-bindgen); part of site, site-render-check, site-tabs-check
zig build site-render-check                 # Render every built site page at four widths in the pinned Chromium (fails on console errors, horizontal overflow, or widows) (needs deno + the image-baked browser)
zig build site-tabs-check                   # Press the code-tabs on every built site page in the pinned Chromium and prove each tab opens its own panel (needs deno + the image-baked browser)
zig build mycelium-test                     # Prove touch devices skip the background and desktop animation respects visibility, motion preferences and teardown (needs deno + Playwright); part of site-render-check
zig build site-serve                        # Serve the documentation site with Zine's development server, the Rooms page at /rooms/app/ included, and print its address (binds 0.0.0.0 in the devcontainer; regenerates site example tabs on start and while site/examples changes; prepares the Rooms pictures and page first only when site/assets lacks them, so run site-captures or site-rooms-page to refresh either)
zig build c-sdk-pack                        # Package and verify the C SDK (explicit Release mode and baseline CPU required)
zig build c-sdk-pack -Doptimize=ReleaseSafe -Dcpu=baseline # package the C SDK under zig-out/release/ and exercise extracted static/shared consumers (needs cargo; Debug and cross-target builds are refused)
zig build glowcap-install                   # Install the complete glowcap product and stage its deployment tree: CLI, Rooms runtimes, browser assets and skills (needs cargo + deno + wasm-bindgen); part of glowcap, glowcap-host-test, glowcap-install-test, runtime-check-build
zig build glowcap-release                   # Prepare the complete host product with ReleaseSafe and baseline CPU settings for installation or Linux deployment (needs cargo + deno + wasm-bindgen)
zig build glowcap-install-test              # Prove the source launcher serves Rooms after glowcap-install, with installed sessions, skills, and completion; part of runtime-check
zig build glowcap-host-test                 # Prove verified host installation and Docker deployment commands without a daemon (needs python3); part of runtime-check
zig build glowcap-pack                      # Package and exercise the complete relocatable glowcap product (explicit Release mode and baseline CPU required)
zig build glowcap-pack -Doptimize=ReleaseSafe -Dcpu=baseline # package the complete host product under zig-out/glowcap-release/; exercise extracted browser serving, HTTP bootstrap, iroh, rooms, DMs and restart (needs cargo + deno + wasm-bindgen + python3; Debug and cross-target builds are refused)
zig build glowcap-package-test              # Prove release rollback and reject damaged packages, broken skills, and loader fallbacks; part of check, infrastructure-check
zig build portable-pack                     # Package prebuilt browser JavaScript, Wasm, examples, and Rust Wasm archives; part of portable-package-test
zig build portable-package-test             # Run the extracted browser example and link a Rust Wasm consumer through the library downloader
zig build product-manifest-test             # Generate and parse a sealed staged product without a release package build; part of check
zig build set-version                       # Move every stated version to -Dversion=X.Y.Z: build.zig, the C ABI constants and header, build.zig.zon, the archive-resolution contract and its copies, every tracked package manifest and lock file, the pages that state the release version, and the generated header and binding constants, and dates the Unreleased changelog entries as the version's section
zig build mbedtls-build                     # Fetch by checksum, compile, and test Glowcap's private Mbed TLS engine (needs network)
```

## Formatting and lint outside the Zig tree

These steps need a non-Zig runtime on PATH, so they sit beside `check`.

```sh
zig build bindings-fmt          # Format the Rust crates and TypeScript bindings in place (needs cargo + deno)
zig build bindings-fmt-check    # Check Rust and TypeScript formatting, the lint and type-check for every TypeScript scope, and mypy over the Python binding (needs cargo + deno + mypy)
zig build rust-lint             # Lint every first-party Rust crate and target with Clippy (needs cargo); part of bindings-fmt-check
zig build ocapnviz-test         # Run the ocapnviz visualizer's own test suite (needs deno); part of runtime-check
zig build ocapnviz-check        # Check ocapnviz: types, formatting, lint, and its test suite (needs deno); part of runtime-check
zig build ocapnviz-live-browser # Build and prove production ocapnviz Live mode in Chromium (needs deno + Playwright Chromium)
zig build ocapnviz-fmt          # Format the ocapnviz sources in place (needs deno)
zig build ocapnviz-dev          # Serve ocapnviz from Vite for development; open the printed URL (needs deno)
```

## Interface contract fixtures

```sh
zig build gen-interface-fixtures       # Generate interface qualification projections from authored Syrup fixtures
zig build gen-interface-fixtures-check # Verify interface qualification projections match the authored Syrup fixtures; part of check
zig build interface-test               # Test bounded interface descriptions and generation allocation failures; part of check
zig build interface-goblins-check      # Prove generated recipient handoff and plain Goblins calling the generated Tasks server boundary (needs cargo + racket + Goblins + deno); part of check-external
zig build interface-conversation-check # Prove generated Tasks creation and Rust/TypeScript pending callback conversations (needs cargo + deno + python3); part of runtime-check
zig build interface-authoring-check    # Compare authored descriptions and prove a generated Cap'n Proto frontend call (needs capnp + cargo + python3); part of runtime-check
zig build interface-authoring-lint     # Lint the compiler-request adapter and its generated-call integration (needs capnp + cargo + python3); part of rust-lint
zig build interface-fixtures-check     # Verify authored interface contract and message fixtures; part of check
```

`interface-fixtures-check` checks the authored Syrup descriptions and
independent message fixtures with upstream Syrup. This is fixture integrity,
not compiler or interop qualification.
The Tasks server behavior remains covered by `tasks-app-test`. The creation
proof crosses the generated Rust client and Zig server, including input snapshot,
returned capability, pipelining, exact replay, and UTF-8 byte bounds.

## Generated headers and binding mirrors

Each `gen-*` step writes a committed mirror, and its `-check` sibling is part
of `check`, so a hand edit shows up as staleness.

```sh
zig build gen-header-ocapn                    # Regenerate include/glowcap_ocapn.h from src/c_abi/ocapn
zig build gen-header-ocapn-check              # Verify include/glowcap_ocapn.h matches src/c_abi/ocapn (fails if stale); part of check
zig build gen-header-locator                  # Regenerate include/glowcap_locator.h from c_abi/shared/locator.zig
zig build gen-header-locator-check            # Verify include/glowcap_locator.h matches the shared locator ABI (fails if stale); part of check
zig build gen-header-loam                     # Generate portable Loam header
zig build gen-header-loam-check               # Verify portable Loam header; part of check
zig build gen-header-loam-lmdb                # Generate LMDB Loam companion header
zig build gen-header-loam-lmdb-check          # Verify LMDB Loam companion header; part of check
zig build gen-header-loam-sqlite              # Generate SQLite Loam companion header
zig build gen-header-loam-sqlite-check        # Verify SQLite Loam companion header; part of check
zig build gen-header-loam-volatile            # Generate in-memory Loam companion header
zig build gen-header-loam-volatile-check      # Verify in-memory Loam companion header; part of check
zig build gen-binding-loam-layout             # Generate Rust Loam layouts and fingerprints
zig build gen-binding-loam-layout-check       # Verify reflected Rust Loam layouts and fingerprints; part of check
zig build gen-header-host                     # Regenerate include/glowcap_host.h from src/c_abi/host
zig build gen-header-host-check               # Verify include/glowcap_host.h matches src/c_abi/host (fails if stale); part of check
zig build gen-own-wire                        # Regenerate the own-wire fingerprint in src/ocapn/model/own_wire.zig from the Syrup and Cap'n Proto encoders
zig build gen-own-wire-check                  # Verify src/ocapn/model/own_wire.zig fingerprints what the encoders write (fails if stale); part of check
zig build gen-header-transport-provider       # Regenerate include/glowcap_transport_provider.h from c_abi/shared
zig build gen-header-transport-provider-check # Verify include/glowcap_transport_provider.h matches the shared provider ABI (fails if stale); part of check
zig build gen-header-driver                   # Regenerate include/glowcap_driver.h from src/c_abi/driver
zig build gen-header-driver-check             # Verify include/glowcap_driver.h matches src/c_abi/driver (fails if stale); part of check
zig build iroh-driver-provider                # Live proof (ADR-0024) that the driver archive dials a real iroh endpoint through the C multiplexed-transport table (needs cargo)
zig build iroh-managed                        # Zig Session and Server over real iroh: identity, fetch, call and accepted-session lifetime (needs cargo); part of iroh-driver-provider
```

The transport archives each carry their own header.

```sh
zig build gen-header-net-transport-tcp          # Regenerate include/glowcap_net_transport_tcp.h from src/c_abi/net_transport/tcp
zig build gen-header-net-transport-tcp-check    # Verify include/glowcap_net_transport_tcp.h matches src/c_abi/net_transport/tcp (fails if stale); part of check
zig build gen-header-net-transport-inproc       # Regenerate include/glowcap_net_transport_inproc.h from src/c_abi/net_transport/inproc
zig build gen-header-net-transport-inproc-check # Verify include/glowcap_net_transport_inproc.h matches src/c_abi/net_transport/inproc (fails if stale); part of check
zig build gen-header-net-transport-onion        # Regenerate include/glowcap_net_transport_onion.h from src/c_abi/net_transport/onion
zig build gen-header-net-transport-onion-check  # Verify include/glowcap_net_transport_onion.h matches src/c_abi/net_transport/onion (fails if stale); part of check
zig build gen-header-net-transport-iroh         # Regenerate include/glowcap_net_transport_iroh.h from src/c_abi/net_transport/iroh/mod.zig
zig build gen-header-net-transport-iroh-check   # Verify include/glowcap_net_transport_iroh.h matches src/c_abi/net_transport/iroh/mod.zig (fails if stale); part of check
zig build gen-iroh-sidecar-constants            # Regenerate the iroh sidecar's Rust constants from iroh transport policy and frame-stream policy
zig build gen-iroh-sidecar-constants-check      # Verify the iroh sidecar's generated Rust constants match iroh transport policy and frame-stream policy (fails if stale); part of check
zig build gen-header-net-transport-webrtc       # Regenerate include/glowcap_net_transport_webrtc.h from src/c_abi/net_transport/webrtc/mod.zig
zig build gen-header-net-transport-webrtc-check # Verify include/glowcap_net_transport_webrtc.h matches src/c_abi/net_transport/webrtc/mod.zig (fails if stale); part of check
zig build gen-webrtc-sidecar-constants          # Regenerate the WebRTC sidecar's Rust constants from src/net/transport/webrtc.zig
zig build gen-webrtc-sidecar-constants-check    # Verify the WebRTC sidecar's generated Rust constants match src/net/transport/webrtc.zig (fails if stale); part of check
zig build gen-header-net-transport-relay        # Regenerate include/glowcap_net_transport_relay.h from src/c_abi/net_transport/relay
zig build gen-header-net-transport-relay-check  # Verify include/glowcap_net_transport_relay.h matches src/c_abi/net_transport/relay (fails if stale); part of check
```

The bindings read the same facts out of generated mirrors.

```sh
zig build gen-ts-abi                    # Regenerate the TypeScript ABI mirror from src/c_abi (every reflected archive)
zig build gen-ts-abi-check              # Verify the generated TypeScript ABI mirror files match src/c_abi (fails if stale); part of check
zig build gen-site-examples             # Assemble site/examples snippets into SuperMD code-tabs on binding, Start, and transport pages; part of site-serve
zig build gen-site-examples-check       # Verify site transport example tabs match site/examples snippets (fails if stale); part of check
zig build gen-build-steps               # Rewrite every bare `zig build` row in docs/build-steps.md and docs/build-steps-apps.md from the build graph
zig build gen-build-steps-check         # Verify every bare `zig build` row in docs/build-steps.md and docs/build-steps-apps.md carries its step's description and containing steps, and every step has a row (fails if stale); part of source-check
zig build site-zig-examples-check       # Compile the authoritative Zig transport site examples; part of check
zig build site-ts-examples-check        # Type-check the authoritative TypeScript transport site examples; part of check-build
zig build site-python-examples-check    # Type-check the authoritative Python transport site examples (needs python3 + uv); part of bindings
zig build site-rust-examples-check      # Type-check the authoritative Rust transport site examples (needs python3 + cargo); part of bindings
zig build site-racket-examples-check    # Compile the authoritative Racket transport site examples (needs python3 + racket); part of bindings
zig build gen-binding-constants         # Regenerate binding ABI constants from src/c_abi (every reflected archive)
zig build gen-binding-constants-check   # Verify binding ABI constants match src/c_abi (fails if stale); part of check
zig build gen-binding-host-action       # Regenerate binding HostAction decode/types from src/c_abi/host
zig build gen-binding-host-action-check # Verify binding HostAction decode/types match src/c_abi/host (fails if stale); part of check
zig build gen-binding-rust-ffi          # Regenerate the Rust binding's extern blocks from src/c_abi (types reflected, names from the generated headers)
zig build gen-binding-rust-ffi-check    # Verify the generated Rust extern blocks match src/c_abi (fails if stale); part of check
zig build gen-binding-python-ffi        # Regenerate the Python binding's ctypes signature tables from src/c_abi (types are reflected and the sigs dicts are positional)
zig build gen-binding-python-ffi-check  # Verify the generated Python ctypes signature tables match src/c_abi (fails if stale); part of check
zig build gen-binding-racket-ffi        # Regenerate the Racket binding's FFI tables from src/c_abi (types reflected, wrapper argument names from the generated headers)
zig build gen-binding-racket-ffi-check  # Verify the generated Racket FFI tables match src/c_abi (fails if stale); part of check
zig build gen-binding-ffi-layouts       # Regenerate binding FFI layout facts from src/c_abi (every reflected archive); part of gen-rust-wasm-layouts
zig build gen-binding-ffi-layouts-check # Verify binding FFI layout facts match src/c_abi (fails if stale); part of gen-rust-wasm-layouts-check
zig build gen-rust-wasm-layouts         # Generate Rust layout constants and fingerprints from the compiled wasm32 C ABI
zig build gen-rust-wasm-layouts-check   # Verify Rust layout constants and fingerprints match the compiled wasm32 C ABI; part of check, rooms-browser-build, rooms-managed-rooms-browser-test, rooms-managed-sharing-browser-test, rooms-rust-contract-browser-test, rooms-session-executor-browser-test, rooms-session-foreign-browser-reload-test, rooms-session-foreign-browser-test, rooms-session-graph-browser-test
```

The Rooms application and terminal clients read their wire vocabulary from
generated tables. `tools/gen/rooms_protocol.zig` declares it,
`apps/rooms/lib/protocol.ts` documents it, and
`apps/rooms/test/protocol_gen_test.ts` checks them against the app's readers.

```sh
zig build gen-rooms-protocol       # Regenerate the Rooms application and client protocol tables from tools/gen/rooms_protocol.zig
zig build gen-rooms-protocol-check # Verify the Rooms application and client protocol tables match tools/gen/rooms_protocol.zig (fails if stale); part of check
zig build gen-agent-index          # Regenerate the agent scaffolding index from each rule, skill and hook
zig build gen-agent-index-check    # Verify the agent scaffolding index matches each rule, skill and hook (fails if stale or a file states no purpose); part of source-check
zig build gen-dependencies         # Regenerate docs/dependencies.md from the dep comments in every manifest
zig build gen-dependencies-check   # Verify docs/dependencies.md matches the dep comments in every manifest (fails if stale or a dependency has no comment); part of source-check
zig build gen-doc-values           # Rewrite every value a doc quotes from a code constant
zig build gen-doc-values-check     # Verify every value a doc quotes from a code constant is current (fails if stale or unreadable); part of source-check
zig build doc-impact               # List the docs that explain code changed since the fork from dev (or `-- <base>`)
```

The project's mark is defined once, as the WebGPU shader in `ui/mark/field.ts`,
and `tools/gen/mark/` traces every still picture of it from a render of that
shader. These two steps run the pinned headless Chromium. `zig build
source-check` covers the half that needs no browser: it holds the committed
files to one geometry, so a hand edit to any of them fails in-tree.

```sh
zig build gen-mark       # Re-trace the still mark from the shader and rewrite the unlit and lit artwork under site/assets/ with their rasters, plus the mark's generated blocks in ui/ (needs deno + the image-baked browser)
zig build gen-mark-check # Verify the committed still mark still matches a fresh trace of the shader (fails if stale)
```

## C ABI consumers

Each binding exercises the C ABI as a consumer. These steps prove the ABI is
consumable and decide no Zig semantics.

```sh
zig build bindings               # Run every binding's test suite and verify the published examples (rust, deno, bun, python, racket)
zig build bindings-package-check # Build and exercise detached Rust, Python and Racket packages and dry-run JSR publication (needs cargo, uv, racket and deno)
zig build rust-test              # Run the Rust binding's tests against the installed C ABI archives (needs cargo); part of bindings, bindings-onion
zig build rust-binding-lint      # Lint the Rust binding library, tests, and examples with Clippy (needs cargo); part of rust-lint, rust-test
zig build deno-test              # Run the TypeScript binding's test suite on Deno against the installed C ABI archives (needs deno); part of bindings
zig build bun-test               # Run the TypeScript binding's test suite on Bun, the same binding as Deno (needs bun); part of bindings
zig build python-test            # Run the Python binding's test suite and unit tests against the installed C ABI archives (needs python3); part of bindings, bindings-onion
zig build racket-test            # Run the Racket binding's test suite and every Racket module's unit tests (needs racket + goblins); part of bindings, bindings-onion
zig build iroh-abi               # Build libglowcap_net_transport_iroh, the iroh transport's public C ABI companion (needs cargo); part of bench-rooms-admission, bindings-package-check, bun-test, deno-iroh-handoff, deno-iroh-loop, deno-iroh-reachability, deno-iroh-redeem-posture, deno-relay-iroh-test, deno-test, goblins-handoff-iroh, goblins-iroh, python-iroh-driver-provider, python-iroh-handoff, python-iroh-loop, python-iroh-reachability, python-iroh-redeem-posture, python-relay-iroh-test, python-test, racket-iroh-handoff, racket-iroh-loop, racket-iroh-reachability, racket-iroh-redeem-posture, racket-relay-iroh-test, racket-test, rooms-browser-test, rooms-chat-build, rooms-irc-bridge-build, rooms-irc-server-build, rooms-managed-rooms-browser-test, rooms-managed-sharing-browser-test, rooms-rust-browser-host-test, rooms-server-build, rooms-session-build, rooms-session-foreign-test, rust-iroh-driver-provider, rust-iroh-handoff, rust-iroh-loop, rust-iroh-reachability, rust-iroh-redeem-posture, rust-relay-iroh-test
zig build iroh-abi-test          # Test the iroh C ABI and generic-driver listener adoption (needs cargo + deno); part of bindings
zig build webrtc-abi             # Build libglowcap_net_transport_webrtc, the WebRTC transport's public C ABI companion (ADR-0035, needs cargo); part of bench-rooms-admission, bindings-package-check, deno-webrtc-driver-provider, python-webrtc-driver-provider, racket-webrtc-driver-provider, rooms-browser-test, rooms-chat-build, rooms-irc-bridge-build, rooms-irc-server-build, rooms-managed-rooms-browser-test, rooms-managed-sharing-browser-test, rooms-rust-browser-host-test, rooms-server-build, rooms-session-build, rooms-session-foreign-test, rust-webrtc-driver-provider
```

Each in-tree proof family runs one scenario once per binding, with glowcap on
every side. The `bindings-*` step runs the whole family.

```sh
zig build bindings-keyed-tcp-restart   # Per-binding keyed-tcp restart proof: happy path, squatter refusal, same-seed fresh-port restart, every binding
zig build deno-keyed-tcp-restart       # Keyed-tcp restart proof: the Deno binding (happy, squatter, restart); part of bindings-keyed-tcp-restart
zig build python-keyed-tcp-restart     # Keyed-tcp restart proof: the Python binding (happy, squatter, restart); part of bindings-keyed-tcp-restart
zig build rust-keyed-tcp-restart       # Keyed-tcp restart proof: the Rust binding (happy, squatter, and restart cases, needs cargo); part of bindings-keyed-tcp-restart
zig build racket-keyed-tcp-restart     # Keyed-tcp restart proof: the Racket binding (happy, squatter, and restart cases, needs racket); part of bindings-keyed-tcp-restart
zig build bindings-iroh-redeem-posture # Per-binding in-tree proof that a configured redeem posture governs a hint-less iroh give, every binding (needs cargo + the runtimes)
zig build deno-iroh-redeem-posture     # In-tree configured-redeem-posture proof for a hint-less iroh give: the Deno binding (needs cargo + deno); part of bindings-iroh-redeem-posture
zig build python-iroh-redeem-posture   # In-tree configured-redeem-posture proof for a hint-less iroh give: the Python binding (needs cargo + python3); part of bindings-iroh-redeem-posture
zig build rust-iroh-redeem-posture     # In-tree configured-redeem-posture proof for a hint-less iroh give: the Rust binding (needs cargo); part of bindings-iroh-redeem-posture
zig build racket-iroh-redeem-posture   # In-tree configured-redeem-posture proof for a hint-less iroh give: the Racket binding (needs cargo + racket); part of bindings-iroh-redeem-posture
zig build bindings-verb-spine          # Per-binding verb-spine behavior proof: each binding walks promise, dial, listen, and GC end to end against one fixed peer over loopback TCP (needs deno + the runtimes)
zig build deno-verb-spine              # Verb-spine behavior proof: the Deno binding walks promise, dial, listen, and GC against one fixed peer (needs deno); part of bindings-verb-spine
zig build python-verb-spine            # Verb-spine behavior proof: the Python binding walks promise, dial, listen, and GC against one fixed peer (needs deno + uv); part of bindings-verb-spine
zig build rust-verb-spine              # Verb-spine behavior proof: the Rust binding walks promise, dial, listen, and GC against one fixed peer (needs deno + cargo); part of bindings-verb-spine
zig build racket-verb-spine            # Verb-spine behavior proof: the Racket binding walks promise, dial, listen, and GC against one fixed peer (needs deno + racket); part of bindings-verb-spine
zig build deno-gifter-handoff          # Glowcap-only 3-node three-party handoff: a broker introduces a recipient to an exporter, who is then messaged directly (needs deno)
```

## Live Goblins interop

The live wire authority. Each step talks to a real Spritely Goblins vat.

```sh
zig build goblins-interop           # Live OCapN conversation vs a real Goblins vat, both directions (needs racket + goblins); part of check-external
zig build goblins-differential      # Compare accept or refuse per mutated frame between glowcap and a live Goblins vat (needs racket + goblins)
zig build goblins-handoff           # Live three-party handoff vs Goblins, glowcap as recipient (needs racket + goblins); part of check-external
zig build goblins-gift              # Live three-party handoff vs Goblins, glowcap as gifter (needs racket + goblins); part of check-external
zig build goblins-exporter          # Live three-party handoff vs Goblins, glowcap as exporter (needs racket + goblins); part of check-external
zig build goblins-relayed-give      # Live relayed give vs Goblins: a give reaches a real Goblins recipient in a listener fire (needs racket + goblins); part of check-external
zig build goblins-listen-recipient  # Live Goblins promise recipient: Session.listenTo observes a later settlement containing a callable capability (needs racket + goblins); part of check-external
zig build goblins-glowcap-pair-gift # Live three-party handoff with two glowcap vats and one Goblins vat: the glowcap pair holds a glowcap-next Cap'n Proto session while both Goblins sessions settle on the v1.0 Syrup baseline, and the give crosses that split (needs racket + goblins); part of check-external
zig build goblins-gift-hints        # Live hinted-locator handoff vs Goblins: an opaque route hint survives decode, re-encode, and signature verification (needs racket + goblins); part of check-external
zig build goblins-gc                # Live Goblins GC in both directions, including remote reclamation after capability and answer release with the Session open (needs racket + goblins)
zig build goblins-handoff-iroh      # Live encrypted handoff: Goblins gifts and exports, a glowcap Session redeems directly over iroh (needs cargo + racket + goblins)
zig build goblins-rooms-peering     # Live Goblins through Rooms Peering: enter a glowcap foreign listing over v1.0/Syrup, revoke discovery, and keep using the handed room (needs deno + racket + goblins)
zig build goblins-iroh              # Live Goblins over iroh: a real Goblins vat and a glowcap peer hold OCapN sessions over encrypted QUIC, both directions, through the iroh netlayer this repository wrote for Goblins (needs cargo + racket + goblins)
zig build goblins-rooms             # Live Goblins in the rooms chat: a real Goblins vat and a glowcap peer hold one room, each on the profile its own session settled (needs deno + racket + goblins)
zig build goblins-rooms-irc         # Run both live Goblins compositions for the shipped IRC bridge and IRC server (needs deno + racket + goblins)
zig build goblins-rooms-irc-bridge  # Live Goblins through the IRC bridge: fixture IRC and a real vat exchange room lines both ways (needs deno + racket + goblins); part of goblins-rooms-irc, goblins-rooms-irc-server
zig build goblins-rooms-irc-server  # Live Goblins through the IRC server: channel traffic both ways, then IRC initiates a DM and Goblins replies on that session (needs deno + racket + goblins)
zig build goblins-rooms-iroh        # Live Goblins in the rooms chat over iroh's encrypted QUIC: the accepting side records the endpoint id QUIC authenticated (needs cargo + deno + racket + goblins)
zig build goblins-rooms-dm          # Live Goblins direct message, both directions: a browser tab redeems a room introduction and reaches a real Goblins vat off-room over cleartext TCP, the vat answers over that same connection, and the vat starts a direct message of its own by redeeming a give that names a Rooms session process member as its exporter (needs deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-dm-iroh     # Live Goblins direct messages both ways over encrypted iroh QUIC: the browser redeems the vat's introduction, then the vat redeems a session process member's, with authenticated endpoint testimony (needs cargo + deno + racket + goblins + a Playwright Chromium)
zig build goblins-rooms-matrix-iroh # Heavy four-peer rooms matrix: pin Goblins' cross-receiver count defect, then exercise mixed and homogeneous rooms, every DM pair, close/reopen, and peer restart over iroh
zig build goblins-relay             # Live Goblins through the byte-transparent relay: a browser peer holds a keyed OCapN session with a real Goblins vat through the Deno reference relay (needs deno + racket + goblins)
zig build bindings-goblins-interop  # Live keyed conversation vs a real Goblins vat through Deno, Python, Rust, and Racket bindings (needs racket + goblins + the runtimes)
zig build deno-goblins-interop      # Live keyed OCapN conversation: Deno binding vs a real Goblins vat (needs deno + racket + goblins); part of bindings-goblins-interop
zig build python-goblins-interop    # Live keyed OCapN conversation: Python binding vs a real Goblins vat (needs python3 + racket + goblins); part of bindings-goblins-interop
zig build rust-goblins-interop      # Live keyed OCapN conversation: Rust binding vs a real Goblins vat (needs cargo + racket + goblins); part of bindings-goblins-interop
zig build racket-goblins-interop    # Live keyed OCapN conversation: Racket binding vs a real Goblins vat (needs racket + goblins); part of bindings-goblins-interop
zig build bindings-goblins-listen   # Live listener conversation: a real Goblins vat dials and calls Deno, Python, Rust, and Racket binding hosts (needs deno + racket + goblins + the runtimes)
zig build deno-goblins-listen       # Live listener conversation: Goblins dials, enlivens, and calls a Deno binding host (needs deno + racket + goblins); part of bindings-goblins-listen
zig build python-goblins-listen     # Live listener conversation: Goblins dials, enlivens, and calls a Python binding host (needs deno + uv + racket + goblins); part of bindings-goblins-listen
zig build rust-goblins-listen       # Live listener conversation: Goblins dials, enlivens, and calls a Rust binding host (needs deno + cargo + racket + goblins); part of bindings-goblins-listen
zig build racket-goblins-listen     # Live listener conversation: Goblins dials, enlivens, and calls a Racket binding host (needs deno + racket + goblins); part of bindings-goblins-listen
zig build bindings-goblins-handoff  # Three-party handoff through Deno, Python, Rust, and Racket bindings as recipient (needs racket + goblins + the runtimes)
zig build deno-goblins-handoff      # Live three-party handoff: the Deno binding redeems a give from a real Goblins introducer and calls the exporter (needs deno + racket + goblins); part of bindings-goblins-handoff
zig build python-goblins-handoff    # Live three-party handoff: the Python binding redeems a give from a real Goblins introducer and calls the exporter (needs python3 + racket + goblins); part of bindings-goblins-handoff
zig build rust-goblins-handoff      # Live three-party handoff: the Rust binding redeems a give from a real Goblins introducer and calls the exporter (needs cargo + racket + goblins); part of bindings-goblins-handoff
zig build racket-goblins-handoff    # Live three-party handoff: the Racket binding redeems a give from a real Goblins introducer and calls the exporter (needs racket + goblins); part of bindings-goblins-handoff
zig build bindings-goblins-gift     # Three-party handoff through Deno, Python, Rust, and Racket bindings as gifter (needs racket + goblins + the runtimes)
zig build deno-goblins-gift         # Live three-party handoff: the Deno binding mints a give a real Goblins recipient redeems, reaching the exporter (needs deno + racket + goblins); part of bindings-goblins-gift
zig build python-goblins-gift       # Live three-party handoff: the Python binding mints a give a real Goblins recipient redeems, reaching the exporter (needs python3 + racket + goblins); part of bindings-goblins-gift
zig build rust-goblins-gift         # Live three-party handoff: the Rust binding mints a give a real Goblins recipient redeems, reaching the exporter (needs cargo + racket + goblins); part of bindings-goblins-gift
zig build racket-goblins-gift       # Live three-party handoff: the Racket binding mints a give a real Goblins recipient redeems, reaching the exporter (needs racket + goblins); part of bindings-goblins-gift
```

## The shared sidecar runtime

The iroh and WebRTC sidecars are Rust crates behind a C ABI. They share
`transports/sidecar-runtime`: the private Tokio runtime a C call runs on, the
release barrier for tasks that outlive their handle, and the self-pipe
readiness channel. Each sidecar's cargo steps build it by path.

```sh
zig build sidecar-runtime-test # Run the Rust unit tests of the runtime plumbing both transport sidecars share: private-runtime calls from inside an ambient runtime and the task barrier (needs cargo)
```

## The iroh transport

```sh
zig build iroh-sidecar-build              # Build the iroh netlayer sidecar staticlib (needs cargo)
zig build iroh-sidecar-test               # Run the iroh sidecar Rust unit tests, including the connect-timeout positive-fire proof (needs cargo)
zig build iroh-session                    # Live encrypted OCapN conversation: two glowcap peers over real iroh endpoints (needs cargo)
zig build iroh-loop                       # Live iroh scale: many concurrent connections served from one Server thread (ADR-0019, needs cargo)
zig build iroh-redeem                     # Live three-party redeem over iroh: a recipient Session dials the exporter by node id inside the introducing call (needs cargo)
zig build tcp-loop                        # Live TCP scale: many concurrent connections served from one Server thread
zig build iroh-reachability               # Live real-internet dial-by-id over n0 relays + DNS/pkarr discovery (opt-in; needs cargo + internet)
zig build bindings-iroh-loop              # Per-binding iroh scale proof: many connections served from one loop, every binding (needs cargo + the runtimes)
zig build deno-iroh-loop                  # Live iroh scale: the Deno binding serves many connections from one readiness loop (ADR-0019, needs cargo + deno); part of bindings-iroh-loop
zig build python-iroh-loop                # Live iroh scale: the Python binding serves many connections from one readiness loop (ADR-0019, needs cargo + python3); part of bindings-iroh-loop
zig build python-iroh-driver-provider     # Live ADR-0024 Python parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the C multiplexed-transport table (needs cargo + python3); part of bindings-iroh-loop
zig build rust-iroh-driver-provider       # Live ADR-0024 Rust parity: the byte-fed iroh surface serves while the driver archive dials the same endpoint through the C multiplexed-transport table (needs cargo); part of bindings-iroh-loop
zig build bindings-webrtc-driver-provider # Live WebRTC through the C provider: every binding dials the Zig answerer and accepts the Zig offerer with its own signaling (ADR-0035) (needs cargo + deno + python3 + racket)
zig build deno-webrtc-driver-provider     # Live Deno WebRTC: the Deno binding dials the Zig answerer and accepts the Zig offerer, both through the C provider with its own signaling (ADR-0035, needs cargo + deno); part of bindings-webrtc-driver-provider
zig build python-webrtc-driver-provider   # Live Python WebRTC: the Python binding dials the Zig answerer and accepts the Zig offerer, both through the C provider with its own signaling (ADR-0035, needs cargo + python3); part of bindings-webrtc-driver-provider
zig build rust-webrtc-driver-provider     # Live Rust WebRTC: the Rust binding dials the Zig answerer, accepts the Zig offerer, and dials from a listening Host, all through the C provider with its own signaling, after its in-tree adapter tests (ADR-0035, needs cargo); part of bindings-webrtc-driver-provider
zig build racket-webrtc-driver-provider   # Live Racket WebRTC: the Racket binding dials the Zig answerer and accepts the Zig offerer, both through the C provider with its own signaling (ADR-0035, needs cargo + racket); part of bindings-webrtc-driver-provider
zig build rust-iroh-loop                  # Live iroh scale: the Rust binding serves many connections from one readiness loop (ADR-0019, needs cargo); part of bindings-iroh-loop
zig build racket-iroh-loop                # Live iroh scale: the Racket binding serves many connections from one readiness loop (ADR-0019, needs cargo + racket); part of bindings-iroh-loop
zig build bindings-iroh-handoff           # Per-binding three-party handoff over iroh: every binding mints and redeems an iroh handoff give in one process (needs cargo + the runtimes)
zig build deno-iroh-handoff               # Three-party handoff over iroh: the Deno binding mints and redeems an iroh handoff give in one process (needs cargo + deno); part of bindings-iroh-handoff
zig build python-iroh-handoff             # Three-party handoff over iroh: the Python binding mints and redeems an iroh handoff give in one process (needs cargo + python3); part of bindings-iroh-handoff
zig build rust-iroh-handoff               # Three-party handoff over iroh: the Rust binding mints and redeems an iroh handoff give in one process (needs cargo); part of bindings-iroh-handoff
zig build racket-iroh-handoff             # Three-party handoff over iroh: the Racket binding mints and redeems an iroh handoff give in one process (needs cargo + racket); part of bindings-iroh-handoff
zig build bindings-iroh-reachability      # Per-binding live dial-by-id over n0 relays + DNS/pkarr discovery, every binding (opt-in; needs cargo + the runtimes + internet)
zig build deno-iroh-reachability          # Live dial-by-id over n0 relays + DNS/pkarr discovery: the Deno binding (opt-in; needs cargo + deno + internet); part of bindings-iroh-reachability
zig build python-iroh-reachability        # Live dial-by-id over n0 relays + DNS/pkarr discovery: the Python binding (opt-in; needs cargo + python3 + internet); part of bindings-iroh-reachability
zig build rust-iroh-reachability          # Live dial-by-id over n0 relays + DNS/pkarr discovery: the Rust binding (opt-in; needs cargo + internet); part of bindings-iroh-reachability
zig build racket-iroh-reachability        # Live dial-by-id over n0 relays + DNS/pkarr discovery: the Racket binding (opt-in; needs cargo + racket + internet); part of bindings-iroh-reachability
```

## The WebRTC transport

The WebRTC transport ([ADR-0035](decisions/adr/ADR-0035-webrtc-exchanges.md)).

```sh
zig build webrtc-sidecar-build      # Build the WebRTC DataChannel netlayer sidecar staticlib and probe binary (ADR-0035, needs cargo); part of webrtc-datachannel-test
zig build webrtc-sidecar-test       # Run the WebRTC sidecar Rust unit tests, including the inbound backpressure proof (needs cargo)
zig build webrtc-datachannel-test   # Prove a headless Chromium RTCDataChannel carries bytes both directions to a Rust webrtc-crate peer on loopback (ADR-0035, needs cargo + deno + a Playwright Chromium)
zig build webrtc-resident-check     # Type-check the WebRTC DataChannel netlayer resident (ADR-0035), compile-only, no cargo; part of check-build
zig build webrtc-internal-test      # Run WebRTC resident ownership, bounded-signaling, managed-dial, and managed-accept tests against a scripted sidecar; part of check
zig build webrtc-session            # Live WebRTC: two Zig glowcap peers hold a keyed OCapN session over a real DataChannel (ADR-0035, needs cargo)
zig build webrtc-loop               # Live WebRTC scale: many concurrent DataChannels, each answered by the completion backend and served from one HostRuntime thread with the client's identity proved (ADR-0035, ADR-0018, needs cargo)
zig build webrtc-redeem             # Live three-party handoff over WebRTC: a recipient Session redeems a bare webrtc give through its signaling authority, and every exporter's backend answers the offer itself (ADR-0035, needs cargo)
zig build webrtc-driver-provider    # Live WebRTC C-provider proof: the generic C driver dials and listens through the WebRTC provider's signaling callbacks, the offer is handed in with provide_offer, and releasing the loop cancels a dial still in flight (needs cargo)
zig build webrtc-mesh               # Live WebRTC signaling mesh: two Zig peers bring up a DataChannel through an OCapN signaling hub, then hold a keyed session (ADR-0035, needs cargo)
zig build webrtc-signaling-captp    # Live WebRTC signaling capability over CapTP: signaling opens the DataChannel, then the keyed session runs over it (ADR-0035, needs cargo)
zig build webrtc-answerer           # Build the Zig answerer the webrtc-browser-peer proof and the binding dial proofs reach (ADR-0035, needs cargo); part of deno-webrtc-driver-provider, python-webrtc-driver-provider, racket-webrtc-driver-provider, rust-webrtc-driver-provider, webrtc-browser-peer
zig build webrtc-offerer            # Build the Zig offerer the binding listen proofs accept (ADR-0035, needs cargo); part of deno-webrtc-driver-provider, python-webrtc-driver-provider, racket-webrtc-driver-provider, rust-webrtc-driver-provider
zig build webrtc-browser-peer       # Prove a real headless Chromium runs @glowcap/web + @glowcap/webrtc: a DataChannel to the Zig answerer carries a keyed OCapN session (ADR-0035, needs cargo + deno + a Playwright Chromium)
zig build webrtc-browser-to-browser # Prove two real headless Chromium peers hold a keyed OCapN session over a direct WebRTC DataChannel, one dialing through the WebRTC connector and the other accepting through the WebRTC listener, the signaling host out of the byte path (ADR-0035, needs deno + a Playwright Chromium)
```

## The onion transport

`onion` is the netlayer the OCapN draft standardizes and upstream Spritely
Goblins ships. Everything that exercises it inside `zig build check`, plus the
focused loop and binding checks, drives a fake daemon on loopback and needs
neither Tor nor the network. The live steps need `tor` on `PATH` and outbound
network access. In the conformance step, glowcap uses operator-supplied control
and SOCKS endpoints and the pinned upstream netlayer starts a separate Tor.

```sh
zig build onion-loop-test           # Run the focused Zig OnionLoop completion tests
zig build onion-pending-listen-test # Run the onion pending-listen resident tests over the fake daemon; part of runtime-check
zig build bindings-onion            # Run the onion provider proof in every language binding (needs cargo + deno + python3 + racket)
zig build onion-session             # Live Tor: two glowcap peers hold an OCapN conversation over a real onion service (needs tor + network)
zig build goblins-onion             # Live Goblins over Tor: a real Goblins vat and a glowcap peer hold OCapN sessions over hidden service circuits, both directions (needs tor + network + racket + goblins)
zig build ocapn-conformance-onion   # Run the upstream OCapN suite against glowcap over an operator-supplied Tor (needs uv + external Tor + network)
zig build demo-rooms-onion          # Run the Rooms application over real Tor with one onion service and two independent peers (needs deno + tor + network)
```

## The browser peer and the relays

```sh
zig build wasm-host             # Build the browser binding's freestanding wasm32 Host module (ADR-0034) into zig-out/wasm/; part of build, gen-rust-wasm-layouts, gen-rust-wasm-layouts-check, install, loam-browser-build, ocapnviz-dev, portable-pack, wasm-abi-layout-check, wasm-host-test, wasm-import-check, webrtc-browser-peer, webrtc-browser-to-browser
zig build wasm-archives         # Build freestanding Host, OCapN, and Loam static archives for Wasm application linking; part of loam-browser-build, portable-pack, rooms-browser-build, rooms-managed-rooms-browser-test, rooms-managed-sharing-browser-test, rooms-rust-contract-browser-test, rooms-rust-lint, rooms-session-executor-browser-test, rooms-session-foreign-browser-reload-test, rooms-session-foreign-browser-test, rooms-session-graph-browser-test
zig build wasm-host-test        # Prove the wasm32 Host handshakes and checks sturdyref peer authority from JS (needs deno, ADR-0034 and ADR-0007)
zig build wasm-abi-layout-check # Prove the wasm32 Host's layout descriptor (glowcap_wasm_abi_layout) decodes cleanly and agrees with the abi.ts field counts (needs deno, ADR-0034)
zig build wasm-import-check     # Prove the wasm32 Host imports exactly its behavior and hosted-retirement callbacks (needs deno, ADR-0034)
zig build web-peer-test         # Prove @glowcap/web holds keyed WebSocket and sealed Noise-relay sessions with Zig peers (needs deno + Playwright, ADR-0034 and ADR-0041)
```

ADR-0033 holds every runtime's relay to one shared harness: TCP forwarding,
the backpressure clause, and the idle-timeout bounded-resources clause.

```sh
zig build bindings-relay                  # Prove the byte-transparent relay contract (TCP forwarding + backpressure + the idle-timeout bounded-resources clause) across every runtime's relay: Deno, Python, Rust, Racket (needs deno + uv + cargo + racket)
zig build bindings-wss-relay              # Per-binding WSS relay success and exact TLS refusal projection through one local CA fixture (needs deno + uv + cargo + racket)
zig build bindings-relay-iroh             # Prove the relay's iroh leg across every runtime's relay: a browser peer holds a live iroh session through Deno, Python, Rust, Racket relays (needs deno + uv + cargo + racket)
zig build deno-relay-test                 # Prove a browser peer holds a keyed session through the Deno reference relay (needs deno); part of bindings-relay
zig build python-relay-test               # Prove a browser peer holds a keyed session through the Python relay (needs deno + uv); part of bindings-relay
zig build rust-relay-test                 # Prove a browser peer holds a keyed session through the Rust relay (needs deno + cargo); part of bindings-relay
zig build racket-relay-test               # Prove a browser peer holds a keyed session through the Racket relay (net/rfc6455) (needs deno + racket); part of bindings-relay
zig build deno-relay-backpressure-test    # Prove a stalled reader backpressures the far sender through the Deno relay (needs deno); part of bindings-relay
zig build python-relay-backpressure-test  # Prove a stalled reader backpressures the far sender through the Python relay (needs deno + uv); part of bindings-relay
zig build rust-relay-backpressure-test    # Prove a stalled reader backpressures the far sender through the Rust relay (needs deno + cargo); part of bindings-relay
zig build racket-relay-backpressure-test  # Prove a stalled reader backpressures the far sender through the Racket relay (needs deno + racket); part of bindings-relay
zig build deno-relay-idle-test            # Prove the Deno relay reclaims an idle session (the bounded-resources clause) (needs deno); part of bindings-relay
zig build python-relay-idle-test          # Prove the Python relay reclaims an idle session (the bounded-resources clause) (needs deno + uv); part of bindings-relay
zig build rust-relay-idle-test            # Prove the Rust relay reclaims an idle session (the bounded-resources clause) (needs deno + cargo); part of bindings-relay
zig build racket-relay-idle-test          # Prove the Racket relay reclaims an idle session (the bounded-resources clause) (needs deno + racket); part of bindings-relay
zig build deno-relay-iroh-test            # Prove a browser peer holds a live iroh session through the Deno reference relay (needs deno + cargo); part of bindings-relay-iroh
zig build python-relay-iroh-test          # Prove a browser peer holds a live iroh session through the Python relay (needs deno + uv + cargo); part of bindings-relay-iroh
zig build rust-relay-iroh-test            # Prove a browser peer holds a live iroh session through the Rust relay (needs deno + cargo); part of bindings-relay-iroh
zig build racket-relay-iroh-test          # Prove a browser peer holds a live iroh session through the Racket relay, dialing iroh via the binding's dial-locator-for-relay (needs deno + cargo + racket); part of bindings-relay-iroh
zig build bindings-keyed-relay-rendezvous # Per-consumer keyed-relay rendezvous cold-dial proof: each language binding and the Zig CLI dial a registered non-listening peer through the reference relay's rendezvous bridge (needs deno + the runtimes)
zig build deno-keyed-relay-rendezvous     # Keyed-relay rendezvous cold-dial proof: the Deno binding dials a registered peer through the reference relay (needs deno); part of bindings-keyed-relay-rendezvous
zig build python-keyed-relay-rendezvous   # Keyed-relay rendezvous cold-dial proof: the Python binding dials a registered peer through the reference relay (needs deno + uv); part of bindings-keyed-relay-rendezvous
zig build rust-keyed-relay-rendezvous     # Keyed-relay rendezvous cold-dial proof: the Rust binding dials a registered peer through the reference relay (needs deno + cargo); part of bindings-keyed-relay-rendezvous
zig build racket-keyed-relay-rendezvous   # Keyed-relay rendezvous cold-dial proof: the Racket binding dials a registered peer through the reference relay (needs deno + racket); part of bindings-keyed-relay-rendezvous
zig build bindings-noise-relay-listen     # Per-binding managed noise-relay listen proof: each binding registers a durable key at the reference relay, advertises its locator, and serves a sealed session dialed by one fixed client (needs deno + the runtimes)
zig build deno-noise-relay-listen         # Noise-relay managed-listen proof: the Deno binding registers, advertises, and serves a sealed session (needs deno); part of bindings-noise-relay-listen
zig build python-noise-relay-listen       # Noise-relay managed-listen proof: the Python binding registers, advertises, and serves a sealed session (needs deno + uv); part of bindings-noise-relay-listen
zig build rust-noise-relay-listen         # Noise-relay managed-listen proof: the Rust binding registers, advertises, and serves a sealed session (needs deno + cargo); part of bindings-noise-relay-listen
zig build racket-noise-relay-listen       # Noise-relay managed-listen proof: the Racket binding registers, advertises, and serves a sealed session (needs deno + racket); part of bindings-noise-relay-listen
zig build deno-wss-relay                  # WSS relay success and exact TLS refusals through the Deno binding (needs deno); part of bindings-wss-relay
zig build python-wss-relay                # WSS relay success and exact TLS refusals through the Python binding (needs deno + uv); part of bindings-wss-relay
zig build rust-wss-relay                  # WSS relay success and exact TLS refusals through the Rust binding (needs deno + cargo); part of bindings-wss-relay
zig build racket-wss-relay                # WSS relay success and exact TLS refusals through the Racket binding (needs deno + racket); part of bindings-wss-relay
zig build zig-keyed-relay-rendezvous      # Keyed-relay rendezvous cold-dial proof: the Zig glowcap CLI dials a registered peer through the reference relay via GLOWCAP_RENDEZVOUS (needs deno); part of bindings-keyed-relay-rendezvous
zig build zig-keyed-relay-register        # Keyed-relay register proof: the Zig glowcap CLI registers at the reference relay (no listening socket) and answers a cold dial (needs deno); part of bindings-keyed-relay-rendezvous
```
