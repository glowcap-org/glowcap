# One I/O runtime, lane A: retire `BlockingSession`

Status: active plan. The [one I/O runtime plan](one-io-runtime.md) owns the
rules every batch follows, the survey, the baseline, and the description of
what already exists. Read it first. This lane moves every caller of the
borrowing tier onto `driver.Session` and deletes the tier. This file is deleted
when its last batch is.

Order: A1, then A2, A3, and A4 in any order, then A5. A6 is a seam that opens
after A5 and is not executable today.

### A1 seam: the scenarios only the borrowing tier proves

Scope: `test/driver/`, `test/driver/host_runtime_multiplexed/residents.zig`,
`test/support/`, `src/driver/host_runtime/` only where a scenario reveals a
missing mechanism. Out of scope: deleting anything, touching apps, examples,
interop, docs, or `src/driver/blocking_session.zig`.

Tier assumed: the planner's own tier. This batch decides, so it is not a
sweep.

Read first: `test/driver/blocking_session/fault_test.zig`,
`test/driver/blocking_session/loopback_test.zig`,
`test/driver/pluggability_test.zig`,
`test/driver/host_runtime_multiplexed/residents.zig`.

For each scenario in the four borrowing-tier test files (10 in
`loopback_test`, 7 in `fault_test`, 4 in `byte_fed_test`, 1 in
`pluggability_test`), classify it as one of:

1. **Already proved on the owning tier.** Name the existing test by file and
   name. The owning-handshake timeouts in `fault_test` ("owning connect",
   "owning accept") and `byte_fed_test`'s four `driver.Served` scenarios
   (they never touch the borrowing tier and move to
   `test/driver/served_byte_fed_test.zig` unchanged) are expected here.
2. **Needs an owning-tier twin.** Write it under `test/driver/` against
   `driver.connect`, `driver.listen`, or a `HostRuntime` with the hermetic
   residents in `residents.zig`. Expected here: the two `faultToClosed`
   scenarios (a transport truncation during a blocking call breaks far vows
   with "connection lost" and reports `ConnectionClosed`. Any other fault
   propagates raw with "connection failed"), the settle stall
   (`WaitTimedOut`), the typed-abort retention (`partnerAbort` and the
   diagnostic), `connectUriOwned` refusing an unregistered transport, and
   ADR-0074's grant-on-first-marshal. Where a twin needs a fault the hermetic
   residents cannot inject, add the knob to `residents.zig` beside
   `fail_remote_key`.
3. **Proves a property of the borrowing tier itself.** Delete it with the
   tier in A5 and list it in the report. Expected here: "the borrowing
   blocking tier refuses the sealed symbol" in `noise_tcp_live_test` and
   `pluggability_test`'s claim that a netlayer written in test code drives the
   driver, which `test/driver/host_runtime_multiplexed/external_resident_test.zig`
   and `residents.zig` already hold for the resident contract.

Then decide two vocabulary questions and record each as a doc comment at the
owning declaration, not in this plan:

- `driver_core.Settled` keeps its `.give` arm because `Served` and the
  byte-fed drive still surface it (`src/driver/core/vocab.zig:388`). Its
  comment stops naming `BlockingSession` and names the byte-fed `Served`
  drive as the tier where a caller redeems a give.
- `Served` stays unbounded on local turns
  (`src/driver/core/served.zig:55`, `src/actors/vat/ingress.zig:521`). The
  comments name the byte-fed embedding instead of the connection-per-thread
  one.

Preserve: every test name in `test/all_test.zig` that A1 does not move keeps
passing. `residents.zig`'s existing knobs keep their names.

Verify: `zig build test -Dtest-layer=driver`, then `zig build check`.

Commit authorized. Close by replacing this section with a list of the twins
written (file and test name) and the scenarios classified as 3, so A2 and A5
can cite them.

### A2 sweep: tests that still dial through the borrowing constructors

