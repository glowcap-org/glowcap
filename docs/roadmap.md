# pancake — Remaining Work

The [ladder](ladder.md) explains the architectural rungs and which ones are
held. This file is the flatter companion. It names the concrete remaining work,
with each item checked against the current tree. When an item lands, this file
changes in the same diff. Like every
living-state surface, it should describe the repository as it is.

## How this is ordered

The sections below are ordered by dependency, not priority, and most of the work
they describe has already landed. The QUIC/iroh netlayer was the capstone: the
highest-leverage piece, built to plug into a substrate that was already complete
rather than to force that substrate into existence. So the substrate landed first
and iroh landed on top of it, and the sections keep that order so a reader meets
each layer before the one that rests on it.

1. **Cross-cutting foundations** come first. They touch several layers at once
   (the data model, the protocol core, the handoff substrate), and both the
   independent tracks and iroh depend on them. They are done; what remains here
   waits on upstream, not on this repository.
2. **Independent tracks** follow. Each is localized to one layer and does not
   block the others, so the remaining ones can be worked concurrently.
3. **Platform reach** is gated on hardware this environment does not have. It is
   real work, not deferred work, but it cannot be done or proven here.
4. **The iroh capstone** comes last because it rests on everything above. The
   encrypted channel, dial-by-id discovery, key-as-designator identity, durable
   capabilities, secure-transport URIs, the mesh, real-internet reachability, and
   the at-scale completion loop have all landed, each on its own gate
   (`iroh-interop`, `iroh-mesh`, `iroh-reachability`, `iroh-loop`). What remains
   is the live-socket 500k measurement and the external blocks (Goblins over
   iroh, native QUIC).

## 1. Cross-cutting foundations (watch items; nothing buildable remains)

The load-bearing cross-cutting pieces have landed; what remains here waits on
upstream, not on this repository.

- **OCapN Null.** The one passable still outside the model (the Integer is
  arbitrary-precision per ADR-0049, and Struct and Undefined ship per ADR-0046).
  Null stays fail-closed on purpose: Goblins has no Null marshalling and the
  upstream encoding is unsettled, so a guessed wire shape would not interop. The
  boundary is pinned by tests; it unblocks only when upstream settles an
  encoding, so it is a watch item, not buildable now.

The projection ops are done: `op:get`, `op:index`, and `op:untag` are all
answered (ADR-0050, ADR-0052) with an exported promise the resolve seam settles
to the projected field, element, or unwrapped Tagged payload, and the live
Goblins gate exercises a pipelined `op:index` and a pipelined `op:get` end to
end. A live untag gate slots in when Goblins ships the op's marshaller.

Handoff certificate verification is held: canonical give/receive signing bytes,
real Ed25519 verification through `engine.cross_peer.SignatureVerifier`, the
exporter `GiftRegistry`, Zig real-key tests, the accountability three-party
scenario, and the live `goblins-handoff` step cover the current certificate
seam. A pure-pancake three-party handoff also runs over a real transport:
`zig build iroh-mesh` runs a three-party handoff across three iroh endpoints,
then has the recipient reach the introduced exporter by the gifted node id,
withdraw, and call, the mesh, all pancake.

## 2. Independent tracks (parallelizable once the foundations are in)

Each item here is localized to one layer and does not depend on the others, so
they can be worked concurrently. None of them is cross-cutting.

- **Enforced wall-clock performance gate.** Allocation count is gated exactly
  and the per-session footprint is gated (ADR-0045). Wall-clock time is only
  printed, and `check` prints it in Debug. A real threshold needs a ReleaseFast,
  hardware-stable benchmark harness that does not flake, infrastructure work,
  not a one-line assertion.
- **Export-on-marshal for spawned capabilities.** `driver.spawnAt` (and the
  `spawn` verbs that ride on it) mints the export the moment the actor is
  spawned, so the partner can invoke the capability before the reference is ever
  sent. Minting the export only when the reference first marshals onto the wire
  would close that window. Today the early-export contract is documented on
  `spawn` / `spawnAt`, and `Vat.spawn` is the no-export alternative.
- **Restart-stable TCP listening identity.** The iroh capstone already binds a
  peer's Ed25519 key as node id, locator designator, and session signing key,
  and a sturdyref survives an endpoint restart (section 4). The cleartext TCP
  netlayer has no equivalent: its keyed handshake authenticates the session but
  the listener has no durable, pinned designator a partner can re-dial across a
  process restart. Giving the TCP transport a restart-stable listening identity
  (an SPKI-pinned or key-derived designator, the TCP analogue of the iroh node
  id) would let durable capabilities span restarts on TCP too. It is a transport
  feature localized to the TCP netlayer and its session seam, not a core change.

- **A hosted, versioned C release of the archives.** Every binding already
  resolves its archives through a shared cascade — `PANCAKE_LIB_DIR`
  (configure), then the repo's `zig-out/lib` (dev fallback), then the bare name
  on the system library path (find) — documented in
  [`../bindings/README.md`](../bindings/README.md). What is deferred is the
  **find** leg's upstream: a hosted, versioned, per-platform release of the
  archives keyed to `pancake_abi_version` — pancake's "C release" — that a
  published binding depends on. It drops a cached-download leg into the cascade
  between configure and the dev fallback without changing the order, and it is
  the prerequisite for any runtime-download or npm per-platform packaging. It is
  real work, but it waits on a release/hosting posture, not on the bindings.

