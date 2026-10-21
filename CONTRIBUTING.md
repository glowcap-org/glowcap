# Contributing to glowcap

Bug reports, focused fixes, tests, and documentation improvements are welcome.
Open a pull request against `dev`. For a substantial design change, open an
issue first to agree on the approach. Glowcap LLC maintains the project.
Reviews are best-effort.

The [bug report form](.github/ISSUE_TEMPLATE/bug_report.md) lists what a report
needs, and a fix is optional. Send suspected vulnerabilities through
[the security policy](SECURITY.md).
[Issues](https://github.com/glowcap-org/glowcap/issues) and
[the roadmap](docs/roadmap.md) show the work under discussion.

## Get a working checkout

The checkout uses symlinks. On Windows, enable Developer Mode and configure
Git to preserve symlinks before cloning.

Clone the development branch and create a branch for your change:

```sh
git clone --branch dev https://github.com/glowcap-org/glowcap.git
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

## Preview startup

`zig build docs-serve` and `zig build rooms-dev` build their prerequisites
before starting a server. A fresh checkout or empty build cache can spend
several minutes downloading and compiling dependencies. Wait for the server's
listening address before opening the page. The development environment front
prints a preparation notice before the build starts.

The website preview also captures Rooms screenshots when none are cached in
`site/assets/`. That preparation builds Rooms and runs browser scenes before
compiling Zine. Later previews reuse those screenshots. Run
`zig build site-captures` when you need fresh pictures.

Rooms builds its Zig libraries and Rust services. Browser commands also build
WebAssembly and prepare UI assets. Later launches reuse unchanged build
outputs. Keep the dev server running while editing UI code to use Fast Refresh
instead of rebuilding the services. See [Developing Rooms](apps/rooms/developing.md).

A build failure is not normal first-run setup. Keep the first error and command
when reporting it. Repeated full compilation with unchanged sources and the
same toolchain also warrants investigation. Avoid deleting caches as a first
response: doing so guarantees another cold build.

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

Open a pull request from that branch to `glowcap-org/glowcap:dev`. Describe the
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

Every pull request and push to `dev` runs core, memory, runtime, infrastructure,
and browser/interoperability smoke checks, plus macOS tests. Core validation
includes source checks and Zig tests in Debug and ReleaseSafe. ReleaseSafe
compiles in groups to bound memory use, with every test layer covered. The
[coverage selector](ci/plan.py) adds deeper jobs for changed subsystems:

| Changed files | Additional Linux jobs |
| --- | --- |
| Documentation | None |
| Loam | Browser |
| Python or Racket bindings | Bindings and interoperability |
| Conformance fixtures | Interoperability |
| Shared protocol, runtime, C ABI, Rust, TypeScript, or applications | All |
| Build, CI, fuzz tests, or unclassified files | All, with full qualification |

Shared-code changes exercise all consumers but leave mutation fuzzing to full
qualification. Missing comparison history selects full validation. Renames
account for both source and destination paths.
Selection uses the complete push diff or the pull request's merge result.

Main pushes, pull requests targeting main, nightly runs, and manual
`suite=check` runs always execute the complete [`ci/gates.sh`](ci/gates.sh)
sequence. Full validation includes bounded mutation fuzzing. Nightly runs also
search deeper with the fuzzer, as does a manual `suite=fuzz` run.

Development runs report `dev-gates`. Only complete validation reports `gates`,
which the main ruleset requires. Before promotion, run full validation on the
exact `dev` candidate as described in [Maintaining glowcap](docs/maintaining.md#promoting-to-main).
A successful development run alone cannot qualify a commit for publication.

The selected Linux jobs run independently with named phases, gate durations in
their summaries, and JSON evidence attached as artifacts. A failed job does not
cancel its siblings. The aggregate check requires every selected job to pass.
Superseded runs on the same branch and event are cancelled. Long gates report
elapsed time once a minute without extending their deadlines.

Each Linux job starts one devcontainer and reuses it across phases. Dependency
downloads are cached between runs. Build outputs and test results are not
restored, so each run exercises its own checkout. Separate jobs have separate
build caches and ports. Linux jobs reclaim unused hosted-runner SDK space
and disable Rust incremental compilation to leave room for build outputs.

Zig packages are fetched in a named setup step on Linux and macOS, with three
bounded attempts for download failures. Tests are never retried by that step.
Package caches are keyed by platform and pinned dependency inputs. Linux
checks use Ubuntu 24.04 to avoid an implicit runner OS migration.

The [image preparation workflow](.github/workflows/devcontainer-image.yml) runs
once before Linux jobs start. It reuses a toolchain image keyed by container
inputs, or builds one on a miss. Every Linux job uses the same immutable image.
Only trusted `main` and `dev` runs publish images. A pull request with new image
inputs shares its build through a temporary artifact within that run.

The container keeps the environment declared in Compose. CI mounts its shared
Zig package download store at the declared path, so startup checks and build
commands see the same environment. Pages and agent-tool jobs use the same
startup helper and image key with read-only registry access. On a cache miss,
they build and consume a local image without publishing it.

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
