# pancake — Remaining Work

The [ladder](ladder.md) explains the architectural rungs and which ones are held.
This file is the flatter companion. It names the concrete remaining work, with
each item checked against the current tree instead of copied from an old audit.
When an item lands, this file changes in the same diff. Like every living-state
surface, it should describe the repository as it is.

## How this is ordered

The order is an engineering argument, not a priority list, and it has one shape:
**iroh is the capstone, and everything else earns its place before it.** The
QUIC/iroh netlayer is the highest-leverage piece and the one that makes the most
boundaries disappear, but it should plug into a substrate that is already complete
and proven, not into a substrate it forces into existence. So the work is staged:

1. **Cross-cutting foundations** land first. These touch several layers at once —
   the data model, the protocol core, the handoff substrate — and both the
   independent tracks and iroh itself depend on them. They are done carefully, as
   architecture, with no corners cut, because a corner cut here is a corner cut
   everywhere downstream.
2. **Independent tracks** follow, and they parallelize. Each is localized to one
   layer and does not block the others, so they can be worked concurrently once
   the foundations they rest on are in.
3. **Platform reach** is gated on hardware this repository's environment does not
   have. It is real work, not deferred work, but it cannot be done or proven here.
4. **The iroh capstone** is last, and the substrate proven ready for it: the
   encrypted channel landed with no driver or core edit, and the
   identity-and-discovery cluster it unlocked — dial-by-id discovery,
   key-as-designator identity, durable capabilities, secure-transport URIs —
   has since landed on top, all on the `iroh-interop` gate. What remains is
   serving it at scale (the ADR-0057 completion-loop bridge) and the external
   blocks (Goblins-over-iroh, native QUIC).

## 1. Cross-cutting foundations (watch items; nothing buildable remains)

The load-bearing cross-cutting pieces have landed; what remains here waits on
upstream, not on this repository.

- **OCapN Null.** The one passable still outside the model (the Integer is
  arbitrary-precision per ADR-0049, and Struct and Undefined ship per
  ADR-0046). Null stays fail-closed on purpose: Goblins has no Null
  marshalling and the upstream encoding is unsettled, so a guessed wire shape
  would not interop. The boundary is pinned by tests; it unblocks only when
  upstream settles an encoding, so it is a watch item, not buildable now.

The projection ops are done: `op:get`, `op:index`, and `op:untag` are all
answered (ADR-0050, ADR-0052) with an exported promise the resolve seam
settles to the projected field, element, or unwrapped Tagged payload, and the
live Goblins gate exercises a pipelined `op:index` and a pipelined `op:get`
end to end. A live untag gate slots in when Goblins ships the op's marshaller.

Handoff certificate verification is held: canonical give/receive signing
bytes, real Ed25519 verification through `engine.cross_peer.SignatureVerifier`,
the exporter `GiftRegistry`, Zig real-key tests, the accountability
three-party scenario, and the live `goblins-handoff` step cover the current
certificate seam. A pure-pancake over-TCP three-party scenario is not built;
it would add hermetic breadth, but nothing on this list blocks on it.

## 2. Independent tracks (parallelizable once the foundations are in)

Each item here is localized to one layer and does not depend on the others, so
they can be worked concurrently. None of them is cross-cutting.

- **Enforced wall-clock performance gate.** Allocation count is gated exactly and
  the per-session footprint is gated (ADR-0045). Wall-clock time is only
  printed, and `check` prints it in Debug. A real threshold needs a ReleaseFast,
  hardware-stable benchmark harness that does not flake — infrastructure work, not
  a one-line assertion.
- **Export-on-marshal for spawned capabilities.** `driver.spawnAt` (and the
  `spawn` verbs that ride on it) mints the export the moment the actor is
  spawned, so the partner can invoke the capability before the reference is
  ever sent. Minting the export only when the reference first marshals onto
  the wire would close that window. Today the early-export contract is
  documented on `spawn` / `spawnAt`, and `Vat.spawn` is the no-export
  alternative.

The completion loop's read buffers are a shared backend-owned pool (io_uring
provided buffers, ADR-0054): an idle connection holds zero read-buffer bytes,
and the buffer floor at 500k connections is the pool, not 16 KiB per
connection. Nothing on this list remains there.

