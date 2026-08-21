# Contributing to pancake

pancake implements CapTP for OCapN in Zig. New to those names?
[Capabilities and CapTP](docs/capabilities.md) starts from first principles.

Before changing code, read [the vision](docs/vision.md) and the section of
[the architecture](docs/architecture.md) you will touch. [AGENTS.md](AGENTS.md)
routes agents and human contributors to the same focused rules.

This is a one-person project, so reviews are best-effort. A narrow change with
the right check is easiest to review. Read only the context needed, then widen
when a claim crosses a boundary. Use the
[issue tracker](https://github.com/jimisaacs/pancake/issues) for questions.

## Design boundaries

These rules define what fits the project:

- OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios
  decide correctness.
- Session logic is codec-neutral. A protocol feature must work through both
  Syrup and Cap'n Proto.
- The synchronous core (`foundation`, `model`, `codec`, `session`, `engine`)
  performs no I/O.
- The session owns authority. Codecs and adapters do not decide whether a
  reference is valid.
- Every wire-path allocation or copy is forbidden, intentional, or measured.
- A fact has one owner. Prefer a generated mirror or check step over a
  hand-kept copy.
- A source file holds one subject and stops at 650 lines. The files still
  over that line are listed in `tools/check/source_check/file_length.zig`, the
  list is closed to newcomers, and it is meant to reach zero. Splitting a file
  to make room for your change is the ordinary way to work here, whoever wrote
  the file, and taking a file off that list is welcome on its own.
- Update docs kept in step with today's code in the same change as the code
  they describe. A claim that outlives the code is worse than no claim.

Changes to protocol semantics, session state, negotiation, vocabulary, or
codec, netlayer, and layer boundaries need a decision record. Copy
[the template](docs/decisions/adr/template.md) and accept the decision before
building against it.

New authority models and I/O inside the synchronous core are out of scope.
Encrypted channels between pancake peers use iroh when discovery and NAT
traversal matter, or `noise-tcp` on a direct route. Sealed TCP is a Noise
channel, not TLS; plain `tcp` stays cleartext.

## Dev environment

The committed [devcontainer](.devcontainer/) is the supported ready-to-build
environment. In the primary checkout, open the repository with **Dev
Containers: Reopen in Container**. The host initializer creates the ignored
checkout configuration and an isolated Docker egress network on first use;
the container then verifies its toolchains automatically. Run:

```sh
zig build check
```

Toolchain versions live in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh). The
[devcontainer README](.devcontainer/README.md) covers maintenance and host
integration, including the one explicit port-offset choice required for a
linked worktree.

## The checkout uses symlinks

Some committed paths are symlinks. The agent overlays use them, as do the
documentation site and rooms app when they load shared UI assets.

Linux and macOS need no extra setup. On Windows, enable Developer Mode or run
`git config core.symlinks true` before checkout. Otherwise Git writes the link
target as a small text file, often without an obvious error.
`zig build source-check` reports any broken link.

## Verifying changes

```sh
zig build check
```

Run the full check by itself. It binds loopback ports and times a ReleaseFast
build; another build running beside it can stall both. It must pass before a
change is complete.

Focused steps while iterating:

```sh
zig build test                         # unit and integration tests
zig build test -Dtest-filter=session   # tests with "session" in the name
zig build source-check                 # cross-file source, docs, and repository contracts
zig build oracle-check                 # protocol scenarios and Syrup fixtures
zig build arch-check                   # dependency layers and core I/O ban
zig build examples                     # public examples
zig build cli-test                     # CapTP CLI golden tests
zig build fuzz                         # parsers and other untrusted inputs
zig build rust-dogfood                 # Rust binding check against the C ABI
zig build bindings                     # all language binding smoke tests
zig build bench-codec                  # codec and dispatch measurements
```

## Continuous integration

GitHub has separate workflows for
[checks](https://github.com/jimisaacs/pancake/actions/workflows/check.yml),
[the documentation site](https://github.com/jimisaacs/pancake/actions/workflows/pages.yml),
and [tagged releases](https://github.com/jimisaacs/pancake/actions/workflows/release.yml).
Check the current commit's results before relying on them. CI installs the same
versions declared in [`.devcontainer/pins.sh`](.devcontainer/pins.sh).

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms; see
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).

[PROVENANCE.md](PROVENANCE.md) explains how the repository is produced and
the upstream contribution limits that follow from it.
