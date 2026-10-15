---
id: ADR-0055
status: accepted
date: 2026-06-11
tags: [net, netlayer, iroh, transport, identity]
decision: "The iroh netlayer is a Rust sidecar: a separate staticlib crate (transports/iroh) wraps the iroh crate behind a narrow C ABI with explicit blocking calls for the blocking resident and one readiness fd for evented dial, accept, and stream I/O. One Zig resident (net/transport/iroh.zig) implements both the ADR-0043 Netlayer contract and the completion backend over that seam. libglowcap and the core stay pure Zig. Only the iroh build steps need cargo. The iroh NodeId is the locator designator under the transport symbol `iroh`. The live proof is a glowcap-to-glowcap keyed session over real iroh endpoints."
supersedes: []
superseded_by: []
---

# ADR-0055 The iroh netlayer is a Rust sidecar behind the netlayer contract

## Context

The vision names a QUIC-based peer-to-peer netlayer in the iroh shape as the
secure-transport destination: an encrypted ordered channel, NAT traversal and
relays, and a self-authenticating node identity that is also OCapN's designator.
The substrate was finished first: the netlayer contract exists (ADR-0043) with
two residents, the completion loop owns both directions (ADR-0051), and the
buffer floor is shared (ADR-0054). iroh ships as a Rust crate (`iroh`, pinned at
`1.0.2`) that Zig cannot import, so the first question is where the Rust
boundary sits.

## Decision

**A sidecar staticlib, never a core dependency.** A crate at `transports/iroh/`
wraps the iroh endpoint behind a narrow, hand-written C ABI
(`glowcap_iroh_sidecar_*`): create an endpoint (owning its tokio runtime behind
the opaque handle), read its node id and direct addresses, and drive one
bidirectional QUIC stream per connection. Explicitly named blocking calls serve
the blocking resident. Request-correlated connect completion, accept, and
stream readiness share one endpoint readiness fd for completion consumers. The
Zig side is the supported `src/net/transport/iroh.zig` facade over an internal
`iroh/` package: `sidecar.zig` owns those externs and `resident.zig` implements
the ADR-0043 `Netlayer` contract, pinning its concrete stream wrappers as
`net.tcp` does. `libglowcap`, the core layers, and every existing gate stay pure
Zig. The `iroh-*` build steps require cargo on PATH and run as sibling steps,
like `rust-dogfood`.

**The node id is the designator.** An iroh NodeId is an Ed25519 public key,
which is OCapN's self-authenticating designator. The transport symbol is `iroh`,
the locator designator is the node id in its canonical 64-character lowercase-hex
form (the form `Resident.nodeId` prints and `dial` accepts), and relay or direct
addresses ride the locator's hints, where ADR-0043 puts reachability.

**Blocking and completion contracts.** QUIC streams are userspace, not
per-stream fds. ADR-0053's cooperative blocking contract uses the blocking
resident (`connectVia` / `acceptVia` through the registry, `BlockingSession`
above). ADR-0057 adapts the sidecar's single endpoint readiness fd into the
completion loop, so an evented caller never offloads a blocking dial to regain
an async surface.

**Live proof.** `zig build iroh-interop` runs two glowcap peers over real iroh
endpoints on loopback, relay-less and dialed by node id with direct address
hints, through the keyed handshake to an open session and a bootstrap fetch
round-trip. The ALPN is `ocapn/glowcap/1`. It also proves discovery, key
unification, and durable identity (below). `iroh-interop` is the authoritative,
deterministic iroh gate. The cross-language `demo-rooms-iroh` and the Deno iroh
tests are flaky under load (an FFI-teardown race plus message loss under many
concurrent dials).

### Binding ABI and symbol prefixes

Exposing iroh to the language bindings needs a C ABI. Folding it into the core
archive would put cargo into every consumer of the pure-Zig core (the rejected
alternative below, one layer up), so the iroh transport ships as its own
optional public archive built from `src/c_abi/net_transport/iroh/`. The
`iroh-abi` and `gen-header-net-transport-iroh` steps are cargo siblings of
`check`, while `check` type-checks the ABI module as a cargo-free object plus
`gen-header-net-transport-iroh-check`. The archive is a standalone companion
that shares the core C types by layout instead of re-exporting them
([ADR-0059](ADR-0059-composable-c-abi-archives.md) governs composition and
naming). All four bindings (Deno, Python, Racket, Rust) offer `listen_iroh` for
hosting and dial an iroh peer through the transport-neutral `connect` on an
`ocapn://<nodeid>.iroh?direct-addresses=…` locator (ADR-0062), reusing each
binding's in-process pump with the frame source/sink moved to the iroh FFI. A
binding joins when its runtime and the iroh ABI library are both present, as
with the TCP demo.

The private byte-level seam and the public frame-level ABI link into one library
without colliding because they differ by prefix and artifact name:

- The private seam is `glowcap_iroh_sidecar_*`, declared in
  `transports/iroh/include/glowcap_iroh_sidecar.h`, consumed only by
  `src/net/transport/iroh/sidecar.zig`, and emitted by the staticlib
  `libglowcap_iroh_sidecar.a` (the `[lib] name` in `transports/iroh/Cargo.toml`).
