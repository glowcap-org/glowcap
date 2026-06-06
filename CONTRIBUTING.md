# Contributing to pancake

pancake is a codec-neutral CapTP core for OCapN, implemented in Zig. OCapN
behavior and Spritely Goblins fixtures are the conformance authority.

## Read first

1. [docs/architecture.md](docs/architecture.md) — memory, C ABI, and layer
   boundaries, plus the session representation.
2. [AGENTS.md](AGENTS.md) — first principles and the invariants every change
   preserves.
3. [.agents/rules/](.agents/rules/) — the focused rules (`project-values`,
   `architecture`, `memory`, `tests`, `resilience`, `cli`, …).
4. [docs/decisions/adr/](docs/decisions/adr/) — the accepted decision records.

## Scope

**In scope:** the CapTP loop; both codecs (Syrup, Cap'n Proto) and the
codec-dispatch boundary; the session state machine and tables; negotiation and
feature sets; the caller-owned `Peer` engine; the `net_adapter` byte-stream
netlayer; the C ABI surface; wire and vocabulary decisions.

**Out of scope:** new authority models; `std.Io` in the sync no-I/O core
(`foundation` / `model` / `codec` / `session` / `engine`); authority decisions
pushed down into codecs or adapters; production transports (TLS, QUIC/iroh) and
full-duplex backpressure, which ride the netlayer design still being settled.

## Decision records

Settled decisions land as ADRs in [docs/decisions/adr/](docs/decisions/adr/).
Write one when a change affects codec / netlayer boundaries, the session state
machine, negotiation, wire capability semantics, vocabulary, or layer
separation — and flip it to `accepted` *before* code is built against it.

## Conventions

- **Codec-neutral semantics, codec-specific encoding.** A feature in one codec
  without the other is incomplete (Invariant 8).
- **Authority lives in the session.** Codecs parse and render; they never decide
  whether a reference, answer, export, import, or release is valid.
- **Copies are named.** Every wire-path allocation or copy is forbidden,
  intentional, or measured — see [.agents/rules/memory.md](.agents/rules/memory.md).
- **Cap'n Proto vs capnp.** "Cap'n Proto" in prose; `capnp` in identifiers.
- **No external taste-reference names** in committed files; express the intent as
  Zig-native control, vocabulary, and tests.
- **Write the design first.**

## Review cadence

This is a one-person project ([@jimisaacs](https://codeberg.org/jimisaacs)).
Reviews are best-effort. The fastest path to merge is a green gate and a change
scoped to a single layer.

## Verifying changes

```sh
zig build check        # arch + meta gates, tests, oracle, examples, benchmark smokes
```

Focused steps while iterating:

```sh
zig build test           # unit + integration tests
zig build meta-check     # agent scaffolding + documented build-step parity
zig build oracle-check   # protocol manifest + Syrup fixture parity
zig build arch-check     # layer dependency DAG + no-std.Io-in-core gate
zig build examples       # build and run the public examples
zig build rust-dogfood   # Rust consumes the C ABI
zig build bindings       # rust + deno + python + racket C ABI smokes
zig build bench-codec    # codec / dispatch throughput
```

`zig build check` must be green before a change is complete. The architecture
gate ([tools/arch_check.zig](tools/arch_check.zig)) blocks layering violations.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE) — the
same terms as the project.
