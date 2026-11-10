---
type: static
description: The zig build steps of the applications, demos, and benchmarks glowcap ships, grouped by what each proves.
sources:
  - resource: /build.zig
  - resource: /tools/build/
---

# glowcap: Application Build Steps

The `zig build` steps of the applications, demos, and benchmarks built on the
library, grouped by what each proves. [Build steps](build-steps.md) lists the
library's own steps, says how to run one, and names the build options the demos
take.

## Applications and demos

The applications glowcap ships, and cross-language demos with several runtimes
in one conversation.

```sh
zig build demo-rooms                                # Run the cross-language rooms chat demo (needs deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-iroh                           # Run the cross-language rooms demo over iroh's encrypted QUIC (needs cargo + deno; joins python3/racket/cargo clients when present)
zig build demo-rooms-dm                             # Rooms direct-message-by-introduction over TCP: a room introduces two members who then DM directly, room out of the path (needs deno)
zig build demo-rooms-dm-reply                       # A Host publication replies to its caller over the arriving connection via currentSession(), so a non-listening peer receives the reply (needs deno)
zig build demo-rooms-dm-back                        # A member replies to a non-listening sender across a redeemed introduction: the sender hosts a reply inbox on the redeemed direct connection (sendRedeeming), room out of the path (needs deno)
zig build rooms-dm-reredeem                         # sendRedeeming resolves the direct exporter from the reply's route: a re-redeem to an already-dialed exporter resolves the same live session with no second dial (needs deno); part of runtime-check
zig build demo-rooms-dm-iroh                        # Rooms DM-by-introduction over iroh: a room introduces two members who then DM directly over encrypted QUIC, room out of the path (needs cargo + deno)
zig build demo-rooms-dm-iroh-discovery              # Opt-in: rooms DM-by-introduction over iroh by node id ALONE through n0 discovery (relays + DNS/pkarr), no direct-address hints (needs cargo + deno + internet)
zig build demo-tasks                                # Run the cross-language tasks board demo (needs deno; joins python3/racket/cargo clients when present)
zig build tasks-server                              # Serve a Tasks board over TCP; pass -- --data=DIR [--port=N]
zig build tasks-mutation-check                      # Prove Tasks mutation ordering and watcher startup cleanup over TCP (needs deno + python3 + racket); part of runtime-check
zig build tasks-app-test                            # Run the task board server over TCP, across a restart of its SQLite store; part of check
zig build tools-app-test                            # Pin the tools showcase's attenuation and revocation (needs deno); part of runtime-check
zig build demo-tools                                # Run the cross-language tools demo: delegation, attenuation, and revocation (needs deno; joins python3/racket/cargo agents when present)
zig build accountability                            # Run the accountability application on glowcap's own runtime over real TCP
zig build accountability-three-party-test           # Run three-Host TCP handoff attribution; part of check
zig build accountability-blake3-test                # Pin the accountability app's Blake3 against known vectors (needs deno and python3); part of runtime-check
zig build demo-accountability                       # Run the cross-language accountability demo: Zig host + Deno/Python callers (needs deno)
zig build rooms-client                              # Run the Zig rooms chat client (one-shot); pass `-- <locator> <room> <nick> <line> [roster]`
zig build rooms-chat-build                          # Build and install the interactive Rooms client (needs cargo); part of rooms-archive-build, rooms-chat
zig build rooms-chat                                # Chat interactively; pass -- <locator> <room> <nick> (needs cargo)
zig build rooms-web-operations-refresh              # Prove Rust operations pagination, latest search, credential removal and reload on the real page (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-trace-tail                          # Tail a Rooms server's live trace as lines; pass `-- <sturdyref> [--json]` (the ROOMS-TRACE-LISTENING value, needs deno)
zig build rooms-server-test                         # Run the in-tree Rooms server and UI contract tests (needs cargo + deno); part of demo-rooms, runtime-check
zig build rooms-terminal-client-test                # Run the Zig, Rust, Python, and Racket terminal-client contract tests (needs cargo + python3 + racket)
zig build rooms-browser-build                       # Build the production Rust Rooms browser module (needs the Wasm Rust target and matching wasm-bindgen); part of bench-rooms-projection, bindings-fmt-check, rooms-browser-test, rooms-web-build
zig build rooms-browser-metadata-check              # Verify browser metadata against the Rust application owners; part of rooms-browser-build, rooms-managed-rooms-browser-test, rooms-managed-sharing-browser-test
zig build rooms-browser-test                        # Prove production Rooms Wasm startup in Deno and Chromium
zig build rooms-rust-test                           # Run portable Rooms application and Rust/Zig static linking contracts on the host (needs cargo); part of runtime-check
zig build bench-rooms-admission                     # Measure admission cost and enforce zero steady policy allocations; part of rooms-rust-test
zig build rooms-session-foreign-test                # Run maximum foreign session admission, capacity refusal and cold-source replacement traces (needs cargo); part of rooms-rust-test
zig build rooms-rust-lint                           # Lint the Rooms Rust workspace with clippy, warnings denied (needs cargo); part of runtime-check-build
zig build rooms-rust-browser-test                   # Run the shared Rooms Rust contracts in Deno and Chromium (needs the Wasm Rust target); part of check-external
zig build rooms-rust-contract-browser-test          # Run portable Rooms Rust declarations and linked Host contracts in Deno and Chromium; part of rooms-rust-browser-test
zig build rooms-rust-browser-host-test              # Run the async Rust Host and Rooms client in Deno and Chromium (needs wasm-bindgen matching the Cargo lock); part of rooms-rust-browser-test
zig build rooms-managed-sharing-browser-test        # Share exact managed use and control through the production Noise relay
zig build rooms-managed-rooms-browser-test          # Register, subscribe, chat and stream exact-source files through the production Rooms server
zig build rooms-session-graph-browser-test          # Run session graph commit, rollback, recovery and cold reload in Chromium
zig build rooms-session-executor-browser-test       # Run managed session receipt execution, interruption and cold recovery in Chromium; part of rooms-rust-browser-host-test
zig build rooms-session-executor-browser-test -Drooms-session-executor-group=3 # readers, access and cold opening only; the default runs all four groups in separate processes, with a deadline for each scenario
zig build rooms-session-foreign-browser-test        # Run maximum foreign session fields and disconnected preservation in Chromium; part of rooms-rust-browser-host-test
zig build rooms-session-foreign-browser-reload-test # Restore maximum foreign session fields after full page reload against a surviving exporter; part of rooms-rust-browser-test
zig build rooms-archive-test                        # Prove the member-owned archive contract, durable store, wire floor, and peer restart (needs cargo + deno); part of rooms-server-test
zig build rooms-archive-build                       # Build and install the archive peer (needs cargo); part of demo-rooms-dm, demo-rooms-dm-back, demo-rooms-dm-iroh, demo-rooms-dm-iroh-discovery, demo-rooms-dm-reply, demo-rooms-iroh, demo-rooms-onion, glowcap-install, goblins-rooms, goblins-rooms-dm, goblins-rooms-dm-iroh, goblins-rooms-irc-bridge, goblins-rooms-iroh, goblins-rooms-matrix-iroh, ocapnviz-check, ocapnviz-live-browser, ocapnviz-test, rooms-archive, rooms-archive-test, rooms-dm-reredeem, rooms-peers-test, rooms-trace-tail, rooms-web-archive, rooms-web-dm-session-webrtc, rooms-web-relay-peer, rooms-web-shared-session, site-captures-rooms
zig build rooms-peers-test                          # Prove the archive peer, session peer, and Rooms server's identity, transport, restart and shutdown (needs cargo); part of runtime-check
zig build rooms-agent-test                          # Exercise the Rooms agent skill across rooms, DMs, restart and acknowledgement (needs cargo + python3); part of runtime-check
zig build rooms-archive                             # Run the durable archive peer; pass -- --state=<directory> (iroh by default)
zig build rooms-session-build                       # Build and install the durable Rooms session runtime (needs cargo); part of rooms-agent-test, rooms-archive-build, rooms-session
zig build rooms-session                             # Run the public Rooms session command; pass `-- <verb> [flags]`
zig build rooms-irc-server-build                    # Build and install the Rooms IRC server (needs cargo); part of rooms-archive-build, rooms-irc-server
zig build rooms-irc-server                          # Serve a Rooms directory to ordinary IRC clients as an IRC server
zig build rooms-irc-bridge-build                    # Build and install the standalone IRC bridge (needs cargo); part of rooms-archive-build, rooms-irc-bridge
zig build rooms-irc-bridge                          # Serve one IRC channel as a Rooms directory with the bridge (read-only by default)
zig build rooms-irc-bridge -- --irc-realname="bridge bot; admin: YOUR_IRC_NICK" # serve an IRC channel as a Rooms directory; policy prerequisites in apps/rooms/irc/README.md
zig build rooms-server-build                        # Build and install the Rooms server (needs cargo); part of rooms-agent-test, rooms-archive-build, rooms-server, rooms-web-build
zig build rooms-server                              # Run the Rooms server: the directory members register with and the rooms they enter. Pass `-- [--state=<directory>] [--history] [--capabilities=all|<name>[,<name>...]]` (iroh by default, needs cargo)
zig build rooms-web-build                           # Build and install the Rooms HTTP front and browser application (needs cargo + wasm-bindgen); part of rooms-archive-test, rooms-dev, rooms-web, rooms-web-prepare, rooms-web-relay-peer
zig build rooms-web-prepare                         # Build the Rooms server and write its browser assets as one prepared generation at zig-out/rooms-web/current, which the Rooms server binary's `--prepared` serves and `--export-static` exports (needs cargo + deno + wasm-bindgen); part of glowcap-install, rooms-server-test, rooms-web-admission, rooms-web-archive, rooms-web-boot-theme, rooms-web-dm, rooms-web-dm-deno, rooms-web-dm-fallback, rooms-web-dm-foreign, rooms-web-dm-noise, rooms-web-dm-reopen, rooms-web-dm-retarget, rooms-web-dm-session-webrtc, rooms-web-dm-tabs, rooms-web-dm-trace, rooms-web-dm-webrtc, rooms-web-hosted-session, rooms-web-link-preview, rooms-web-manager, rooms-web-operations-refresh, rooms-web-page, rooms-web-private, rooms-web-reconnect, rooms-web-relay-door, rooms-web-responsiveness, rooms-web-routes, rooms-web-shared-session, rooms-web-test, rooms-web-tor-test, rooms-web-trace-lifecycle, site-captures-directories, site-captures-rooms, site-rooms-page
zig build rooms-web-test                            # Prove the installed web front's HTTP, relay admission and startup/shutdown custody (needs cargo + deno + python3); part of runtime-check
zig build rooms-web-tor-test                        # Opt-in: prove the web front owns a private Tor and preserves its directory service key, with networking disabled (needs cargo + deno + python3 + tor)
zig build rooms-web                                 # Serve the rooms browser UI for public rooms and direct messages by introduction. Open the printed URL. This needs cargo and deno, while onion also needs tor. `-Dtransport=<transport>` picks the announced room transport from the seven the server accepts, default iroh. Server flags follow `--`: `--capabilities=all` or a comma-separated list of the names in `apps/rooms/operating.md` mints the operator capabilities. `--bind=<host> --announce-host=<host>` expose a cleartext room on a LAN
zig build rooms-dev                                 # Serve Rooms with every operator capability minted and state under .local/.state/rooms; `-Dhot-reload=false` uses compiled-generation serving, and `-Dtransport` works as on rooms-web (needs cargo + deno)
```