- The public ABI is `glowcap_iroh_netlayer_*` / `glowcap_iroh_conn_*`
  (`src/c_abi/net_transport/iroh/mod.zig`), declared in the generated header and
  shipped in the optional iroh archive.

The three hand-written copies of the seam (Rust definitions, the seam header,
the Zig externs) are held to one shape by the `glowcap_iroh_sidecar_` ABI parity
check in `tools/check/source_check.zig`.

### Discovery, key unification, durable identity

- **Discovery / relays.** The endpoint takes a configurable `Reachability` with
  no default (`direct`, `discovery`, `discovery_no_relay`, `local_discovery`): a
  `u32` on `glowcap_iroh_sidecar_endpoint_new` and the public
  `glowcap_iroh_netlayer_*`, surfaced as the `Reachability` enum /
  `IROH-REACH-*` constants in all four bindings. The relay and privacy posture
  is therefore a visible choice at every constructor. The gate dials by node id
  alone through the `local_discovery` address book (no direct-address hints).
  `discovery` is the same path against n0 relays plus pkarr/DNS. Relays and
  hole-punching are sidecar-internal. Without discovery, dialing uses explicit
  direct-address hints in the locator (a loopback/LAN story).
- **Key unification.** `driver.connectVia` / `acceptVia` with a `.keyed`
  `Identity` sign the keyed `op:start-session` with a caller-supplied secret over
  the side's own dialable designator. When that secret is
  `crypto.SecretKey.fromSeed(seed)` and the endpoint is seeded with the same
  `seed`, one Ed25519 key is the iroh node id, the OCapN locator designator, and
  the session signing key. The gate verifies both halves via
  `Session.partnerSessionKey` / `partnerDesignator`.
- **Durable identity.** A sturdyref (node id plus swiss-number) outlives an
  endpoint restart: the same seed yields the same node id at a fresh address, so
  the same published cap is reached through the locator recorded before the
  restart.

### Scale

[ADR-0057](ADR-0057-iroh-completion-loop-bridge.md) makes the event-driven
completion loop (`iroh.Backend` + Bridge, gated by `zig build iroh-loop`) the
iroh netlayer's one I/O model. It serves many concurrent connections from one
loop thread. The public iroh netlayer C ABI is loop-only: a readiness fd plus a
non-blocking drain, armed at construction, with no blocking frame surface. Every
binding parks on that fd natively (Python, Rust, and Racket gated by
`bindings-iroh-loop`).

## Scope (what this does not decide)

- **Goblins interop over iroh.** Goblins ships no netlayer of its own, so this
  ADR proves the bring-your-own-netlayer contract glowcap-to-glowcap. An iroh
  netlayer for Goblins lives in `conformance/goblins-peer/racket/` over the
  Racket binding's byte-channel surface, and `zig build goblins-iroh` holds a
  live session across it. The OCapN conversation it carries is the one the TCP
  gates prove.
- **The sidecar-versus-native tradeoff has a flip condition.** A dependency this
  large is acceptable for an optional resident and not for a core product. If
  the encrypted channel becomes glowcap's primary shipped transport, the
  native-path question reopens, gated by two external facts: iroh's relay and
  discovery protocols stabilizing into something a second implementation can
  target, and a production-hardened Zig QUIC stack existing. Until both hold, a
  native rewrite is a chase, not a project.

## Alternatives Considered

- **Zig QUIC + iroh protocols.** Rejected for now: reimplementing QUIC,
  hole-punching, and the relay protocol is a multi-year project, and the
  netlayer contract makes the sidecar replaceable.
- **iroh-ffi / UniFFI bindings.** Rejected: the generated surface is shaped for
  mobile app consumers, not a netlayer contract, and a hand-rolled ABI of under
  a dozen functions is smaller than the generated glue.
- **Rust inside `libglowcap`.** Rejected: it would put cargo into every
  consumer's build and contradict the pure-Zig artifact contract
  (`libglowcap.a`, `libglowcap.so`, `glowcap.h`).

## Consequences

- New surfaces: `transports/iroh/` (Cargo.toml pinned to iroh `=1.0.2`,
  `src/lib.rs`, `include/glowcap_iroh_sidecar.h`), the supported
  `src/net/transport/iroh.zig` facade and internal `iroh/` package, and the
  `iroh-lib` / `iroh-interop` build steps wired into `ci/gates.sh`.
- An encrypted channel exists behind the netlayer contract, so the README's "the
  shipped channel is cleartext TCP" boundary no longer holds.
- `Cargo.lock` is committed, unlike `bindings/rust` (which dogfoods the in-tree
  ABI with a near-empty dependency tree and floats). The sidecar wraps an
  external network stack, and the lockfile makes the `iroh-interop` gate resolve
  the same dependency tree on every machine. Direct dependencies are also pinned
  exactly in `Cargo.toml` so a bump is visible there.
