---
id: ADR-0055
status: accepted
date: 2026-06-11
tags: [net, netlayer, iroh, transport, identity]
decision: "The iroh netlayer is a Rust sidecar: a separate staticlib crate (transports/iroh) wraps the iroh crate behind a narrow blocking C ABI, and one Zig resident (net/transport/iroh.zig) implements the ADR-0043 Netlayer contract over that ABI. libpancake and the core stay pure Zig; only the iroh build steps need cargo, the same sibling-step posture as the Rust dogfood. The iroh NodeId is the locator designator under the transport symbol `iroh`; the blocking ConnectedVat path is the slice-1 consumer; the live proof is a pancake-to-pancake keyed session over real iroh endpoints."
supersedes: []
superseded_by: []
---

# ADR-0055 The iroh netlayer is a Rust sidecar behind the netlayer contract

## Context

The vision names a QUIC-based peer-to-peer netlayer in the iroh shape as the
secure-transport destination: an encrypted ordered channel, NAT traversal and
relays, and a self-authenticating node identity that is also OCapN's designator.
The roadmap stages it last, against a finished substrate, and the substrate is
now finished: the netlayer contract exists (ADR-0043) with two residents, the
completion loop owns both directions (ADR-0051), and the buffer floor is shared
(ADR-0054). iroh itself ships as a Rust crate (`iroh`, pinned at `1.0.0-rc.1`),
not as anything Zig can import. Every integration shape therefore answers one
question first: where does the Rust boundary sit?

## Decision

**A sidecar staticlib, never a core dependency.** A new crate at
`transports/iroh/` wraps the iroh endpoint behind a narrow, blocking,
hand-written C ABI (`pancake_iroh_*`): create an endpoint (owning its tokio
runtime behind the opaque handle), read its node id and direct addresses,
connect by node id plus address hints, accept, and read/write/close one
bidirectional QUIC stream per connection. The Zig side is one resident,
`src/net/transport/iroh.zig`, that implements the ADR-0043 `Netlayer` contract
over those externs, pinning its concrete stream wrappers exactly as `net.tcp`
does. `libpancake`, the core layers, and every existing gate remain pure Zig;
the `iroh-*` build steps require cargo on PATH and run as sibling steps, the
same posture as `rust-dogfood`.

**The node id is the designator.** An iroh NodeId is an Ed25519 public key —
precisely OCapN's self-authenticating designator. The transport symbol is
`iroh`, the locator designator is the node id in its canonical 64-character
lowercase-hex form (the one spelling `Resident.nodeId` prints and `dial`
accepts), and relay or direct addresses ride the locator's hints, where ADR-0043
already puts reachability. Slice 1 keeps the OCapN session key separate from the
iroh node key; unifying them (one key, one identity) is real follow-up work
named below, not an assumption baked in here.

**Blocking first, by the contracts already settled.** QUIC streams are
userspace, not fds, so the completion loop is not this transport's home —
ADR-0051 reserved exactly this case for the Netlayer contract, and ADR-0053's
cooperative blocking contract is the consumer shape slice 1 serves (`connectVia`
/ `acceptVia` through the registry, `ConnectedVat` above).

**The proof is live.** `zig build iroh-interop` runs two pancake peers over real
iroh endpoints on loopback — relay-less, dialed by node id with direct address
hints — through the keyed handshake to an open session and a bootstrap fetch
round-trip. The ALPN is `ocapn/pancake/1`.

**Amendment (2026-06-12): iroh reaches the bindings as a separate public C ABI
artifact.** Exposing iroh to the language bindings needs a C ABI, and folding it
into the core archive would drag cargo into every consumer of the pure-Zig core
— the rejected alternative below, applied one layer up. So the iroh transport
ships as its own _optional_ public archive built from
`src/c_abi/net_transport/iroh/`, kept out of the hermetic core: the `iroh-abi`
and `gen-header-net-transport-iroh` steps are cargo siblings of `check`, while
`check` still type-checks the ABI module as a cargo-free object plus
`gen-header-net-transport-iroh-check`.
Its composition and naming — a standalone companion archive that shares the core
C types by layout rather than re-exporting them — are governed by
[ADR-0059](ADR-0059-composable-c-abi-archives.md). On that artifact, all four
bindings (Deno, Python, Racket, Rust) gained `listen_iroh` for hosting and dial
an iroh peer through the same transport-neutral `connect` on an
`ocapn://<nodeid>.iroh?direct-addresses=…` locator (ADR-0062), reusing each
binding's existing in-process pump unchanged — only the frame source/sink moves
to the iroh FFI. `zig build demo-rooms-iroh` runs the cross-language rooms chat
(with its browser UI) over iroh end to end; a binding joins when its runtime and
the iroh ABI library are both present, the same join-when-available posture as
the TCP demo. Address discovery is unchanged from slice 1: relay-less, with
explicit direct-address hints carried in the locator — a loopback/LAN story, not
public-internet dialing.

**Amendment (2026-06-12): the seam and the public ABI carry distinct symbol
prefixes.** iroh exposes both a private byte-level seam (the Rust sidecar's C
ABI, consumed only by `src/net/transport/iroh.zig`) and a public frame-level ABI
(`src/c_abi/net_transport/iroh/mod.zig`, the binding-facing surface), and the
two link into
one library without colliding. They are split by prefix and by artifact name:

- The **private seam** is `pancake_iroh_sidecar_*`, declared in
  `transports/iroh/include/pancake_iroh_sidecar.h` and emitted by the staticlib
  `libpancake_iroh_sidecar.a` (the `[lib] name` in
  `transports/iroh/Cargo.toml`).