Each rooms browser proof drives a headless Chromium. The rows that need cargo
run their page's rooms on the installed Rooms server, including its
operations and timeline capabilities.

```sh
zig build rooms-web-relay-peer        # Prove a wasm browser peer drives the room directory through the Rooms web server's /relay byte pipe (needs deno)
zig build rooms-web-page              # Prove the whole rooms page runs as a browser peer: join a room through /relay and round-trip a line over the room capability (needs deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-relay-door        # Prove the published page, with no Rooms server, reaches a directory through its declared noise-relay door, names a relay nothing answers at, and asks for a server only for the doors it cannot open (needs deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-admission         # Prove browser admission preserves drafts, attachment custody, cleanup and unrelated progress; part of rooms-web-proofs
zig build rooms-web-responsiveness    # Prove stable Rooms presentation, delayed progress and bounded input latency over the production transport
zig build rooms-web-proofs            # Run every browser proof of the shipped Rooms page (needs cargo + deno + a Playwright Chromium). The proofs run concurrently, so a green run needs the machine to carry them: under fleet load the heaviest proofs (iroh dials) can exceed their wrapper deadline while passing alone through their own step.; part of check-external
zig build rooms-web-link-preview      # Prove link previews reconcile ready, retry, remove, image-failure and delivered-fallback states using Rooms controls on the real page (needs deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-shared-session    # Prove two browser profiles attach to one durable Rooms session process and mirror its member, selection, draft, lines, and capability vault (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-hosted-session    # Prove a browser-hosted local session attaches from a different Rooms page through its named iroh signaling directory (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-reconnect         # Prove the rooms page survives losing its iroh room server: it refreshes changed routing hints without changing authority, then re-enters a listed room by name and a private room by its retained link (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm                # Prove the rooms page sends a direct message from a real browser: redeem a room introduction and dial the member's iroh endpoint through /relay, delivered off-room (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-tabs           # Prove two browser tabs direct-message each other over the default WebRTC path, including closing and reopening the introduced line (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-deno           # Prove a Deno peer on the C library cold-dials a browser member by sealed relay rendezvous (ADR-0034). The tab advertises noise-relay, the Deno peer's Host redeems through its relay provider, the encrypted session opens Deno-to-tab off-room, and the reply rides back over the arriving connection (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-noise          # Prove two browser members direct-message through the Rooms server over an end-to-end Noise-sealed session: one managed browser connector cold-dials the other's rendezvous and the reply rides back off-room (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-webrtc         # Prove two browser members direct-message over a WebRTC DataChannel by redeeming a webrtc handoff give (ADR-0035): the room directory carries only signaling, the live timeline must name webrtc rather than keyed-relay, the card names the browser-to-browser path, and the reply rides back over the arriving connection (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-fallback       # Prove a browser direct message in the default WebRTC mode falls back to the Rooms server's sealed relay when ICE finds no route: Chromium runs with non-proxied UDP disabled, the offerer's connect bound reports the failure, the line opens over noise-relay within that bound plus a relay dial, its card names the server as the path, and the reply rides back (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-session-webrtc # Prove the Rooms session process and browser members direct-message over WebRTC DataChannels in both directions: the process runs with --dial-transports=webrtc and no relay, dials one member through the room that introduced it, and answers a second member's offer that the room delivers to its answering inbox. The live timeline names a new webrtc session for each and no keyed-relay one (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-routes            # Prove the rooms page's address is a shareable place to stand: a cold /room/<name> link arrives named, opening writes its address, back and forward walk it with the view, following an address never moves the sidebar, a private room's key stays out of it, the join card standing in for a link reflects what that link gates rather than what was used last, an empty nickname uses its displayed directory grant, and an unanswered address folds back to the front (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-manager           # Prove a reloaded workspace re-enters the rooms it manages by name and keeps its saved manager capability usable rather than merely drawn (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-boot-theme        # Prove the page's first paint is the theme the reader left, guessed from the stored workspace before any application code exists, and that a browser holding no workspace is left to its own preference (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-private           # Prove a private room is reachable only by the reference to it: it is in no room list, naming the same thing opens a different room, handing it over is what puts somebody else in it, and declining leaves them out (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-foreign        # Prove a visitor can start a direct message in a room they joined: the tab holds its own page's directory and the one it went to, and the redeem signals through the directory that introduced the member rather than through whichever was opened first (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-trace          # Prove a browser-to-browser direct message reaches the live timeline endpoint (ADR-0040): each tab publishes its own trace, the endpoint scopes both producers' session ids apart and carries both ends of the wire, and the room stays off the DM's path (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-retarget       # Prove a nickname changing hands cannot move a direct conversation: the member leaves, someone else is granted the name, and a message typed into the original conversation reaches nobody and says why (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-dm-reopen         # Prove reopening a closed direct conversation opens a second connection and that the second one carries: the live timeline must show the first session gone and a session id nobody had seen, and the reply must ride back over it, run once over webrtc and once over noise-relay (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-trace-lifecycle   # Prove the live timeline draws a member's whole life in a room, counted through ocapnviz's own converter: two tabs in a room are three peers and two sessions, a direct message adds a session between the members with the room off its path, leaving the room keeps the session and drops the nickname, closing the direct message closes its session from either end, and a tab going away takes its peer and both its sessions (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
zig build rooms-web-archive           # Prove a member explicitly selects a durable archive peer, a generation split across two archives reads back as one account under both keepers, and a fresh browser profile recovers direct-message history from the same sturdyref (needs cargo + deno + a Playwright Chromium); part of rooms-web-proofs
```

