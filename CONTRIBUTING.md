# Contributing to glowcap

glowcap implements CapTP for OCapN in Zig. New to those names?
[Capabilities and CapTP](docs/capabilities.md) starts from first principles.
Participation in project spaces is governed by the
[Code of Conduct](CODE_OF_CONDUCT.md).

Before changing code, read [the vision](docs/vision.md) and the section of
[the architecture](docs/architecture.md) you will touch. [AGENTS.md](AGENTS.md)
routes agents and human contributors to the same focused rules.

This is a one-person project, so reviews are best-effort. A narrow change with
the right check is easiest to review. Use the
[issue tracker](https://github.com/jimisaacs/glowcap/issues) for questions.

AI-assisted contributions are welcome when a human submitter understands and
takes responsibility for the change. Describe material AI assistance in the
pull request, together with the checks you ran and any untested behavior.
The restrictions on contributions to other projects are separate and live in
[`PROVENANCE.md`](PROVENANCE.md#upstream-policies).

## Design boundaries

- OCapN behavior, Spritely Goblins fixtures, and glowcap's own Zig protocol
  tests decide correctness.
- Session logic is codec-neutral. A protocol feature must work through both
  Syrup and Cap'n Proto.
- The synchronous core (`foundation`, `model`, `codec`, `session`, `engine`)
  performs no I/O.
- The session decides whether a reference is valid. Codecs and adapters do
  not.
- Every allocation or copy a message goes through is forbidden, intentional,
  or measured.
- A fact has one owner. Prefer a generated mirror or check step over a
  hand-kept copy.
- A source file holds one subject and stays under the line limit that
  `zig build source-check` holds, with no exceptions. Splitting a file to
  make room for your change is the ordinary way to work
  here, whoever wrote the file.
- Update docs that must match the code in the same change as the code
  they describe. A claim that outlives the code is worse than no claim.

Changes to protocol semantics, session state, negotiation, vocabulary, or
codec, netlayer, and layer boundaries need a decision record. Copy
[the template](docs/decisions/adr/template.md) and accept the decision before
building against it.

New ways to grant access, and I/O inside the synchronous core, are out of scope.

## Dev environment

The committed [devcontainer](.devcontainer/) is the supported ready-to-build
environment. In the primary checkout, open the repository with **Dev
Containers: Reopen in Container**. On first use, it writes a local `.env`
(never committed) and creates a private Docker network for the container's
outbound traffic.
The container then verifies its toolchains automatically. Run:

```sh
zig build check
zig build runtime-check
```

Toolchain versions live in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh), and
[dependencies](docs/dependencies.md) explains what each one is for. The
[devcontainer README](.devcontainer/README.md) covers maintenance and host
integration, including the port offset a second
worktree has to choose.

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

The in-tree checks also use the other tools [dependencies](docs/dependencies.md)
lists. The devcontainer remains the ready-made path when you do not already
have them.

## The checkout uses symlinks

Some committed paths are symlinks. The agent overlays use them, as do the
documentation site and rooms app when they load shared UI assets.

Linux and macOS need no extra setup. On Windows, enable Developer Mode or run
`git config core.symlinks true` before checkout. Otherwise Git writes the link
target as a small text file, often without an obvious error.
`zig build source-check` reports any broken link.

## Verifying changes

Run the check that covers what you changed. A change to product code normally
runs `zig build check`. Add `zig build runtime-check` for application behavior,
child-process lifecycles, language workspaces, or live loopback paths. Run
`zig build source-check` for a plan-only or prose-only edit. A protocol claim
also needs the step that checks it against the reference fixtures or an outside
implementation such as Goblins.

`.agents/skills/work/bin/glowcap-dev zig build check` runs a build inside
the worktree's devcontainer, one build per worktree at a time. A second build
names the one running and exits. Plain `zig build` works on a host with every
tool installed.

While iterating, narrow a run to the tests whose names match:

```sh
zig build test -Dtest-filter=session
```

[Build steps](docs/build-steps.md) explains every focused step.

To try the whole product the way a user gets it:

- `./glowcap install` builds, verifies, and installs it, using the same
  installer as a release archive. Plain `./glowcap` installs it first when
  needed.
- `zig build rooms-build` stages it under `zig-out/product` without
  installing. `zig build rooms-release` does the same with release settings.
- On Linux, `./glowcap apps rooms deployment up` builds a Docker image from
  your checkout with those release settings and starts it.

## Continuous integration

These workflows run on GitHub, and CI installs the versions declared in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh):

- [Checks](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml):
  pull requests run a quick Zig-only job. Pushes to `main` and `dev` run every
  step in [`ci/gates.sh`](ci/gates.sh) inside the devcontainer image. A macOS
  job runs the host-side infrastructure checks and the Zig and Loam storage
  tests. A nightly schedule runs a longer fuzz search.
- [Documentation site](https://github.com/jimisaacs/glowcap/actions/workflows/pages.yml).
- [Tagged releases](https://github.com/jimisaacs/glowcap/actions/workflows/release.yml):
  runs on `v*` tags and manual dispatch. Tags publish after the matching check,
  and manual runs upload artifacts without publishing.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms. See
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).