Scope: `test/driver/inproc_netlayer_test.zig`,
`test/driver/keyed_tcp_restart_test.zig`,
`test/driver/noise_tcp_live_test.zig`, `test/driver/pluggability_test.zig`,
`test/driver/blocking_session/`, `test/support/actors.zig`,
`test/net/completion_loop_test.zig:315`, `test/all_test.zig`,
`tools/check/source_check/locator_sites.zig`. Out of scope: `src/`, apps,
examples, interop, docs.

Tier assumed: mid tier. Every edit is held by `zig build test`.

Predecessor: A1 on `dev`. Read first: the A1 closing list in this file,
`test/driver/iroh_managed.zig` (the owning-tier shape over a resident),
`test/driver/host_runtime_multiplexed/inproc_resident_test.zig`.

Rule per site:

- A `driver.connectVia(allocator, netlayers, &peer, locator, identity, read_buf, write_buf, .{ .handshake, .settle })`
  becomes `driver.connect(allocator, io, transports, locator, identity, .{ .frame_cap = frame_cap, .handshake, .settle })`.
  `transports` names the one symbol the test dials: `.{ .symbols = &.{.tcp} }`,
  `.{ .symbols = &.{.keyed_tcp} }`, `.{ .symbols = &.{.noise_tcp} }`, or
  `.{ .inproc = &exchange }`. The `engine.Peer` and the two buffers are
  deleted with their `defer`s.
- A `driver.acceptVia(allocator, listener, &peer, identity, read_buf, write_buf, opts)`
  becomes `driver.listen(allocator, io, transports, model.transport.<symbol>, .{ .designator = ... }, identity, opts)`
  followed by `server.waitAcceptable(<finite ms>)` and `server.accept()`.
  The `tcp.Listener` the test bound by hand is deleted. The address comes from
  `server.advertisedLocator()`.
- `cv.fetch(name)` keeps its name. Its result is a `driver.Capability`.
  `cv.call(ref, .{ .verb = v, .args = &.{...} }, arena)` becomes
  `session.call(cap, v, &.{...}, arena)`, and the `Settled` switch loses its
  `.give` arm. Example: `keyed_tcp_restart_test.zig:87` becomes a
  `driver.connect` over `.{ .symbols = &.{.keyed_tcp} }`.
- A test actor `handle(self, *actors.Turn, msg)` becomes
  `handle(self, *driver.HostTurn, verb, args) !driver.Value`. `model.Argument`
  literals become `driver.Value` literals of the same shape.
- The three `blocking_session/*_test.zig` imports in `test/all_test.zig`
  (lines 204 to 206) are replaced by the files A1 created. The directory
  `test/driver/blocking_session/` is deleted once every scenario in it is
  classified by A1's list. `test/support/actors.zig`'s consumer comment names
  the surviving consumers.
- `locator_sites.zig`'s row for `test/driver/blocking_session/loopback_test.zig`
  moves to the file that now owns that dial, with the same `required` and
  `banned` strings.
- Scenarios A1 classified as 3 are deleted here, not rewritten.

Preserve: every test name A1 did not classify as 3 still appears, verbatim,
in a `test/driver` file. The `x-loopback` symbol still appears nowhere in
`src/`. No `tcp` default or demo is introduced (`inproc` for in-process,
`noise-tcp` or `keyed-tcp` where a transport symbol is exposed to a reader).

Refusals: a scenario that needs a verb `driver.Session` lacks (stop, name the
verb). A test that can only pass with `.unbounded` on a dial that reaches a
socket.

Verify: `zig build test -Dtest-layer=driver`, `zig build test`, then
`zig build check`.

Commit authorized. Close by deleting this section.

### A3 sweep: apps and examples

Scope: `apps/rooms/clients/zig/client.zig`,
`apps/accountability-on-glowcap/zig/{main,host,affordance}.zig`,
`examples/zig/connect_explicit_buffers.zig`, `examples/README.md`,
`examples/zig/06_pipeline_and_attenuate.zig:125`,
`tools/build/examples.zig`, `tools/check/source_check/captp_product/deadlines.zig`.
Out of scope: `src/`, tests, interop, `docs/`, `site/`.

