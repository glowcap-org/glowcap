---
id: ADR-0150
status: accepted
date: 2026-09-12
tags: [repository, apps, tools, operations, layout, scripts]
decision: "Commands live with the surface they act on, contributor commands are zig build steps, and each deployable has one operations front. Every committed script has one caller, one effect, an explicit interface and runtime, focused evidence, and a lifecycle aligned with its owner. There is no root ./ops."
supersedes: []
superseded_by: []
amends: [ADR-0085]
amended_by: []
---

# ADR-0150 Operations fronts and script placement

## Context

[ADR-0085](ADR-0085-repository-product-and-devtool-layout.md) settled where
product code and dev-tool verbs live. It did not say where an *operation*
lives: a command someone runs to start, inspect, redeploy, or reset a running
thing. Those grew where each was first needed. The Rooms deployment had
a strict `up.sh` and a raw `compose.sh` beside its Compose file, three
`rooms-web-*` steps spelled one `--transport=` flag, a `dev.sh` supervised the
ocapnviz Vite server, `site/docs-serve.sh` supervised Zine, and the
maintainer's gitignored tooling under `.local/` grew a Rooms area that knew
the two-machine shape of a redeploy: prepare in the devcontainer, start on the
Docker host. A contributor who cloned the public tree could not see that
shape at all, because the only front that named it was not in the tree.

Two pulls were in play. Centralizing everything into one root script is easy
to find and impossible to keep honest, because one file then speaks for the
toolchain, for Docker, for Tailscale, and for a maintainer's own machine, and
every reader pays for the parts that are not theirs. Leaving each script
where it grew is easy to write and impossible to discover, because the
next person searches for an entry point and finds six.

## Decision

Placement follows what the command acts on, and each surface has exactly one
front:

- **The toolchain.** A command that builds, tests, serves, or launches from
  this checkout is a `zig build` step, registered in `tools/build/` and
  documented in `docs/build-steps.md` like every other step. `rooms-dev` and
  `ocapnviz-dev` are the developer launches. A shell script may remain the
  *body* of such a step when it owns process-group cleanup or a supervised
  child (`apps/ocapnviz/dev.sh`, `site/docs-serve.sh`), but the script lives
  beside the thing it launches and is not itself an entry point anyone is
  asked to remember. A value the program already takes as a flag is a `-D`
  option on the one step, never a step per value: `rooms-web -Dtransport=`
  replaced `rooms-web-iroh`, `rooms-web-tcp`, and `rooms-web-onion`.
- **A public deployable.** A thing this repository ships to be run on a
  machine, today the Rooms Compose stack, carries one operations front in its
  own directory: `apps/rooms/web/deploy/ops`. It is POSIX `sh`, so it runs on
  the Docker host without the devcontainer's toolchain. It is the whole
  contract: the verbs, the two-machine shape and which half a machine can do,
  the strict start that refuses anything but prepared committed source, and a
  `compose` pass-through for what no verb names. Destructive verbs confirm,
  name their custody unit, and are the only place volume names are spelled.
- **The direction between them.** An operations front calls `zig build` for
  the toolchain half; the build graph never calls an operations front, and
  never names the deployment directory at all. A step that needed the front
  would be a build that depends on a machine, and a front that ran `cargo` or
  `deno` itself would be a second copy of the build. `source-check` holds
  both halves.
- **The container.** Image build, cache ownership, and pin checks stay in
  `.devcontainer/bin` and `.devcontainer/hooks`, as the
  [cli rule](../../../.agents/rules/cli.md) already holds.
- **Agent workflow.** Integration and hook scripts stay under
  `.agents/skills/*/bin` and `.agents/hooks`, because their consumers are
  agents and their gate is `source-check`.
- **Checks and generators.** Script bodies that a step runs stay under
  `tools/check` and `tools/gen` (ADR-0085), and the `in_tree_runtimes` table in
  `tools/build/toolchain.zig` names every one the gate may reach.