ADR-0053 settles the read/write fiber split for the blocking pump as a
refusal, so it does not appear above. The blocking pump's contract is
cooperative request/response on one fiber, and the workload that needs duplex
backpressure — a partner that streams without draining — rides the completion
loop, which both directions package (`driver.LoopHost`, `driver.LoopDialer`).

## 3. Platform reach (real work, not doable in this environment)

- **Windows / IOCP backend.** The completion loop is OS-neutral over its backend;
  io_uring and kqueue ship (kqueue compile-gated by `cross-check`). A Windows IOCP
  backend needs a Windows machine to write and run against.
- **macOS runtime CI.** kqueue is compile-gated on every `check` but never *run*.
  Proving its runtime behavior and backend throughput parity needs a macOS runner.

## 4. The iroh capstone (channel + identity + discovery landed; scale remains)

The capstone's first slice exists. The iroh netlayer is a real
`net_adapter.Netlayer` resident (`net_adapter/iroh.zig`, ADR-0055), registered
like tcp and reached through `connectVia` and `acceptVia` with no driver or core
edit — exactly the seam the substrate was built to receive. The transport is
a Rust sidecar staticlib (`transports/iroh/`) behind a narrow blocking C ABI, so
`libpancake` stays pure Zig; the transport symbol is `iroh` and the locator
designator is the endpoint's Ed25519 id. `zig build iroh-interop` proves the
encrypted channel live: two pancake peers over real iroh endpoints, dialed by
endpoint id with direct-address hints, through the keyed handshake, a bootstrap
fetch, and a deliver/resolve. The capstone's identity-and-discovery cluster has
since landed, all proven by the same `iroh-interop` gate:

- **Peer discovery and relays — shipped.** The netlayer takes a configurable,
  no-default `Reachability` (`direct`/`discovery`/`discovery_no_relay`/
  `local_discovery`) threaded through the sidecar, the resident, the public C
  ABI, and all four bindings. The gate dials by node id **alone** through an
  address book — no direct-address hints — proving the lookup half
  deterministically; the public-internet posture is the same path against n0
  relays and pkarr/DNS. Relays and hole-punching are sidecar-internal (iroh
  performs them); the posture is pancake's visible, opt-in choice.
- **Key-as-designator identity — shipped.** One Ed25519 key per peer is now at
  once the iroh node id, the OCapN locator designator, and the session signing
  key. `driver.connectViaWithSecret` / `acceptViaWithSecret` sign the keyed
  handshake with the endpoint's own key, and `iroh-interop` verifies on both
  halves that the partner's session pubkey equals the node id equals the signed
  designator.
- **Durable capability identity — shipped.** A sturdyref (node id plus
  swiss-number) outlives an endpoint restart: the gate tears an endpoint down,
  rebinds from the same seed (same key, same node id at a fresh address), and
  reaches the same published cap through the locator recorded before the restart.
  Bootstrap-cap *contents* stay process-lifetime (an app re-registers on
  restart), but the durable *identity* the sturdyref names is now stable.

What remains on the cluster is **scale and external blocks**, each named:

- **Serving iroh at scale** is the event-driven completion-loop bridge of
  ADR-0057 — designed, not built. Today's concurrency is thread-per-connection
  (correct, proven, but capped well below the ~500k-connection footprint
  target). The plan is
  [`planning/iroh-completion-loop-bridge.md`](planning/iroh-completion-loop-bridge.md).
- **Goblins interop over iroh** is externally blocked: Goblins ships no iroh
  netlayer, so the transport is proven pancake-to-pancake.
- **A native Zig QUIC** path stays rejected until iroh's protocols stabilize and
  a production Zig QUIC stack exists (ADR-0055's flip condition).

One adjacent robustness debt is recorded, not hidden: the cross-language
`demo-rooms-iroh` and the Deno iroh tests are flaky under load (an FFI-teardown
race and message loss under many concurrent dials), which the ADR-0057
non-blocking surface removes by construction. `iroh-interop` is the
authoritative, deterministic iroh gate.
