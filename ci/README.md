# ci/

What runs on a commit, in one place. A workflow in `.github/workflows/`
declares jobs and the transfers between them, and each step is one command.
The commands are the Python here and `zig build`, so each program has a test
beside it and the YAML reads as a list.

| Trigger | Workflow | Runs |
| --- | --- | --- |
| Push to `dev`, pull request, nightly, manual `suite=check` | [check.yml](../.github/workflows/check.yml) | [`plan.py`](plan.py) selects groups, [devcontainer-image.yml](../.github/workflows/devcontainer-image.yml) prepares the toolchain image once, [check-group.yml](../.github/workflows/check-group.yml) runs each group, macOS and the workflow audit run beside them, and [`report.py`](report.py) requires every result as `gates` |
| Nightly, manual `suite=fuzz` | check.yml | `zig build fuzz -Dfuzz-runs=250K`, keeping a finding as an artifact |
| `check` succeeded on a `dev` push | [promote.yml](../.github/workflows/promote.yml) | Fast-forwards `main` to that commit as the promotion app |
| Push to `main` | [pages.yml](../.github/workflows/pages.yml) | Requires the commit's `check` run, builds and deploys the site |
| Tag `v*` | [release.yml](../.github/workflows/release.yml) | Requires the commit's `check` run, builds every archive, publishes the release and the Rooms image |
| Release published | [publish.yml](../.github/workflows/publish.yml) | Publishes the language packages to their registries |
| Weekly, policy file change | [repository-policy.yml](../.github/workflows/repository-policy.yml) | Compares GitHub's settings and rulesets with the committed policy and reports the differences |
| Weekly, newest release | [validate-release.yml](../.github/workflows/validate-release.yml) | Installs the newest release from the site and each registry |
| Devcontainer change | [agent-tools.yml](../.github/workflows/agent-tools.yml) | Cold-installs the pinned coding agents |

## Vocabulary

- A **gate** is one command judged by its exit code.
- A **phase** is the gates one test job runs in order.
- A **group** is the phases that share one compiled state. Its build jobs
  each compile one **shard** of what the phases run and hand the compiled
  state to one test job per phase.
- **Full validation** runs every group and reports `gates`, which the main
  ruleset requires. A pull request into `dev` runs the groups its changed
  paths reach and reports `dev-gates`.

## How a run is built

For a pull request into `dev`, [`plan.py`](plan.py) adds the groups its
changed paths reach. Each follow-up compares the full pull request with its
base, so a documentation edit keeps the checks that earlier code changes
require:

| Changed files | Additional Linux groups |
| --- | --- |
| Documentation | None |
| Loam | Browser |
| Python or Racket bindings | Bindings and interoperability |
| Conformance fixtures | Interoperability |
| Shared protocol, runtime, C ABI, Rust, TypeScript, or applications | All |
| Build, CI, fuzz tests, or unclassified files | All, with full validation |

Missing comparison history selects full validation, and a rename counts both
its paths. Pushes to `dev`, pull requests into `main`, nightly runs, and manual
`suite=check` runs always run full validation, which includes bounded mutation
fuzzing. The main ruleset reads `gates` from the run the push to `dev`
started, and that run's success moves `main` to the commit
([Maintaining glowcap](../docs/maintaining.md#promoting-to-main)).

A group's build jobs each compile one shard of what its phases run and hand
the compiled state to one test job per phase, which run side by side. Source
and infrastructure checks compile only their checkers, so they report within
minutes. A failed job does not cancel its siblings, a failed build still hands
its tests what it compiled, and a failed test does not stop its phase, so one
run reports every failing test. A build that runs out of time ends its phase,
because every later gate needs it. The aggregate check requires every selected
group and macOS to pass, and its summary links each failing job.

Runtime build and test jobs first run `zig build runtime-toolchain-check`.
It checks declarations and installed tools before expensive compilation or
process proofs. A failed prerequisite stops later commands in that job.

A deadline holds on the slowest machine that runs it: a hosted runner compiles
cold, an order of magnitude slower than a warm workstation. Tests that use
more than half their deadline warn, locally too.

Every Linux job runs in the same immutable toolchain image, which the
[image workflow](../.github/workflows/devcontainer-image.yml) resolves or
builds once per run. Only trusted `dev` and `main` runs publish an image, and a
pull request with new image inputs hands its build to its jobs as a run-scoped
artifact. Dependency downloads are cached between runs. A pull request restores
Zig and Cargo compile state saved by the last run of its review. Pushes,
nightly runs, and manual checks build cold and save state for later reviews,
so the push that validates `main` reuses nothing compiled. State past a size
limit is dropped, and a job frees the hosted runner's unused SDKs only when it
has less free disk than it needs. Coding-agent installation has a
[separate workflow](../.github/workflows/agent-tools.yml) for devcontainer
changes, so product checks never wait for agent downloads.

## Files

| File | Owns | Runs |
| --- | --- | --- |
| [`groups.py`](groups.py) | Every gate, in its phase and group, with its deadline class | Imported |
| [`plan.py`](plan.py) | Which groups a run needs, from its event and changed paths | Host, `plan` job |
| [`gates.py`](gates.py) | `fetch` the pinned dependencies, `compile` a shard, `run` a phase under its deadlines and record the evidence, `summary` the records | Inside the devcontainer, build and test jobs |
| [`state.py`](state.py) | The compiled state a build job packs and a test job restores, bounded by size and free disk | Host, build and test jobs |
| [`report.py`](report.py) | The one required result, from every job's outcome | Host, `gates` job |
| [`image.py`](image.py) | The toolchain image: reclaim runner disk, resolve or build the image, start it | Host, through the composite actions in [`.github/actions/`](../.github/actions/) |
| [`evidence.py`](evidence.py) | The record a run leaves: commit, pins, host, each gate's exit and duration | Inside the devcontainer |
| [`require_main_check.py`](require_main_check.py) | Whether a commit is on `main` with a successful full `check` run | Host, pages and release jobs, and the release tag front |
| [`github_release.py`](github_release.py) | The GitHub release: assemble the archives, verify attestations, fill the draft, publish | Host, release and publish jobs |
| [`release_notes.py`](release_notes.py) | The release page, from the assembled facts and the changelog | Host, release job |
| [`release_image.py`](release_image.py) | The Rooms image publication: each platform's exact image and the versioned index | Host, release job |
| [`racket_catalog.py`](racket_catalog.py) | The Racket catalog entry: point it at the release's binding archive and wait until the catalog has read it | Host, publish job |
| [`tools/run-with-timeout.py`](../tools/run-with-timeout.py) | The deadline every gate runs under | Both |
| [`workflows.py`](workflows.py) | The workflow files as mappings, the Actions predicates they select by, and a loader for the programs `import` cannot reach, for the tests | Imported |
| [`pyproject.toml`](pyproject.toml) | The tests' one dependency, PyYAML, which [`uv.lock`](uv.lock) pins | `uv run --project ci --locked` |

Reproduce a phase locally with `glowcap-dev python3 ci/gates.py run <phase>`.
`ci/gates.py fetch` first builds Zig's package/build tool without a download,
using the build allowance. The subsequent download attempts keep their separate
three-minute deadline, so retries do not repeatedly kill a cold compiler.
Each program's test sits beside it as `<name>_test.py`, a workflow's test is
named after the workflow, and `zig build infrastructure-check` runs them all
through `uv run --project ci --locked`.
