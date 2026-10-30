# Contributing to glowcap

Bug reports, focused fixes, tests, and documentation improvements are welcome.
Open a pull request against `dev`. For a substantial design change, open an
issue first to agree on the approach. Glowcap LLC maintains the project.
Reviews are best-effort.

Use the editor and development tools you prefer. Building, testing, and
contributing require no AI service or account. Contributions written with or
without assistance receive the same review for correctness, clarity, tests,
and fit with the project.

The [bug report form](.github/ISSUE_TEMPLATE/bug_report.md) lists what a report
needs, and a fix is optional. Send suspected vulnerabilities through
[the security policy](SECURITY.md).
[Issues](https://github.com/glowcap-org/glowcap/issues) and
[the roadmap](docs/roadmap.md) show the work under discussion. An open plan
describes proposed work, not a shipped API or an instruction to implement it
without agreeing on scope.
Before changing a contract covered by a plan, discuss the approach in an
issue. Focused fixes to the existing product need not wait for that plan.

## Find a starting point

A useful contribution can point out a confusing instruction, reproduce a bug,
add a missing failure case to a test, or fix a focused problem. You do not need to
understand the whole protocol to report what happened and what you expected.

For code, start with a runnable [example](examples/README.md) in your language,
then follow it into the implementation. For Rooms, start with
[Developing Rooms](apps/rooms/developing.md). The roadmap includes substantial
design work, so discuss scope before taking on an entire item.

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
| Process or application behavior, language workspaces | Also `zig build runtime-check -Doptimize=ReleaseSafe` |
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
An accepted change lands on `dev` as one squash commit that keeps you as its
author, and the pull request closes as merged.

## Tools and responsibility

The submitting contributor explains the change and its design decisions,
reports validation and remaining uncertainty, and answers review questions.
These expectations apply regardless of the tools used.

If you used AI assistance, briefly describe what it did and how you verified
the result in the pull request.
[PROVENANCE.md](PROVENANCE.md) describes the project's own use of assistants
and the upstream policies that restrict assisted work. Participation follows
the [Code of Conduct](CODE_OF_CONDUCT.md).

Repository instructions for coding agents live in [AGENTS.md](AGENTS.md).

## Continuous integration

Every pull request runs core, memory, runtime, infrastructure, and
browser/interoperability smoke checks, plus macOS tests. Core validation
includes source checks and Zig tests in Debug and ReleaseSafe. ReleaseSafe
compiles in groups to bound memory use, with every test layer covered. For a
pull request into `dev`, the [coverage selector](ci/plan.py) adds deeper jobs
for changed subsystems:

| Changed files | Additional Linux groups |
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

Pushes to `dev`, pull requests targeting main, nightly runs, and manual
`suite=check` runs always execute the complete [`ci/gates.sh`](ci/gates.sh)
sequence. Full validation includes bounded mutation fuzzing. Nightly runs also
search deeper with the fuzzer, as does a manual `suite=fuzz` run. A fuzzer
finding is retained as a downloadable artifact for reproduction.

Selected validation reports `dev-gates`. Complete validation reports `gates`,
including on pull requests that require every group. The main ruleset reads
`gates` from the run the push to `dev` started. That run's success moves `main`
to the commit, as
described in [Maintaining glowcap](docs/maintaining.md#promoting-to-main).

Linux validation runs in the groups [`ci/plan.py`](ci/plan.py) names. A group's
build jobs each compile one shard of what its phases run and hand the compiled
state to one test job per phase. Test jobs restore that state before running
their phases side by side. Source and infrastructure checks start without waiting
for a product build, including package and TLS fixture regression tests. The
live TLS proof has its own build group. Each test job reports gate durations
and attaches JSON evidence.

A failed job does not cancel its siblings, a failed build still hands its tests
what it compiled, and a failed test does not stop its phase, so one run reports
every failing test. A build that runs out of time ends its phase, because every
later gate in that phase needs it. The aggregate check requires every selected
Linux group and macOS validation to pass. Its summary identifies the commit,
links failing jobs, and lists the longest completed jobs.

Superseded runs on the same branch and event are cancelled. Long gates report
elapsed time once a minute without extending their deadlines.

A deadline holds on the slowest machine that runs it. Hosted runners compile
cold, an order of magnitude slower than a warm workstation, and run tests
slower too. Each job therefore carries only the phases that fit its time limit,
and a phase opens with its shared build under a separate build allowance so a
proof's deadline times the proof. A step that passes using more than half its
deadline says so, locally too. A test step whose deadline fires reruns once,
and the log names the miss, so a retry absorbs a stalled runner without
hiding a slow test.

To reproduce CI's process checks locally, compile in ReleaseSafe first, then
run the tests in the same mode. Run browser proofs separately from this sequence.

```sh
zig build runtime-check-build -Doptimize=ReleaseSafe
zig build runtime-check -Doptimize=ReleaseSafe
```

Each Linux job starts one devcontainer and reuses it across phases. Dependency
downloads are cached between runs. Pull requests can restore Zig and Cargo
compile state even when all groups run. Pushes, nightly runs, and manual checks
build cold and save state for later reviews. The push that qualifies `main`
therefore reuses no compiled state. Separate jobs have separate caches and ports.

Zig and Cargo validate cached objects against compiler and source inputs.
Process proofs rerun, while unchanged Zig unit-test results can be reused.
State past a size limit is dropped. A Linux job removes the hosted runner's
unused SDKs only when the runner has less free disk than a job needs, and
Rust incremental compilation stays off to leave room for build outputs.

Zig packages are fetched in a named setup step on Linux and macOS, with three
bounded attempts for download failures. Tests are never retried by that step.
Package caches are keyed by platform and pinned dependency inputs. Linux
checks use Ubuntu 24.04 to avoid an implicit runner OS migration.

The [image preparation workflow](.github/workflows/devcontainer-image.yml) runs
once before Linux jobs start. It reuses a toolchain image keyed by container
inputs, or builds one on a miss. Every Linux job uses the same immutable image.
Only trusted `main` and `dev` runs publish images. A pull request with new image
inputs shares its build through a temporary artifact within that run.

The container keeps the environment declared in Compose. CI mounts its cached
Zig package and compile stores at their declared paths, so startup checks and build
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
