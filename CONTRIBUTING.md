# Contributing to pancake

pancake is a CapTP core for OCapN, implemented in Zig. If those names are new,
[docs/capabilities.md](docs/capabilities.md) explains them from zero. OCapN
behavior and Spritely Goblins fixtures decide what counts as correct here.

## Read first

1. [docs/vision.md](docs/vision.md): where the project is going; read before
   scoping.
2. [docs/architecture.md](docs/architecture.md): memory, C ABI, and layer
   boundaries, plus the session representation.
3. [docs/decisions/adr/](docs/decisions/adr/): the accepted decision records.
4. [PROVENANCE.md](PROVENANCE.md): how pancake is built, and what that means for
   contributions you send elsewhere.

Most of the work here is done by AI agents, so the project's conventions are
written as instructions an agent can execute: [AGENTS.md](AGENTS.md) holds the
first principles and the invariants every change preserves, and
[.agents/rules/](.agents/rules/) breaks them into focused rules
(`project-values`, `architecture`, `memory`, `tests`, `resilience`, `cli`). They
are worth reading whoever you are — they are the real conventions, just written
in the imperative.

## Scope

**In scope:**

- the CapTP loop, the session state machine and its tables, and the
  caller-owned `Peer` engine;
- both codecs (Syrup, Cap'n Proto) and the codec-dispatch boundary;
- negotiation and feature sets;
- the `net` netlayer contract and its residents (`tcp`, `keyed-tcp`,
  `inproc`, iroh, webrtc);
- the C ABI surface, and wire and vocabulary decisions.

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
- **Write the design first.** A change that moves a boundary gets its decision
  record accepted before the code that depends on it exists.

## Review cadence

This is a one-person project ([@jimisaacs](https://codeberg.org/jimisaacs)), so
reviews and issue-tracker replies are both best-effort. The fastest path to
merge is a green `zig build check` and a change scoped to a single layer.
Questions go through the
[Codeberg issue tracker](https://codeberg.org/jimisaacs/pancake/issues). That is
the address until the hosting decision below lands; if the project moves, the
[GitHub mirror](https://github.com/jimisaacs/pancake/issues) is where it goes.

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

## Try CapTP from the shell

```sh
zig build
export PATH="$PWD/zig-out/bin:$PATH"
pancake help
```

For a two-terminal echo round-trip, REPL, or stdio MCP over CapTP, follow
[`docs/cli.md`](docs/cli.md). That binary is the product adapter over the same
library, not a second protocol stack. Room presence uses `pancake app rooms-peer`
(see the rooms app README).

## The checkout uses symlinks

Some committed paths are symlinks, and the repository does not work without
them. `CLAUDE.md` points at `AGENTS.md`, the editor overlays point into
`.agents/`, and both user interfaces reach their shared palette and typefaces
through `ui/`.

On Linux and macOS this needs nothing. On Windows, git only materialises
symlinks with Developer Mode enabled or `git config core.symlinks true`;
without that it writes each one as a small text file containing the target
path. Nothing errors. The documentation site simply renders unstyled, because
its stylesheet is a file whose contents are `../../ui/tokens.css`. There is no
Windows runner in continuous integration, so nothing else will catch it either.
`zig build meta-check` does: it fails with the path and the target it expected.

## Verifying changes

```sh
zig build check        # arch + meta checks, tests, reference fixtures, examples, benchmark smokes
```

Run it alone. It binds real loopback ports and times a ReleaseFast build, so a
second build running beside it — another terminal, an editor building on save —
makes both look like they have hung.

Focused steps while iterating:

```sh
zig build test           # unit + integration tests
zig build test -Dtest-filter=session   # only tests whose names contain "session"
zig build meta-check     # documented build steps, overlays, and doc registry
zig build oracle-check   # protocol reference fixtures + Syrup fixture parity
zig build arch-check     # layer dependency DAG + no std.Io in the core
zig build examples       # build and run the public examples
zig build cli-test       # self-contained CapTP CLI golden tests
zig build fuzz           # mutation-fuzz the surfaces that take somebody else's bytes
zig build rust-dogfood   # Rust consumes the C ABI (binding smoke)
zig build bindings       # rust + deno + bun + python + racket C ABI smokes
zig build bench-codec    # codec / dispatch throughput
```

`zig build check` must be green before a change is complete. The architecture
check ([tools/check/arch_check.zig](tools/check/arch_check.zig)) blocks layering violations.

## Continuous integration

Codeberg is still the origin pending a maintainer hosting decision, but no
project workflow runs on its donation-funded runners. The [GitHub mirror](https://github.com/jimisaacs/pancake/actions/workflows/check.yml)
([.github/workflows/](.github/workflows/)) is configured for the correctness
suite, the full sequence ([`ci/gates.sh`](ci/gates.sh) inside the devcontainer
image), GitHub Pages, and the tagged release build. A workflow file is not proof
that a run completed; check the current commit's result before relying on the
automatic coverage. Every CI job installs toolchains through
the checksummed [`.devcontainer/`](.devcontainer/) installers, so the pins in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh) are the one version
authority.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms; see
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).