Tier assumed: mid tier. `zig build examples`, `zig build accountability`,
and `zig build runtime-check` hold every edit.

Predecessor: A1 on `dev`. Read first: `examples/zig/01_connect_and_serve.zig`
(the published owning-tier shape), `apps/accountability-on-glowcap/zig/three_party_test.zig`
(the same app already on `driver.listen` and `driver.connect`),
`test/driver/iroh_managed.zig`.

Rule per site:

- `apps/rooms/clients/zig/client.zig`: `dialVia` builds
  `driver.connect(allocator, io, transports, loc, .ephemeral, .{ .frame_cap = frame_cap, .handshake, .settle })`.
  For TCP, `transports` is `.{ .symbols = &.{.tcp} }` (this client already
  names cleartext TCP as the fallback). For iroh, it is
  `.{ .residents = &providers }` over an `iroh.MultiplexedAdapter` on the
  resident the function already creates, as `iroh_managed.zig:70` does. The
  stale comment at line 323 ("the owning Session face ... is not the contract
  for an iroh userspace stream") is deleted. `enterOrOpen`, `postLine`,
  `runRoom` take `*driver.Session`. `actors.Ref` becomes `driver.Capability`.
  The `Watcher` and `Inbox` actors take `*driver.HostTurn` and `driver.Value`.
  Every `.give => return error.UnexpectedHandoff` arm is deleted.
  `session.stepReadable` keeps its name.
- `apps/accountability-on-glowcap/zig/main.zig` and `host.zig`: `hostServe`
  and the standalone host use `driver.listen` over `.{ .symbols = &.{.tcp} }` on the
  address they already print, then `accept`. The caller uses `driver.connect`.
  `invoke` and `bail` take `*driver.Session`. `invoke` returns `driver.Reply`
  and `brokenReason` loses its `.give` arm. `affordance.zig` keeps
  `HostAffordance` and deletes `Affordance` with its "borrowing-tier adapter"
  comment. `valueString` becomes the one argument reader. The host prints the
  same `ACCOUNTABILITY-HOST-SERVED {d}` line.
- `examples/zig/connect_explicit_buffers.zig` is deleted: its subject is the
  caller-owned peer and buffers, which no longer exist. Delete its row in
  `tools/build/examples.zig` and its bullet in `examples/README.md`, and
  reword the comment in `tools/build/examples.zig:31` so it names only
  `frame_view` as the lower-level walkthrough.
- `examples/zig/06_pipeline_and_attenuate.zig:125` names
  `driver.Session.step` as the serve-then-drive pump over a real socket.
- `deadlines.zig:273`: `explicit_openers` loses the three borrowing
  constructors. If the array becomes empty, delete the array and the branch
  that reads it, and keep the check's examination of `driver.connect` and
  `driver.listen` budgets.

Preserve: the Rooms client's command line, output lines, and `demo_rooms_cli`
contract. The accountability banners and the three refusal outcomes its run
asserts. Every remaining example still runs under `zig build examples`.

Refusals: a verb the Rooms client needs that `driver.Session` lacks. Any new
`tcp` default in an example.

Verify: `zig build examples`, `zig build accountability`,
`zig build rooms-client`, then `zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section.

### A4 sweep: interop drivers and the shared harness

Scope: `interop/_common/zig/harness.zig`,
`interop/goblins_interop/{iroh_driver,onion_driver}.zig`,
`interop/iroh_interop/driver.zig`, `interop/iroh_reachability/driver.zig`,
`interop/onion_interop/driver.zig`, `interop/webrtc_common.zig`,
`interop/webrtc_signaling_captp/driver.zig`. Out of scope: everything else.

Tier assumed: mid tier, with the limit that only `iroh-interop`,
`webrtc-signaling-captp`, and the compile of every driver run without
outside services. `goblins-iroh`, `goblins-onion`, `onion-interop`, and
`iroh-reachability` need Racket with Goblins, Tor, or the internet. The
report names which ran.

Predecessor: A1 on `dev`. Read first: `test/driver/iroh_managed.zig`,
`interop/_common/zig/harness.zig`, `src/driver/session/connect.zig`.

Rule per site:

- `harness.PeerScaffold` is deleted. `harness.expectStringReply` takes
  `*driver.Session`, a `driver.Capability`, and `[]const driver.Value`, and
  switches on `driver.Reply`. `harness.AcceptServeOne.run` takes the
  `HostRuntime.Transports` and the transport symbol instead of a
  `net.netlayer.Listener`, calls `driver.listen`, waits with a finite
  `waitAcceptable`, accepts, publishes `Actor` as a `HostTurn` behavior, and
  serves.
- Each `driver.connectVia` over an iroh `resident.netlayer()` becomes
  `driver.connect` over `.{ .residents = &providers }` with
  `iroh.MultiplexedAdapter` on that resident. Each over onion becomes
  `driver.connect` over `.{ .symbols = &.{.onion}, .onion = config }`. Each
  over TCP (the WebRTC signaling session) becomes `driver.connect` over
  `.{ .symbols = &.{.tcp} }`.
  `acceptVia` becomes `driver.listen` the same way.
- `interop/iroh_reachability/driver.zig`: `callByIdOnlyRetrying` keeps its
  loop, now around `driver.connect`, with the classifier switch unchanged.
  B2 deletes the loop once B1 retries inside the runtime.
- `interop/webrtc_common.zig:424` `bringUpViaCapTP` takes `*driver.Session`
  and a `driver.Capability` inbox.
- `assertPartnerIsNodeId` and the other `*driver.BlockingSession` helpers
  take `*driver.Session` and read `session.partnerIdentity()`.

Preserve: every banner line the drivers print (the binding proofs and
`docs/build-steps.md` descriptions quote them). The keyed identities each
driver proves. `.unbounded` stays only where the driver already spells it
against its own in-process partner.

Refusals: a driver that needs `Settled.give` (the goblins drivers redeem
through the runtime now. Stop if a scenario depended on holding the give).

Verify: `zig build iroh-interop`, `zig build webrtc-signaling-captp`, the
compile of every driver in scope through `zig build check`, then whichever of
`goblins-iroh`, `goblins-onion`, `onion-interop` the environment supports.

Commit authorized. Close by deleting this section.

### A5 delete: the module, its exports, its checks, and its prose

Scope: `src/driver/blocking_session.zig`, `src/driver/mod.zig`,
`src/driver/core/{mod,served,vocab}.zig`, `src/driver/session/client.zig`,
`src/actors/vat/{ingress,mod,serve}.zig`,
`src/net/completion/loop/configuration.zig`,
`src/net/completion/loop/connections/flow.zig`, `src/ocapn/engine/hello.zig`,
`tools/check/source_check/captp_io_spine.zig`, `docs/architecture.md`,
`docs/boundaries.md`, `docs/stability.md`, `site/content/concepts.smd`,
`site/content/transports/noise.smd`, `.agents/rules/architecture.md`,
`.agents/skills/memory-ledger/references/host.md`,
`docs/decisions/adr/ADR-0053-blocking-pump-single-fiber.md`,
`docs/decisions/adr/ADR-0193-one-io-runtime.md`, `docs/roadmap.md`. Out of
scope: tests, apps, examples, interop (A2 to A4 own them).

Tier assumed: mid tier. `zig build check` holds the Zig edits and
`source-check` holds the prose and the symbol claims in doc comments.

Predecessors: A2, A3, and A4 on `dev`. Read first: this plan's survey
command for lane A, `.agents/rules/doc-drift.md`.

Rule per site:

- Delete `src/driver/blocking_session.zig`. In `src/driver/mod.zig` delete
  the import and the four re-exports (lines 92 to 98), and rewrite the module
  header so it names `driver.Session` and `Server` on `HostRuntime` as the
  native surface and `Served` as the sans-io core, with no mention of a
  borrowing or caller-pumped tier. `drawSessionSecret`'s comment names the
  `HostRuntime` handshake halves.
- `captp_io_spine.zig:260` to `276`: delete the block that reads
  `src/driver/blocking_session.zig`.
- Every remaining source comment that names `BlockingSession` (the survey
  command lists them under `src/`) is rewritten to name the mechanism that
  exists: `driver.Session.step` for the serve-then-drive pump, the byte-fed
  `Served` drive for a caller-owned loop, `driver.connect` for the dial-side
  open. A comment whose only content was the borrowing tier is deleted.
  `src/driver/core/vocab.zig:124` to `131`: the `SealedChannelRequiresHost`
  arm is deleted together with every site that returns it (the survey lists
  them) because no tier remains that refuses a sealed symbol.
- Docs are found by content, not line, because a prose sweep may land
  first: grep each file for `BlockingSession`. `docs/architecture.md`: delete
  the `driver.BlockingSession` row of the API table, and the `driver.Session`
  row says a transport with no pollable descriptor joins as a multiplexed
  resident. In the options table, the `local_turn_budget` row drops its
  clause about a bare `Served` in `BlockingSession`. `docs/boundaries.md`:
  delete the bullet that says it serves one connection on one fiber.
  `docs/stability.md`: the `noise-tcp` row's last cell says only that no
  outside CapTP peer speaks Noise. `site/content/concepts.smd`: delete the
  sentence that says it hands you the gift. `site/content/transports/noise.smd`:
  delete the paragraph that says it borrows an already-open byte stream.
  `.agents/rules/architecture.md`: the transports line drops its
  parenthetical, the `driver` bullet lists `HostRuntime` with its `Session`
  and `Server` views, and the vocabulary table loses the
  `driver.BlockingSession` row. `.agents/skills/memory-ledger/references/host.md`:
  the blocking-wait line names `driver.Session.call`.
- ADR-0053's frontmatter gains `superseded_by: [ADR-0193]` and status
  `superseded`. ADR-0193's `supersedes` gains `ADR-0053`. No other ADR
  changes: historical mentions stay.
- `docs/roadmap.md`: delete the row "Replace `BlockingSession` with a
  one-wire Host".

Preserve: `driver.Served`, `driver.core`, every `driver.*` export other than
the four deleted. `test/api_surface_test.zig` compiles.

Refusals: a `BlockingSession` mention the survey command still finds after
the sweep that is not an ADR. A `source-check` symbol-claim failure fixed by
deleting the check instead of the claim.

Verify: the lane A survey command returns only `docs/decisions/adr/` paths
and this plan, `zig build check`, `zig build runtime-check`.

Commit authorized. Close by deleting this section and the "Order" line above
it, and by writing A6 as the one remaining item in this file.

### A6 seam, opens after A5: the blocking `Netlayer` contract

Not executable today. After A5, `net.netlayer.Netlayer` (the blocking
dial/accept vtable) has no consumer outside `src/net/`:

```sh
grep -rln 'netlayer\.Netlayer\b' src | grep -v '^src/net/'
```

returns nothing, while every stream resident still exposes `netlayer()` and
`asNetlayer()` (`src/net/transport/{tcp,inproc,iroh/resident,keyed_relay/*,onion/resident}.zig`)
and `test/net/` exercises them. The planner decides whether the blocking
vtable stays as `src/net`'s internal composition seam or is deleted with its
tests, by reading ADR-0043 and ADR-0062 against the resident contract in
`net/multiplexed_resident.zig`. That decision is written as an ADR amendment
or a `net` doc comment, then this lane is closed.