The completion loop's read buffers are a shared backend-owned pool (io_uring
provided buffers, ADR-0054): an idle connection holds zero read-buffer bytes,
and the buffer floor at 500k connections is the pool, not 16 KiB per connection.
Nothing on this list remains there.

ADR-0053 settles the read/write fiber split for the blocking pump as a refusal,
so it does not appear above. The blocking pump's contract is cooperative
request/response on one fiber, and the workload that needs duplex backpressure —
a partner that streams without draining — rides the completion loop, which both
directions package (`driver.LoopHost`, `driver.LoopDialer`).

## 3. Platform reach (real work, not doable in this environment)

- **Windows / IOCP backend.** The completion loop is OS-neutral over its
  backend; io_uring and kqueue ship (kqueue compile-gated by `cross-check`). A
  Windows IOCP backend needs a Windows machine to write and run against.
- **macOS runtime CI.** kqueue is compile-gated on every `check` but never
  _run_. Proving its runtime behavior and backend throughput parity needs a
  macOS runner.

## 4. The iroh capstone (channel + identity + discovery landed; scale remains)

The capstone's first slice exists. The iroh netlayer is a real
`net.netlayer.Netlayer` resident (`net/transport/iroh.zig`, ADR-0055),
registered like tcp and reached through `connectVia` and `acceptVia` with no
driver or core edit, exactly the seam the substrate was built to receive. The
transport is a Rust sidecar staticlib (`transports/iroh/`) behind a narrow
blocking C ABI, so pancake's own archives stay pure Zig; the transport symbol is
`iroh` and the locator designator is the endpoint's Ed25519 id.
`zig build iroh-interop` proves the encrypted channel live: two pancake peers
over real iroh endpoints, dialed by endpoint id with direct-address hints,
through the keyed handshake, a bootstrap fetch, and a deliver/resolve. The
capstone's identity-and-discovery cluster has since landed, all proven by the
same `iroh-interop` gate:

- **Peer discovery and relays, shipped.** The netlayer takes a configurable,
  no-default `Reachability` (`direct`/`discovery`/`discovery_no_relay`/
  `local_discovery`) threaded through the sidecar, the resident, the public C
  ABI, and all four bindings. The gate dials by node id **alone** through an
  address book — no direct-address hints — proving the lookup half
  deterministically; the public-internet posture is the same path against n0
  relays and pkarr/DNS. Relays and hole-punching are sidecar-internal (iroh
  performs them); the posture is pancake's visible, opt-in choice.
- **Key-as-designator identity, shipped.** One Ed25519 key per peer is now at
  once the iroh node id, the OCapN locator designator, and the session signing
  key. `driver.connectVia` / `acceptVia` with a `.keyed` `Identity` sign the
  keyed handshake with the endpoint's own key, and `iroh-interop` verifies on
  both halves that the partner's session pubkey equals the node id equals the
  signed designator.
- **Durable capability identity, shipped.** A sturdyref (node id plus
  swiss-number) outlives an endpoint restart: the gate tears an endpoint down,
  rebinds from the same seed (same key, same node id at a fresh address), and
  reaches the same published cap through the locator recorded before the
  restart. Bootstrap-cap _contents_ stay process-lifetime (an app re-registers
  on restart), but the durable _identity_ the sturdyref names is now stable.

What remains on the cluster is **scale and external blocks**, each named:

- **Serving iroh at scale** is the event-driven completion loop of ADR-0057,
  now built (`iroh.LoopHost`, gated by `zig build iroh-loop`) and the iroh
  netlayer's one I/O model, so connections multiplex through one loop thread
  instead of a thread apiece. The public netlayer C ABI is loop-only (a
  readiness fd plus a non-blocking drain, armed at construction), and every
  binding parks on that fd natively (Deno, Python, Rust, and Racket each in
  their own idiom). Python, Rust, and Racket are each proven by a many-connection
  gate under `bindings-iroh-loop`; Deno implements the same loop surface,
  exercised by the iroh demos rather than that aggregate step. What remains is the live
  measurement at the ~500k-connection footprint target; the design is
  [ADR-0057](decisions/adr/ADR-0057-iroh-completion-loop-bridge.md).
- **Goblins interop over iroh** is deferred behind a contained *upstream* change,
  not a pancake one: Goblins ships no iroh netlayer, so the transport is proven
  pancake-to-pancake today. Unblocking it is an edit to Goblins' netlayer seam
  only — teaching a Goblins vat to speak the iroh netlayer — after which the
  existing `*-goblins-interop` / `*-goblins-handoff` gates extend over iroh
  unchanged on the pancake side. Deferred until that upstream seam lands.
- **A native Zig QUIC** path stays rejected until iroh's protocols stabilize and
  a production Zig QUIC stack exists (ADR-0055's flip condition).

One adjacent robustness debt is recorded, not hidden: the cross-language
`demo-rooms-iroh` and the Deno iroh tests are flaky under load (an FFI-teardown
race and message loss under many concurrent dials), which the ADR-0057 loop —
the netlayer's one I/O model — removes by construction. `iroh-interop` is the
authoritative, deterministic iroh gate.