## Benchmarks

Benchmarks print measurements or write reports under `zig-out/bench-reports/`.

```sh
zig build bench-floors                # Measure each primitive alone: Ed25519, the Noise XK handshake and records, a frame copy, and a loopback round trip
zig build bench-floors -Doptimize=ReleaseFast # each primitive alone (Ed25519, Noise XK handshake and records, frame copy, loopback round trip); bench/README.md pairs product paths with these; -- --smoke under check
zig build bench-frame-view            # Run frame/view benchmark
zig build bench-host-locator          # Measure warmed Host advertised-route allocation traffic
zig build bench-uri                   # Measure locator and sturdyref URI rendering time and allocation traffic
zig build bench-uri -Doptimize=ReleaseFast # locator and sturdyref rendering time and allocation traffic
zig build bench-set-uniqueness        # Measure borrowed set validation and collision scratch on both codecs
zig build bench-set-uniqueness -Doptimize=ReleaseFast # borrowed set validation and collision scratch on both codecs
zig build bench-rooms-projection      # Count conversation and line-custody visits in the production Rooms projection
zig build bench-codec                 # Run codec/dispatch throughput benchmark
zig build bench-dispatch-scaling      # Measure inbound dispatch ns/turn across N peers (cold-cache regime) with p50/p99
zig build bench-outbound              # Measure the outbound engine path (send/step/takeOutbound) and the op:gc-answers release storm
zig build bench-peer-scaling          # Measure per-session memory and live authenticated socket scale
zig build bench-snapshot              # Measure vat snapshot/restore: O(objects), flat in object size, off by default
zig build bench-loam                  # Measure Loam residency, wakeups, edits, collection interference, and the Tasks app on either disk engine
zig build bench-loam -Doptimize=ReleaseFast # LMDB-backed conversation graph, sleepy actors, edits, collection, and cold reads at scale, and the Tasks app on each disk engine (`-- --tasks-only --engine=lmdb|sqlite` picks one); -- --smoke under check
zig build relay-scaling               # Measure the reference relay's per-connection footprint, prove it holds thousands of connections at once, and extrapolate to a host's descriptor and RAM ceiling, the relay-tier sibling of bench-peer-scaling (needs deno)
zig build bench-iroh                  # Measure OCapN round-trip latency/throughput over iroh vs a TCP baseline (needs cargo)
zig build bench-interface             # Compare raw and generated Rust calls over the same TCP workflow (needs cargo)
zig build bench-interface-builds      # Compare fresh raw and generated Rust client compilation with warm dependencies (needs cargo + python3)
zig build bench-interface-diagnostics # Measure paired Rust interface allocation traffic and wire messages separately from latency (needs cargo)
zig build bench-interface-generation  # Measure warm interface generation process time, peak RSS, and nonblank compiler source inventory (needs python3)
zig build interface-bench-smoke       # Check paired interface benchmark effects, traffic parity, and diagnostic output (needs cargo + python3); part of runtime-check
zig build interface-bench-lint        # Lint the paired interface benchmark and its diagnostic allocation feature (needs cargo); part of interface-bench-smoke, runtime-check-build, rust-lint
zig build profile-interface           # Attribute paired Rust interface operation phases under callgrind (needs cargo + valgrind + python3)
zig build bench-goblins               # Cross-implementation benchmark: glowcap's Racket binding vs Spritely Goblins (needs racket + goblins)
zig build bench-capnp                 # Cap'n Proto RPC echo round trip in Rust and C++ for the comparison table on the benchmarks page (needs capnp, cargo, g++)
zig build bench-langs                 # Per-language consumer-cost benchmark: fixed Zig host, swap client (Zig always; joins deno/python3/cargo/racket+goblins when present)
zig build bench-site-report           # Regenerate the performance pages' benchmark reports from live runs (needs racket + goblins)
zig build bench-ab                    # Run one bench alternately on a base revision and this tree, ReleaseFast, and print each row's medians side by side: -- --base=<rev> [--pairs=N] <bench-step> [bench args]
zig build bench-ab -- --base=<rev> <bench-step> [args] # the bench alternately on the archived base revision and this tree, ReleaseFast, `--pairs=N` (default 3); each row's medians side by side with their ratio
```

A `profile-*` step runs a bench under callgrind, built ReleaseFast for the
baseline CPU, and ranks the self cost per file and per function for each phase
the bench marks. The report lands at `zig-out/bench-reports/<bench>-profile.md`
beside the callgrind parts, and `bench/README.md` says how to read it.

```sh
zig build profile-loam             # Profile bench-loam under callgrind: self cost per file and function for each marked phase, taking bench-loam's filters after -- (needs valgrind)
zig build profile-outbound         # Profile bench-outbound under callgrind: self cost per file and function for each marked phase (needs valgrind)
zig build profile-dispatch-scaling # Profile bench-dispatch-scaling under callgrind: self cost per file and function for each marked phase (needs valgrind)
zig build profile-iroh             # Profile bench-iroh under callgrind: self cost per file and function for each marked phase, taking bench-iroh's filters after -- (needs cargo + valgrind)
zig build profile-report-test      # Unit-test the callgrind part reader behind the profile-* reports; part of check
zig build bench-ab-test            # Unit-test the row reader behind bench-ab; part of check
```
