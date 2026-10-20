# Contributing to glowcap

Bug reports, focused fixes, tests, and documentation improvements are welcome.
Open a pull request against `dev`. For a substantial design change, open an
issue first to agree on the approach. Reviews are best-effort in this
one-maintainer project.

The [bug report form](.github/ISSUE_TEMPLATE/bug_report.md) lists what a report
needs, and a fix is optional. Send suspected vulnerabilities through
[the security policy](SECURITY.md).
[Issues](https://github.com/jimisaacs/glowcap/issues) and
[the roadmap](docs/roadmap.md) show the work under discussion.

## Get a working checkout

The checkout uses symlinks. On Windows, enable Developer Mode and configure
Git to preserve symlinks before cloning.

Clone the development branch and create a branch for your change:

```sh
git clone --branch dev https://github.com/jimisaacs/glowcap.git
cd glowcap
git switch -c fix-description
```

For the Zig test suite on Linux or macOS, you need Git, Python 3, and the
pinned Zig compiler. The installer uses Bash, curl, tar, and xz support,
verifies the download, and installs inside this checkout:

```sh
ZIG_INSTALL_DIR="$PWD/.local/zig" bash .devcontainer/image/zig.sh
export PATH="$PWD/.local/zig:$PATH"
zig build test --test-timeout 30s
```

The first build downloads the dependencies declared in `build.zig.zon`.
Compiler and toolchain versions live in
[`.devcontainer/pins.sh`](.devcontainer/pins.sh).

For the full checks, use the committed [devcontainer](.devcontainer/README.md).
Open the checkout with **Dev Containers: Reopen in Container**. Setup installs
the other toolchains and initializes the conformance submodules. Once setup
finishes, run `zig build check`. A host setup can use
[the dependency list](docs/dependencies.md) and
`conformance/bootstrap-submodules.sh` instead.

## Make a change

Start with the tests and implementation for the area you are changing.
[Architecture](docs/architecture.md) explains the layers, and
[the vision](docs/vision.md) explains the project's scope.

Keep fixes focused. Add a regression test for a behavior change and update
any documentation it makes untrue. Separate prerequisite refactoring from the
fix so each can be reviewed on its own.

While iterating, compile one layer or run tests whose names match a substring:

```sh
zig build test -Dtest-layer=session --test-timeout 30s
zig build test -Dtest-filter=session --test-timeout 30s
```

A passing filtered run covers only the selected tests. Before submitting, run
the unfiltered check for the affected area:

| Change | Check |
| --- | --- |
| Zig implementation | `zig build check` |
| Process or application behavior, language workspaces | Also `zig build runtime-check` |
| Documentation | `zig build source-check` |

[Build steps](docs/build-steps.md) lists focused checks for bindings, examples,
protocol conformance, and other areas. If you cannot run a required check,
say which one and why in the pull request.

Keep these design constraints:

- OCapN behavior, Goblins fixtures, and Zig protocol scenarios decide protocol
  correctness. Bindings consume the protocol implementation.
- Session logic is codec-neutral. Protocol behavior works through Syrup and
  Cap'n Proto.
- The synchronous core performs no I/O. Ownership, allocations, and copying
  remain explicit.
- Source files have a clear subject and stay within the limit enforced by
  `source-check`.

A change to an architectural contract needs a
[decision record](docs/decisions/README.md), and that page says which changes
qualify.

## Open a pull request

Fork the repository on GitHub, then publish your branch to your fork:

```sh
git remote add fork https://github.com/YOUR-USERNAME/glowcap.git
git push -u fork fix-description
```

Open a pull request from that branch to `jimisaacs/glowcap:dev`. Describe the
problem, resulting behavior, validation, and any untested paths. Link an issue
or decision record when relevant. Draft pull requests are welcome for early
feedback.

The maintainer reviews the diff and checks before accepting it. Keep
follow-up changes on the same branch so the discussion and checks stay together.
An accepted change lands on `dev` as one commit signed by the maintainer that
keeps you as its author, and the pull request closes naming that commit.

AI assistance is welcome on the terms the maintainer works under: the person
who submits a change can explain every line of it, answers for it in review,
and says in the pull request what an assistant did. A change its submitter
cannot explain is not ready. The maintainer signs each commit on `dev` at
integration, so the signature on a landed commit names who vouched for it.
[PROVENANCE.md](PROVENANCE.md) records how the project itself is built and
lists upstream projects whose policies restrict AI-assisted work.
Participation follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Continuous integration

For pull requests, the configured workflow runs Debug and ReleaseSafe Zig tests,
source and documentation checks, and formatting. Pushes to `main` or `dev`
also run [`ci/gates.sh`](ci/gates.sh) and the macOS checks. `main` is a
fast-forward of `dev`, so a published commit is one those runs checked.
A nightly run searches longer with the mutation fuzzer.

Coding-agent installation has a [separate workflow](.github/workflows/agent-tools.yml)
for devcontainer changes and manual runs. Product checks do not wait for
coding-agent downloads.

Execution requires available GitHub-hosted runners. Local checks remain the
way to validate a change when hosted runs are unavailable.
The commands are in the [checks workflow](.github/workflows/check.yml).
[Maintaining glowcap](docs/maintaining.md) covers how `dev` reaches `main` and
how releases are published.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms. See
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).
