# Contributing to glowcap

glowcap implements CapTP for OCapN in Zig. New to those names?
[Capabilities and CapTP](docs/capabilities.md) starts from first principles.
Participation in project spaces is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).

Before changing code, read [the vision](docs/vision.md) and the section of
[the architecture](docs/architecture.md) you will touch. [AGENTS.md](AGENTS.md)
routes agents and human contributors to the same focused rules.

This is a one-person project, so reviews are best-effort. A narrow change with
the right check is easiest to review. Read only the context needed, then widen
when a claim crosses a boundary. Use the
[issue tracker](https://github.com/jimisaacs/glowcap/issues) for questions.

AI-assisted contributions are welcome when a human submitter understands and
takes responsibility for the change. Describe material AI assistance in the
pull request, together with the checks you ran and any untested behavior.
The restrictions on contributions to other projects are separate and live in
[`PROVENANCE.md`](PROVENANCE.md#upstream-policies).

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
- A source file holds one subject and stops at 650 lines. The budget is
  enforced by `zig build source-check` and currently holds with no exceptions.
  Splitting a file to make room for your change is the ordinary way to work
  here, whoever wrote the file.
- Update docs that must match today's code in the same change as the code
  they describe. A claim that outlives the code is worse than no claim.

Changes to protocol semantics, session state, negotiation, vocabulary, or
codec, netlayer, and layer boundaries need a decision record. Copy
[the template](docs/decisions/adr/template.md) and accept the decision before
building against it.

New authority models and I/O inside the synchronous core are out of scope.
Encrypted channels between glowcap peers use iroh when discovery and NAT
traversal matter, or `noise-tcp` on a direct route. Sealed TCP is a Noise
channel, not TLS. Plain `tcp` stays cleartext.

## Dev environment

The committed [devcontainer](.devcontainer/) is the supported ready-to-build
environment. In the primary checkout, open the repository with **Dev
Containers: Reopen in Container**. The host initializer creates the ignored
checkout configuration and an isolated Docker egress network on first use.
The container then verifies its toolchains automatically. Run:

```sh
zig build check
zig build runtime-check
```

Toolchain versions live in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh), and
[dependencies](docs/dependencies.md) explains what each one is for. The
[devcontainer README](.devcontainer/README.md) covers maintenance and host
integration, including the one explicit port-offset choice required for a
linked worktree.

### Without the devcontainer

The repository also builds directly on Linux and macOS. Install the Zig
version declared as `ZIG_VERSION` in `.devcontainer/pins.sh`. The repository's
installer reads that pin and verifies the downloaded archive:

```sh
ZIG_INSTALL_DIR="$PWD/.local/zig" bash .devcontainer/image/zig.sh
export PATH="$PWD/.local/zig:$PATH"
conformance/bootstrap-submodules.sh
zig build test
```

The in-tree checks also use Deno, Racket, Cargo, and small host tools. Their
tested versions are listed in `.devcontainer/pins.sh`. The devcontainer remains
the ready-made path when you do not already have that toolchain.

## The checkout uses symlinks

Some committed paths are symlinks. The agent overlays use them, as do the
documentation site and rooms app when they load shared UI assets.

Linux and macOS need no extra setup. On Windows, enable Developer Mode or run
`git config core.symlinks true` before checkout. Otherwise Git writes the link
target as a small text file, often without an obvious error.
`zig build source-check` reports any broken link.

## Verifying changes

Choose the evidence that covers the changed boundary. Product source normally
runs `zig build check`. Add `zig build runtime-check` for application behavior,
child-process lifecycles, language workspaces, or live loopback paths. Run
`zig build source-check` for a plan-only or prose-only edit. Protocol claims
also need their focused oracle or external-authority step.

Agent sessions should invoke these through
`.agents/skills/work/bin/glowcap-dev`. From the host it enters this worktree's
running devcontainer. Inside that image it runs locally from the repository
root. Both paths apply the per-test deadline and per-worktree build lease. A
concurrent session reports the owner and exits instead of racing caches or
ports. `runtime-check` also serializes process families inside one build. A
host with the complete declared toolchain can still run `zig build` directly.

Focused steps while iterating:

```sh
zig build test                         # unit and integration tests
zig build test -Dtest-filter=session   # tests with "session" in the name
zig build source-check                 # cross-file source, docs, and repository contracts
zig build runtime-check                # process, application, and language-workspace checks
zig build infrastructure-check         # devcontainer and worktree integration behavior
zig build oracle-check                 # protocol scenarios and Syrup fixtures
zig build arch-check                   # dependency layers and core I/O ban
zig build examples                     # public examples
zig build cli-test                     # CapTP CLI golden tests
zig build fuzz                         # parsers and other untrusted inputs
zig build rust-dogfood                 # Rust binding check against the C ABI
zig build bindings                     # all language binding smoke tests
zig build bench-codec                  # codec and dispatch measurements
```

The complete product path is also available to contributors. `./glowcap`
prepares a missing installation, and `./glowcap install` uses the same verified
installer as a platform archive. `zig build rooms-build` stages
`zig-out/product` with the selected build options. `zig build rooms-release`
prepares it with ReleaseSafe and baseline CPU settings. On Linux,
`./glowcap apps rooms deployment up` prepares the current source with that
preset and builds its Docker image.

## Continuous integration

The repository defines separate workflows for
[checks](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml),
[the documentation site](https://github.com/jimisaacs/glowcap/actions/workflows/pages.yml),
and [tagged releases](https://github.com/jimisaacs/glowcap/actions/workflows/release.yml).
Pull requests run `zig build test` and `zig build fmt-check` in a 15-minute
Zig-only lane. Pushes to `main` and `dev` run the complete devcontainer check
and the macOS Zig test suite. The release workflow runs on `v*` tags and manual
dispatch. Tags publish after the matching check, while manual runs upload
artifacts without publishing. CI installs the versions declared in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh).

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms. See
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).

[PROVENANCE.md](PROVENANCE.md) explains how the repository is produced and
the upstream contribution limits that follow from it.
