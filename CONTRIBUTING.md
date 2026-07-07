# Contributing to pancake

pancake is a codec-neutral CapTP core for OCapN, implemented in Zig. OCapN
behavior and Spritely Goblins fixtures are the conformance authority.

## Read first

1. [docs/vision.md](docs/vision.md) — where the project is going; read before
   scoping.
2. [docs/architecture.md](docs/architecture.md) — memory, C ABI, and layer
   boundaries, plus the session representation.
3. [AGENTS.md](AGENTS.md) — first principles, the Start Here router, and the
   invariants every change preserves.
4. [.agents/rules/](.agents/rules/) — the focused rules (`project-values`,
   `architecture`, `memory`, `tests`, `resilience`, `cli`, …).
5. [docs/decisions/adr/](docs/decisions/adr/) — the accepted decision records.

Substantial changes (features, sweeps, architectural moves) also follow
[.agents/skills/work/SKILL.md](.agents/skills/work/SKILL.md).

## Scope

**In scope:** the CapTP loop; both codecs (Syrup, Cap'n Proto) and the
codec-dispatch boundary; the session state machine and tables; negotiation and
feature sets; the caller-owned `Peer` engine; the `net` netlayer contract and
its residents (tcp, inproc, iroh); the C ABI surface; wire and vocabulary
decisions.

**Out of scope:** new authority models; `std.Io` in the sync no-I/O core
(`foundation` / `model` / `codec` / `session` / `engine`); authority decisions
pushed down into codecs or adapters; TLS over TCP (not implemented, since the
encrypted channel is the iroh netlayer, ADR-0055).

## Decision records

Settled decisions land as ADRs in [docs/decisions/adr/](docs/decisions/adr/);
start from [the template](docs/decisions/adr/template.md). Write one when a
change affects codec / netlayer boundaries, the session state machine,
negotiation, wire capability semantics, vocabulary, or layer separation, and
flip it to `accepted` _before_ code is built against it.

## Conventions

- **Codec-neutral semantics, codec-specific encoding.** A feature in one codec
  without the other is incomplete.
- **Authority lives in the session.** Codecs parse and render; they never decide
  whether a reference, answer, export, import, or release is valid.
- **Copies are named.** Every wire-path allocation or copy is forbidden,
  intentional, or measured, see
  [.agents/rules/memory.md](.agents/rules/memory.md).
- **Cap'n Proto vs capnp.** "Cap'n Proto" in prose; `capnp` in identifiers.
- **No external taste-reference names** in committed files; express the intent
  as Zig-native control, vocabulary, and tests.
- **Write the design first.**

## Review cadence

This is a one-person project ([@jimisaacs](https://codeberg.org/jimisaacs)).
Reviews are best-effort. The fastest path to merge is a green gate and a change
scoped to a single layer. Questions go through the
[Codeberg issue tracker](https://codeberg.org/jimisaacs/pancake/issues);
turnaround is best-effort too.

## Dev environment

The committed [`.devcontainer/`](.devcontainer/) is the canonical ready-to-build
environment. Open with _Dev Containers: Reopen in Container_, then:

```sh
bash .devcontainer/post-create.sh
zig build check
```

Toolchain pins live in [`.devcontainer/pins.sh`](.devcontainer/pins.sh);
boundaries and environment notes in
[`.devcontainer/README.md`](.devcontainer/README.md).

## Verifying changes

```sh
zig build check        # arch + meta gates, tests, oracle, examples, benchmark smokes
```

Focused steps while iterating:

```sh
zig build test           # unit + integration tests
zig build test -Dtest-filter=session   # only tests whose names contain "session"
zig build meta-check     # agent scaffolding + documented build-step parity
zig build oracle-check   # protocol manifest + Syrup fixture parity
zig build arch-check     # layer dependency DAG + no-std.Io-in-core gate
zig build examples       # build and run the public examples
zig build rust-dogfood   # Rust consumes the C ABI
zig build bindings       # rust + deno + bun + python + racket C ABI smokes
zig build bench-codec    # codec / dispatch throughput
```

`zig build check` must be green before a change is complete. The architecture
gate ([tools/arch_check.zig](tools/arch_check.zig)) blocks layering violations.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE), the
same terms as the project.
