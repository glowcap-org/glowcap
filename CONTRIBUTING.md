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
without agreeing on scope. Before changing a contract covered by a plan,
discuss the approach in an issue. Focused fixes to the existing product need
not wait for that plan.

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

Opening the devcontainer also installs the pre-commit hook, which formats
staged Zig, Rust, TypeScript, JavaScript, and Python files. A plain clone runs
`git config core.hooksPath .agents/hooks` once to install the same hook.

## Preview startup

`zig build site-serve` and `zig build rooms-dev` build their prerequisites
before starting a server. A fresh checkout or empty build cache can spend
several minutes downloading and compiling dependencies. Wait for the server's
listening address before opening the page. When you run either through the
devcontainer's `glowcap-dev` command, it prints a notice that the build is
still preparing before the server starts.

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

## Adding a build step

Add `zig build <name>` on its own line in the section of
[Build steps](docs/build-steps.md) that matches what the step proves, beside
its closest sibling, then run `zig build gen-build-steps`.
The comment on every bare row is written from the build graph: the step's own
description, then `part of` and the nearest steps that run it, derived from
the step dependencies. The description says what the step proves and ends with
the tools it needs in parentheses when it needs more than Zig. A row with
arguments after the name is a usage example and keeps the comment you write.
`gen-build-steps-check` holds the rows to the graph under `source-check`.

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

[`ci/README.md`](ci/README.md) maps every trigger to the workflow it runs, the
command each step calls, and how a run selects and builds its groups. The
commands are Python under `ci/` and `zig build`, so each has a test in
[`ci/`](ci/) and a workflow reads as a list of steps.

Every pull request runs source checks, Zig tests in Debug and ReleaseSafe,
process proofs, infrastructure checks, and macOS tests, and a pull request
into `dev` adds the groups its changed paths reach. A missed deadline fails
the check without a retry. Diagnose the stopped attempt before rerunning it,
because a later pass does not explain the failure. Reproduce a phase locally
with `glowcap-dev python3 ci/gates.py run <phase>`, or CI's process checks
alone:

```sh
zig build runtime-check-build -Doptimize=ReleaseSafe
zig build runtime-check -Doptimize=ReleaseSafe
```

When hosted runners are unavailable, local checks remain the way to validate a
change.

## License

By contributing, you agree your contributions are licensed under
[Apache-2.0](LICENSE-APACHE).
Third-party files keep their own terms. See
[`LICENSE-THIRD-PARTY`](LICENSE-THIRD-PARTY).