- **Machine and account facts.** Tailnet state, tunnel names, access
  policies, tokens, and which host runs Docker are one maintainer's facts and
  live in gitignored tooling under `.local/`. That tooling delegates to the
  public fronts above for anything the public tree owns, and the public tree
  never reaches into `.local/` except for the one state directory a developer
  launch keeps there.

There is no root `./ops`. A root front would have to speak for every surface
at once, which is the shape this record refuses.

### Committed script contract

A committed script is a maintained program with one caller and one effect. It
is not the default answer to a command that was convenient once. Before adding
one, name the repeated behavior, the public or internal interface that calls
it, and why the effect does not belong in an existing program or script.

Every script carries the contract its boundary needs:

- Its arguments, environment inputs, output, and exit status are explicit.
- Paths resolve from the script's location, or the caller visibly establishes
  the working directory. A command intended to work away from the repository
  root is tested from another directory.
- Its interpreter and dependencies already belong to the target environment.
  POSIX `sh` is for hosts that need it. Bash is for behavior that benefits from
  Bash facilities. Structured work moves to a language the pinned toolchain
  already owns instead of growing a shell parser.
- It validates before external effects and owns cleanup, signals, retries, and
  destructive confirmation appropriate to those effects.
- The same change wires focused evidence, adds the runtime to the toolchain
  inventory when a build check reaches it, and documents the public entry
  point. Internal script bodies name their caller instead of becoming a second
  command users must discover.

Maintenance follows the same ownership. A caller change moves its script,
test, runtime inventory, and documentation together. A script is removed when
its caller disappears, its effect moves into a better owner, or the behavior
itself no longer earns maintenance. A request to make helpers consistent does
not decide that usefulness question and is not, by itself, a reason to delete
one.

## Scope (what this does not decide)

The site's own hosting is not a deployable this repository ships; it has no
front. The Rooms demos under `apps/rooms/demos/` are proofs, not operations,
and stay wired to their `zig build` steps. A second deployable would get its
own front beside itself, not a verb on the Rooms one.

## Alternatives Considered

- **A root `./ops` script**: one entry point for everything. Rejected because
  it mixes the toolchain, Docker, and one maintainer's machine into one file,
  so it cannot run where any single half is missing without pretending.
- **Everything through `zig build`**: every operation a step. Rejected because
  the Docker host has no Zig, and a deployment front that needs the compiler
  to stop a container is wrong on the machine that matters.
- **Leave the two-machine shape out of the tree**: keep the Rooms verbs only
  in gitignored tooling. Rejected because a contributor with a Docker host
  would then rediscover the shape from a stale page.

## Consequences

`apps/rooms/web/deploy/ops` is the Rooms deployment's front, and the README,
the site's operations page, and the maintainer's tooling all route through
it; `up.sh` and `compose.sh` are gone. `rooms-web` is one step with
`-Dtransport`, and `rooms-dev` takes the same option.
`zig build ocapnviz-dev` joins `rooms-dev` as a developer launch and the
ocapnviz README leads with it. `tools/README.md` points here so the next
script lands with an owner, caller, contract, and verification.

## Evidence and gate

`zig build source-check` holds every documented `zig build` command to a real
step and every step to a line in `docs/build-steps.md`, so the two developer
launches cannot go undocumented. `tools/check/toolchain_check.zig` holds the
scripts the gate may reach. `checkOpsFrontsCallZigOnly` in
`tools/check/source_check/project_shape/ops_fronts.zig` holds the direction:
the build graph names no deployment directory, and the front runs no build
tool and no `zig` verb but `build`. The deployment front is exercised by hand
on a Docker host; `./ops doctor` reports the machine's half without touching
state.

## Notes

Amends [ADR-0085](ADR-0085-repository-product-and-devtool-layout.md), which
placed product and dev-tool code and left operations unplaced.