- The **public ABI** is `pancake_iroh_netlayer_*` / `pancake_iroh_conn_*`,
  declared in the generated header and shipped in the optional iroh archive
  (composed and named per [ADR-0059](ADR-0059-composable-c-abi-archives.md)).

The three hand-spelled copies of the seam (Rust definitions, the seam header,
the Zig externs) are held to one shape by the `pancake_iroh_sidecar_` ABI parity
check in `tools/meta_check.zig`. Nothing about the transport's behavior changed;
this is a naming boundary that makes the private/public split legible and
link-safe.

**Amendment (2026-06-12): the identity-and-discovery capstones landed.** The
three pieces the slice-1 decision named as follow-up are now shipped and proven
by `zig build iroh-interop`, which gained a deterministic proof for each:

- **Discovery / relays.** The endpoint takes a configurable, no-default
  `Reachability` (`direct`, `discovery`, `discovery_no_relay`,
  `local_discovery`) — a `u32` on `pancake_iroh_sidecar_endpoint_new` and the
  public `pancake_iroh_netlayer_new*`, surfaced as the `Reachability` enum /
  `IROH-REACH-*` constants in all four bindings. The gate dials by node id
  **alone** through the `local_discovery` address book (no direct-address
  hints); the public-internet posture (`discovery`) is the same path against n0
  relays plus pkarr/DNS. The no-default stance is deliberate: the relay/privacy
  posture is a visible choice at every constructor, never a hidden
  implementation detail.
- **Key unification.** `driver.connectVia` / `acceptVia` with a `.keyed`
  `Identity` sign the keyed `op:start-session` with a caller-supplied secret
  over the side's own dialable designator. When that secret is
  `crypto.SecretKey.fromSeed(seed)` against an endpoint seeded with the same
  `seed`, one Ed25519 key **is** the iroh node id, the OCapN locator designator,
  and the session signing key at once; the gate verifies it on both halves via
  `Session.partnerSessionKey` / `partnerDesignator`.
- **Durable identity.** A sturdyref (node id plus swiss-number) outlives an
  endpoint restart: same seed → same node id at a fresh address → the same
  published cap reached through the locator recorded before the restart.

The last piece of the cluster — **scale** — ships as
[ADR-0057](ADR-0057-iroh-completion-loop-bridge.md): the event-driven completion
loop (`iroh.LoopHost`, gated by `zig build iroh-loop`) is the iroh netlayer's
one I/O model and serves many concurrent connections from one loop thread. The
public iroh netlayer C ABI is loop-only — a readiness fd plus a non-blocking
drain, armed at construction, with no blocking frame surface — and every binding
parks on that fd natively (Python, Rust, and Racket gated by `bindings-iroh-loop`).
The cross-language
`demo-rooms-iroh` and the Deno iroh tests are flaky under load — an FFI-teardown
race plus message loss under many concurrent dials — so `iroh-interop` is the
authoritative, deterministic iroh gate.

## Scope (what this does not decide)

- **Goblins interop over iroh is not possible today**: Goblins ships no iroh
  netlayer, so this transport is the bring-your-own-netlayer contract proven
  pancake-to-pancake. The OCapN conversation it carries is the same one the TCP
  gates prove against Goblins.
- **Key unification, peer discovery, and durable identity** shipped — see the
  2026-06-12 "identity-and-discovery capstones" amendment above. (Relays and
  hole-punching themselves are sidecar-internal; pancake's part is the
  configurable posture, which landed.)
- **A completion-loop integration** for QUIC streams is not decided _here_; it
  shipped as [ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) — the
  event-driven sidecar bridge serving iroh at scale, now the netlayer's one I/O
  model.
- **The sidecar-versus-native tradeoff has a named flip condition.** A
  dependency this large is acceptable for an optional resident; it is not
  acceptable for a core product. If the encrypted channel becomes pancake's
  primary shipped transport — rather than one resident among several — the
  native-path question reopens, and two external facts gate its feasibility:
  iroh's relay and discovery protocols stabilizing into something a second
  implementation can target, and a production-hardened Zig QUIC stack existing.
  Until both hold, a native rewrite is a chase, not a project.

## Alternatives Considered

- **Native Zig QUIC + iroh protocols**: rejected for now — reimplementing QUIC,
  hole-punching, and the relay protocol is its own multi-year project, and the
  netlayer contract makes the sidecar replaceable if a native path ever earns
  itself.
- **iroh-ffi / UniFFI bindings**: rejected — the generated surface is shaped for
  mobile app consumers, not for a netlayer contract; a hand-rolled ABI of under
  a dozen functions is smaller than the glue UniFFI would generate.
- **Rust inside `libpancake`**: rejected outright — it would put cargo into
  every consumer's build and contradict the boring-artifact contract
  (`libpancake.a`, `libpancake.so`, `pancake.h`, pure Zig).

## Consequences

- New surfaces: `transports/iroh/` (Cargo.toml pinned to iroh `=1.0.0-rc.1`,
  `src/lib.rs`, `include/pancake_iroh_sidecar.h`), `src/net/transport/iroh.zig`,
  and the `iroh-lib` / `iroh-interop` build steps wired into `ci/gates.sh`.
- The README's "the shipped channel is cleartext TCP" boundary changes the day
  the gate is green: an encrypted channel exists behind the same contract, and
  the remaining boundary is discovery, relays, and identity unification — named,
  not implied.
- `Cargo.lock` is committed, diverging deliberately from `bindings/rust` (which
  dogfoods the in-tree ABI with a near-empty dependency tree and floats by
  design): the sidecar wraps an external network stack, and the lockfile is what
  makes the `iroh-interop` gate resolve the same dependency tree on every
  machine. Direct dependencies are additionally pinned exactly in `Cargo.toml`
  so an intentional bump is visible there.
