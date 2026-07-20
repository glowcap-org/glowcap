# Agent Worklist: the plate, with the details already paid for

Status: active plan (a dispatch brief for agent sessions; delete entries as
they ship, delete the file when it is empty)

This is the hand-off from a long execution arc (2026-07-19). It names every
open rock, the design facts and traps that were expensive to learn, and what
is already done so nobody re-does it. Read the [roadmap](../roadmap.md) for
ordering authority; this file adds the working detail the roadmap deliberately
leaves out.

## How to work here (lessons that cost real debugging)

- **Gates pass by exit code.** Redirect a build step's output to a file and
  check `$?` — never pipe through `tail`/`grep` (that reports the pipe's
  exit; two commits once shipped red that way). Run gates alone; a live rival builder (another
  session, a ZLS `--watch` actively compiling) causes phantom failures whose
  tell is a changing cache hash per retry.
- **The FFI tiers are generated.** Never hand-edit `_sigs_gen.py`,
  `ffi-*-gen.rkt`, `sys/*_fns_gen.rs`, `internal/ffi/*.ts`, or
  `include/pancake_*.h`. To change a C signature: edit the Zig export, its
  row in the archive's `symbols.zig` inventory, the header prose in BOTH the
  export's doc comment and `tools/gen/header/*.zig`, then run the five
  `gen-*` steps (`gen-header-driver`, `gen-ts-abi`, `gen-binding-rust-ffi`,
  `gen-binding-python-ffi`, `gen-binding-racket-ffi`). Each is one command;
  staleness checks in `check` hold them.
- **Header doc prose must not contain `/*` or `*/`** — the generator now
  refuses it at compile time. The failure it prevents hides until a header
  change invalidates a consumer's compile cache, then breaks `-Werror`
  builds far from the cause.
- **Racket runtime truths:** `#:blocking?` keeps GC cooperative but does NOT
  free the place's green threads; a callout that must overlap them rides
  `call-in-os-thread`, with a one-byte pipe write as completion signal and
  memory barrier (see the dial in `bindings/racket/pancake-iroh.rkt` — both
  halves are load-bearing, the comment there explains the 30-second
  GC-stall failure mode). The last-error slot is per OS thread: read
  diagnostics on the thread that failed. Plain `racket` never writes
  bytecode; demo spawns pass `-y` so first runs warm the cache; stale
  `compiled/` dirs after renames make new names "undefined" (`find … -name
  compiled -exec rm -rf {} +`, then re-warm).
- **The byte-fed feed contract:** the core owns framing AND the unconsumed
  tail (`HostSession.feed_tail`). `pancake_host_session_feed_bytes(session,
  bytes, len)` consumes everything on success; an empty feed resumes frames
  held behind the handshake hello; an empty feed with nothing held is a
  no-op even on a condemned session (a crossed-hellos tiebreak loss is
  routine under concurrent introductions — do not turn it into a serve
  failure). A binding pump is read → feed → drain; meta-check bans a
  binding-side inbox from returning.
- **Commits:** stage explicit paths only; re-read `git status` first —
  parallel sessions land commits mid-turn here, and `.forgejo/` CI files may
  be another session's in-flight work.

## The rocks, in suggested order

### 1. Rooms-web browser peer (the owner's priority)

Plan: [rooms-web-browser-peer](rooms-web-browser-peer.md). The wish: a human
peer living in the browser talks to bots as real pancake peers. W1 (the
`/relay` byte pipe, `apps/rooms/deno/relay_server.ts` on the rooms web
server's HTTP port) is landed and proven: see the relay tests in
`apps/rooms/deno/web_test.ts`, where a stack `Session` with its own Host
identity establishes through the relay and calls the directory.
Facts the next agent needs:

- `Session.establishDialedLocator(host, "tcp", "host:port", channel)` opens
  a dialed CapTP session over ANY `Channel` — the ws-adapter shape is in
  that test and in `bindings/ts/web/test/serve_ws_host.ts`.
- **W2 (done).** Browser peer runs OCapN over `/relay`: wasm peer
  (`rooms-web-relay-peer`), real Chromium (`rooms-web-browser-peer`), and the
  whole page joining a room (`rooms-web-page`); the `bindings-relay` matrix
  holds the keyed session through the relay. JSON bridge, `lib/wire.ts`, and the
  flaky bridge tests deleted; the browser drives `lib/room_client.ts`
  directly on an `@pancake/web` peer. The relay is the pipe in
  `apps/rooms/deno/relay_server.ts` over `@pancake/relay`:
  TCP targets allow-listed to exactly the room server's own port (iroh
  targets are `ocapn://` locators), Origin check on the upgrade, live-session
  cap, idle timeout, per-session byte cap; every forwarded chunk is copied.
- **W3 (open).** DMs from the browser to a member through the relay are not
  built; the browser DM path is a stub that says the feature is coming
  later. The allow-list admits no TCP target beyond the room server's own
  port, so opening
  DMs needs a source for member ports (the room server exposing
  live-introduction locators over a session, or an equivalent decision) plus
  a live proof.
- **W4 (iroh leg proven; browser DMs open).** `zig build bindings-relay-iroh`
  proves a wasm browser peer holds a live OCapN session with a real iroh
  endpoint through each runtime's relay (fetch and call round-trip).
  Browser-to-member DMs through the relay remain open.
- Reachability truths: a browser always initiates dials (it has no dialable
  locator), and a CapTP session is bidirectional once open — so messaging
  from a bot to the human works over the human-initiated session. WebRTC
  (ADR-0070 M2) is only needed between two browser tabs and can trail.

### 2. Observability family (Spec B)

Plan: [observability-family](observability-family.md) — griddle and
ocapnviz, the protocol-timeline tooling. Untouched by this arc; the plan is
the brief. A product app lands under `apps/` (see ADR-0085 as amended).

### 3. A2A-on-CapTP facade (Spec D)

Plan: [pancake-a2a-on-captp-design](pancake-a2a-on-captp-design.md).
Decision-first: confirm with the owner before building.

### Not agent-executable here (ops / hardware)

The C release valve (credentialed machine), the live ~500k measurement,
Windows/IOCP, macOS runtime CI — see the roadmap's sections 2–3. The
upstream watch items (OCapN Null, live `op:untag`, listen arity, settlement
encoding, Goblins-over-iroh) are a do-not-build list with flip conditions.

## Recently closed (do not redo)

- **Rooms-web-browser-peer W2 (2026-07-19).** Browser peer established: fixed import paths after Deno-specific layer separation, proved OCapN over `/relay` with wasm peer and real Chromium. JSON bridge and flaky tests deleted. All tests green: `rooms-web-relay-peer`, `rooms-web-browser-peer`. Browser now runs `lib/room_client.ts` on an `@pancake/web` peer.
- The binding FFI generation rock, whole: inventories drive all five
  language tiers, and the pump choreography hoisted into the core-owned
  feed tail (net −150 lines across four pumps).
- `racket-iroh-loop` red → green (the os-thread + `#:blocking?` dial).
- The TUI nonblocking CapTP lab shipped long since (`cli/repl/
  await_queue.zig`); its plan doc was retired.
- `examples/apps/` → `apps/` (ADR-0085 amended); demo racket spawns warm
  bytecode with `-y`.
