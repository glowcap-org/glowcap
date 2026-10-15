# glowcap devcontainer

The supported build environment for VS Code and Cursor. The image installs
Zig, conformance tools, binding runtimes, the Chromium the browser proofs
drive, and debugging utilities. The four AI harnesses (Claude Code, Codex,
opencode, and the Cursor agent CLI) are not image content: they install on
first use into the shared host cache and update without a rebuild.

Open the repository with **Dev Containers: Reopen in Container**, then run:

```sh
zig build check
```

On first use, `hooks/initialize.sh` runs
[`bin/configure.sh`](bin/configure.sh), which writes the ignored `.env` and
creates an isolated `glowcap-dev-main-egress` network. The primary checkout
needs no setup.

## Starting from a host shell

[`bin/up.sh`](bin/up.sh) drives the [devcontainer
CLI](https://github.com/devcontainers/cli), the engine behind the editor
commands. The editor can attach to, reuse, or rebuild the container it starts:

```sh
bash .devcontainer/bin/up.sh              # Reopen in Container
bash .devcontainer/bin/up.sh --rebuild    # Rebuild Container
bash .devcontainer/bin/up.sh --no-cache   # Rebuild Container Without Cache
```

[`bin/enter.sh`](bin/enter.sh) wraps that in tmux. It starts or reuses the
named worktree's container, then attaches a tmux session. Run it from the
checkout, or symlink it onto the host `PATH` under a name other than
`glowcap`, which is the CapTP CLI inside the container:

```sh
bash .devcontainer/bin/enter.sh                          # tmux: glowcap-dev-main
bash .devcontainer/bin/enter.sh --session review         # tmux: glowcap-dev-main-review
bash .devcontainer/bin/enter.sh tree1                    # tmux: glowcap-dev-tree1
bash .devcontainer/bin/enter.sh tree1 --session review   # tmux: glowcap-dev-tree1-review
bash .devcontainer/bin/enter.sh tree1 --session review --rebuild

ln -s "$(pwd)/.devcontainer/bin/enter.sh" ~/.local/bin/glowcap-dev-enter
glowcap-dev-enter tree1 --session review
```

The launcher works from any current directory. `main` names the primary
checkout, and every other name must be a linked worktree Git lists with that
directory basename. It runs the selected checkout's own `up.sh`, so a checkout
keeps the tooling it was built with.

`--session NAME` opens another tmux session on the same container. The default
session is `glowcap-dev-<worktree>`, and a named one is
`glowcap-dev-<worktree>-<name>`. Each session has its own shell, and all of a
worktree's sessions share its processes and filesystem. A name starts with a
lowercase letter, ends with a lowercase letter or digit, uses lowercase
letters, digits, and hyphens, and is at most 24 characters. Reusing a name
rejoins that session.

From iTerm2, both launchers attach in tmux control mode (`tmux -CC`), so
sessions and panes render as iTerm2 windows and splits. Other terminals attach
as an ordinary tmux client. Pass `--cc` or `--no-cc` to force either.

The worktree name also names the container and image: a `tree1` checkout uses
the container `glowcap-dev-tree1` and the image `vsc-glowcap-dev-tree1`.

[`bin/enter-grid.sh`](bin/enter-grid.sh) opens many worktrees in one tmux
session, one column per worktree. With no arguments, every worktree Git
registers becomes a column, and naming worktrees narrows the grid.
`--rebuild`, `--no-cache`, `--session`, `--cc`, and `--no-cc` work as in
`bin/enter.sh`, with sessions named `glowcap-dev-grid` or
`glowcap-dev-grid-<name>`. Percentage splits need tmux 3.1 or newer.

```sh
bash .devcontainer/bin/enter-grid.sh                  # tmux: glowcap-dev-grid
bash .devcontainer/bin/enter-grid.sh main tree2       # only these columns
bash .devcontainer/bin/enter-grid.sh --session review # tmux: glowcap-dev-grid-review
```

Each worktree configures its column through the ignored
`.devcontainer/pane/panes.sh`, plain shell that the pane runtime sources in
each of the column's panes after the container shell's `~/.zshrc`.
[`panes.example.sh`](pane/panes.example.sh) shows the shape.

- Top-level lines run in every pane, so an export there configures the whole
  column.
- A `pane1`, `pane2`, … function runs as that pane's startup command. The
  highest `paneN` declared sets the column's row count: one full-height shell
  when the file declares none or is absent, at most twelve.
- Each command behaves as if typed at the prompt: it can be interrupted,
  joins shell history, and returns to the prompt when it exits.
- With `--session NAME`, a `pane/panes-NAME.sh` file is preferred when it
  exists, so one worktree can carry different grids for different sessions.
- A session opened by `bin/enter.sh` reads the same file and runs no startup
  command, so its pane functions are defined and wait to be named at the
  prompt.

## Entering and leaving the container

Every pane the launchers open keeps a shell on the host, in that worktree's
checkout, and runs the container shell inside it. Two commands move between
them:

```sh
glowcap_devcontainer_exit    # step out to the host, in this worktree
glowcap_devcontainer_enter   # go back into the container
```

Plain `exit` ends the pane, because the shell it ends is the host shell the
container one was opened from. On the host side the prompt carries a
`(host <worktree>)` marker, and you can `cd` anywhere.

Going back in runs the pane's startup command again. Add `--bare` to skip it.
If the container stopped or was rebuilt while you were away, entering starts it
through [`bin/up.sh`](bin/up.sh). A container shell that a signal ends leaves
the pane standing.

The container half is `pane/container/.zshrc` and the host half is
`pane/host/.bashrc`. Each sources your own `~/.zshrc` or `~/.bashrc` first and
adds the two commands.

## Worktree identity

Each checkout has one short name in its ignored `.devcontainer/.env`.
[`bin/configure.sh`](bin/configure.sh) derives the name and Git common
directory. The primary checkout uses `main`, so its container is
`glowcap-dev-main`. A linked worktree uses the lowercase name of its
directory, whatever its branch is called. Create and configure one with:

```sh
git worktree add --lock .worktrees/tree1 -b failure-sweep
cd .worktrees/tree1
bash .devcontainer/bin/configure.sh --port-offset 10000
```

Keep the lock on for the worktree's whole life. Inside a container the
registered paths of linked worktrees point at directories that do not exist
there, so a `git worktree prune` run in the container removes every unlocked
worktree's registry entry and submodule stores, including its own. Git never
prunes a locked worktree.

The port offset is added to every development host port. Setup takes it
explicitly instead of guessing whether ports are free.

`bin/configure.sh` validates but never overwrites an existing `.env`. To change
an identity, port offset, or egress network, stop that checkout's container,
remove the file, and run the command again.

Opening the checkout above creates `glowcap-dev-tree1`, though its branch is
`failure-sweep`. Startup refuses a linked-worktree directory whose name does
not match. Names start with a letter, use lowercase letters and digits, and
are at most 12 characters. They are host-global Docker names, so two clones
can run together only when their worktree names differ, and startup refuses a
duplicate container name.

The file also records `GLOWCAP_CHECKOUT_DIR`, the absolute path to this
checkout, and `GLOWCAP_GIT_COMMON_DIR`, derived from:

```sh
git rev-parse --path-format=absolute --git-common-dir
```

All worktrees of one primary checkout share the common-directory value, and
linked worktrees' `.git` files can contain its absolute host path. Compose
mounts both paths at their host locations inside every container and keeps
`/workspaces/glowcap` as the workspace. The mounts are explicit because the
Dev Containers CLI does not apply its automatic Git mounts to custom Compose
workspace mounts. Linked-worktree submodules use absolute Git paths that
resolve from both sides, and primary clones use relative links so they survive
a checkout move.

The file also owns the worktree's host ports. Each is a baseline from
[`lib/settings.sh`](lib/settings.sh) plus the offset, and the primary checkout
uses offset 0. Host port 8080 is reserved for the Rooms deployment, and
development configuration refuses it.

The file holds one `KEY=value` assignment per line. Exported host variables
take precedence over Compose `.env` files, so startup refuses an inherited
`GLOWCAP_*` or `EGRESS_NET` value that differs from the file.

## What runs when

| Phase | What runs |
| --- | --- |
| Before creation | `hooks/initialize.sh` creates the shared host agent-state paths and any missing primary-checkout configuration, validates Git identity and ports, and prepares the managed Docker networks |
| Image build | `Dockerfile`, `image/` installers, then `image/verify-toolchains.sh` |
| First open | `hooks/post-create.sh` verifies host binds are writable, proves the Zig cache filesystem, checks pins and toolchains, holds the container to the environment Compose declares, and fills the conformance submodules |
| Development | You run `zig build check` and focused build steps |

## Toolchains

Versions and canonical paths live in [`pins.sh`](pins.sh), and download hashes
in [`checksums.sh`](checksums.sh). [Dependencies](../docs/dependencies.md) says
what each tool is for. Each installer in [`image/`](image/) is named for its
toolchain group, and the `Dockerfile` installs the system packages.

The image installs the Rust browser target and the `wasm-bindgen` compiler,
whose version comes from `apps/rooms/rust/Cargo.lock`. ZLS is built from the
checksummed source revision in `pins.sh` and must compile with the selected Zig
before the image counts as verified.

The image puts the CapTP CLI on PATH (see the [CLI](../docs/cli.md)).
`glowcap` links to the repo-root development launcher, which runs
`zig-out/product/bin/glowcap`.

- The launcher builds a missing product once. Run `zig build rooms-release`
  after source edits, because session and inspection commands use the existing
  product.
- On Linux, checkout deployment `up` and `reset` prepare the current source
  automatically.
- `./glowcap install` uses the same verified installer as a platform archive.
  Installed executables do not enter containers or run compilers.
- The launcher and agent workflow share `.devcontainer/bin/run.sh` for
  environment selection and a per-checkout build lease.

Supply build environment overrides through the front:

```sh
.agents/skills/work/bin/glowcap-dev --env CARGO_BUILD_JOBS=1 zig build rooms-rust-test -j1
```

`-j1` limits Zig's build graph, and Cargo sets its own child concurrency. The
front passes `--env` values into the selected environment and refreshes Zig's
cached configuration so its Run steps receive them. Compiled artifacts stay
cached, and the build lease and per-test deadline stay active. Compilation and
linking are outside that deadline.

A tool run through `docker exec` writes files as the container's user, so a
`zig fmt` there leaves files the host session can no longer edit. Format from
the front, or chown the touched paths back afterward.

The front reads `GLOWCAP_DEV_WORKDIR` itself, on the host, to choose the
checkout to mount: `GLOWCAP_DEV_WORKDIR=... glowcap-dev ...`. A host-side
prefix on any other variable stops at the front, so pass it through `--env`.

Cargo is configured for build speed:

- Intermediate objects, fingerprints, and incremental state stay on the
  worktree's Linux volume, and final artifacts keep their declared output
  paths. The build front applies this to existing containers too.
- Linux Rust links use the active compiler's bundled LLD. Changing
  linker or debug settings requires one rebuild.
- Rooms tests retain source locations for backtraces, and
  `--env CARGO_PROFILE_TEST_DEBUG=2` gives full debugger data.
- The container defaults to four Cargo jobs, and `--env CARGO_BUILD_JOBS=N`
  overrides that.
- Rooms tests and peers build only the static archives and iroh
  companion they link, and Rust lint checks metadata only.
- Browser proof steps request the contract crate's Wasm module explicitly and
  skip its unused shared-library link. Only `rooms-browser-build`
  requests the deployable module.
- Browser contracts use the `browser-proof` profile with optimized loops and
  parallel code generation. Deployment modules keep whole-program optimization.
- The source analyzer uses optimized code with safety checks.

## Managed tools: the AI harnesses

`claude`, `codex`, `opencode`, and the Cursor agent CLI (`agent` and
`cursor-agent`) are not in the image, and neither is Playwright's browser set.
A harness's first use installs the checkout's seed into the shared cache at
`~/.cache/glowcap/installed/<platform>/<tool>`. The seed is the version
`pins.sh` names, verified by registry integrity for npm packages and by
checksum for archives. Every worktree container shares that cache, so one
download serves all of them and a rebuild keeps the installed version.

Playwright's requirement is the checkout's `PLAYWRIGHT_VERSION` pin, and several
requirements can coexist in the cache. Browser proof steps run under
`tools.sh exec`, which prepares the requirement and points the command at its
browser directory:

```sh
.devcontainer/bin/tools.sh exec playwright -- deno run --allow-all tools/some-browser-step.ts
```

The image keeps only the apt libraries the browsers launch against
(`image/playwright.sh`). If a later pin names libraries the image lacks, a
rebuild installs them.

The wrapper owns the update lifecycle, so the vendors' updaters do not run:
Claude Code runs with `DISABLE_UPDATES=1`, opencode with
`OPENCODE_DISABLE_AUTOUPDATE=1`, and the Cursor agent CLI is exec'd with
`--disable-auto-update`. `claude update`, `codex update`, and
`opencode upgrade` route to the maintenance front instead:

```sh
.devcontainer/bin/tools.sh status                 # what is installed, at which selection
.devcontainer/bin/tools.sh update claude          # move past the seed to upstream latest
.devcontainer/bin/tools.sh ensure claude          # install/adopt the seed; verify
.devcontainer/bin/tools.sh repair claude          # reinstall the selection into a fresh install
.devcontainer/bin/tools.sh exec playwright -- <command>   # pinned browsers, exact requirement
```

A warm invocation is quiet and offline: it resolves the selection and execs it.
Updates persist across rebuilds, and a pin bump is adopted on the next ensure or
cold first use. `claude install` and `opencode uninstall` are refused, because
installer migration and shared-cache removal are not managed operations.

Each install carries a receipt recording what was installed, from where, and
how it was verified. Upstream tarballs that publish no digest (Cursor) are
recorded as unverified.

The container has no browser, so sign in with `NO_OPEN_BROWSER=1 agent login`
and open the printed URL on the host. `agent status` says who you are.

No Tor runs when the container opens. glowcap reaches an onion service through
a daemon its deployer started. The image installs the binary only, a check that
needs a live daemon starts and stops its own, and the in-tree onion checks talk
to a fake daemon.

## Updating pins

Use [`bin/update-pins.sh`](bin/update-pins.sh) to update a tool:

```sh
.devcontainer/bin/update-pins.sh               # report pins vs upstream + submodule drift
.devcontainer/bin/update-pins.sh bump <dep>    # rewrite the pin and everything restating it
.devcontainer/bin/update-pins.sh bump --safe   # bump everything outside the build graph
```

It fetches versions and hashes from each dependency's release channel and
validates every edit before replacing a file. Rebuild the container when an
updated tool is installed there. The harness seeds are not image content, so
their check is the cold-seed smoke run (`test/tool-install.sh <name>`), and the
running cache adopts a bumped seed on the next `tools.sh ensure` or cold first
use. The report also lists the checks each dependency requires: Zig requires
`zig build check`, Racket and Goblins require `zig build check-external`, and
the Distroless base lists the release workflow's image proofs.

A few pins are restated outside `pins.sh`, because a Dockerfile and a
`deno.json` cannot source a shell file. A bump rewrites those copies, and
`test/env-sync.sh` fails the build if one drifts. Path changes are hand edits:
keep the `Dockerfile` environment and `devcontainer.json` `containerEnv`
aligned with `pins.sh`, which the same check enforces.

To track a new dependency, add it to
[`lib/update-pins-deps.sh`](lib/update-pins-deps.sh): a name in
`GLOWCAP_PINS_DEPS`, its `pins.sh` variable, how a bump is proven, and the
query that asks its release channel for the latest version. If a file outside
`pins.sh` also names that version, add a row in
`lib/update-pins-companions.sh`. The bump rewrites the file from that row, and
`test/env-sync.sh` reads the same row to check it.

Host-side startup uses an installed devcontainer CLI only when it matches the
`DEVCONTAINER_CLI_VERSION` pin. Otherwise `npx` runs the pinned release.

The pin report covers image tools and conformance submodules. A complete
refresh also covers these owners, and `source-check` fails when a pinned tool
or Zig package is missing from [Dependencies](../docs/dependencies.md).

| Dependency | Update and evidence |
| --- | --- |
| Devcontainer features | Run the pinned `@devcontainers/cli`'s `upgrade --workspace-folder .`. Rebuild to exercise the regenerated feature lock |
| Rust crates | Update direct requirements, then `cargo update` in each crate or workspace. Run the affected Zig build steps and `runtime-check` |
| Deno packages | Update imports and task specifiers together, then `deno update --frozen=false` in each scope. Normal builds keep frozen locks |
| Python packages | Update direct requirements, then `uv lock --upgrade --project <directory>`. Run binding and conformance checks |
| Zig packages | Review upstream changes, then move each `build.zig.zon` entry (root and `site/`). Fetch each over `git+https` at a commit or from an archive URL, so `zig fetch --save` gives the hash the build checks and the layout the build names: an archive loses its one top-level directory, and a hash taken from a tree unpacked by hand matches only that cache. Update its revision and notice in `LICENSE-THIRD-PARTY`, and exercise the consuming build steps, including `site` and `cli-test` |
| CI actions | Resolve current releases to full commit hashes. Keep workflow references immutable |

Source checks do not prove a new base image or feature installation. Verify an
update with the new tool in use.

## Persistent paths

Each kind of generated bytes has one owner. The wrong owner causes a race, a
cold rebuild, or a `git clean` that throws away the wrong thing.

The **image** holds compilers, Goblins in `PLTUSERHOME`, rustup, uv tools, and
the Cursor agent binary. A pin bump is a rebuild.

The **host user** holds agent logins, downloads, and language-manager caches.
Those scoped binds are in [`devcontainer.json`](devcontainer.json). The tree is
`~/.cache/glowcap` on the host and `/home/vscode/.cache/glowcap` in the
container, with a `LAYOUT` file at the root. [Host
configuration](docs/host-configuration.md) covers the shared mounts.

Each worktree keeps Zig's local cache and extracted packages in a Docker named
volume, `glowcap-dev-<worktree>-zig-work`. That gives Zig the Docker daemon's
filesystem semantics instead of the atomic-file behavior of a host bind, and
worktrees do not share build objects.

| Path | Owner | What |
| --- | --- | --- |
| `tool/zig` | `ZIG_GLOBAL_CACHE_DIR` | Zig compiler / global cache |
| `tool/deno`, `npm`, `pip`, `bun`, `uv`, `zls` | those tools' cache vars | shared downloads |
| `installed/<platform>/<tool>` | the managed-tool lifecycle | AI harness installs: one immutable directory per version plus a `current` selection, with a receipt. Shared by every worktree container |
| `cargo/` | `CARGO_HOME` | registry, git, `cargo install` bins |
| `/home/vscode/.cache/glowcap-dev-zig-work/zig-local` | `ZIG_LOCAL_CACHE_DIR` | that container's Zig compile objects |
| `/home/vscode/.cache/glowcap-dev-zig-work/zig-pkg` | `ZIG_LOCAL_PKG_DIR` | that container's extracted Zig packages |
| `/home/vscode/.cache/glowcap-dev-zig-work/cargo/{workspace-path-hash}` | `CARGO_BUILD_BUILD_DIR` | Cargo intermediate state, separated by workspace |

Checkout paths that are **install products or product state** stay on the
worktree bind, where the tree already names them:

| Path | Why it stays |
| --- | --- |
| `zig-out/` | install prefix (`bin/`, `lib/`, wasm, site, benches) |
| crate `target/` | sidecar `.a` files and relay bins the Zig graph links by path |
| `.local/` | occupancy and MCP scratch |

`git clean -fdx` removes those worktree paths but not incremental Zig objects
or extracted packages. After recreate, leftover `.zig-cache/`, `zig-pkg/`, and
Racket `compiled/` directories in the checkout are unused, and post-create
deletes them.

| Variable | During image build | In an open container |
| --- | --- | --- |
| `CARGO_HOME` | `/usr/local/cargo` | `~/.cache/glowcap/cargo` host bind |
| `RUSTUP_HOME` | `/usr/local/rustup` | unchanged |
| `PLTUSERHOME` | `/opt/glowcap-racket-userhome` | unchanged |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/glowcap/tool/zig` | same path on the host bind |
| `ZIG_LOCAL_CACHE_DIR` | unset (image build uses a checkout `.zig-cache`) | `zig-local` in the worktree's Docker volume |
| `ZIG_LOCAL_PKG_DIR` | unset (image build uses a checkout `zig-pkg/`) | `zig-pkg` in the worktree's Docker volume |
| `UV_CACHE_DIR` | unset | `tool/uv` on the host bind |
| `CLAUDE_CONFIG_DIR` | `/home/vscode/.claude` | same host bind mount |
| `CURSOR_CONFIG_DIR`, `CURSOR_DATA_DIR` | `/home/vscode/.cursor` | settings host bind. Linux tokens use `~/.config/cursor` |

Rustup seeds the image under `/usr/local/cargo`. The first locked cargo build
of an in-tree crate fills `cargo/` on the host bind, and later builds reuse it.

The last two rows keep an agent CLI's settings across a rebuild, by pointing
both tools at directories [`devcontainer.json`](devcontainer.json) binds from
the host.

Playwright's browsers are runtime content. The shared browser prerequisite in
`build.zig` runs `tools.sh ensure playwright`, which installs the pinned
requirement into the shared cache on first browser use, and every browser proof
step (`zig build rooms-web-page` and its siblings) runs under
`tools.sh exec playwright`. Browser garbage collection is off, so one
worktree's run cannot delete another's installation.

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml), though `perf`
may still depend on host kernel policy. Racket's package tool has no version
flag: use `racket --version`, not `raco --version`.

## Host and network setup

- [Docker networking](docs/networking.md): the rooms network, the private egress
  network, and how the rooms peer reaches the deployed app.
- [Host configuration](docs/host-configuration.md): Git, SSH, shared agent and
  authentication state, keyrings, and commit signing.

### Ports the container forwards

`docker-compose.yml` publishes the Rooms web page, the Rooms directory's CapTP
listener, the reference relay, the protocol-visualizer trace feed, the ocapnviz
Vite dev server, and the documentation preview on host loopback. Services use
the container ports the compose file names, and their host ports come from
`.env`. Open each page as localhost on its published port, such as
`GLOWCAP_ROOMS_WEB_HOST_PORT` for Rooms. A tailnet listener such as Tailscale
Serve can bind the same numbers on the machine's tailnet addresses.

`zig build rooms-dev` binds its Vite listener to the container interface and
keeps its Rooms backend on an ephemeral container-loopback port, so the
published web port is the only Rooms development address exposed to the host.
Outside the container, it defaults to host loopback.

[`apps/rooms/developing.md`](../apps/rooms/developing.md) uses canonical
container ports, and a host-side client uses the matching `*_HOST_PORT` value.
For the `tree1` example above, the live trace is `ws://127.0.0.1:20300/`.

If a host port is taken, the container does not start. Inspect its owner before
choosing a different offset. To change an existing assignment, edit the six
`*_HOST_PORT` values together, keeping the checkout paths and egress network,
then run `bash .devcontainer/bin/up.sh --rebuild` from a host shell. This
disconnects sessions inside the devcontainer, and restarting alone does not
change the published ports.

## Layout

| Directory | Holds |
| --- | --- |
| `bin/` | The commands a person or a tool runs: configure a checkout, bring its container up, open a tmux session, find a container, bump the pins, maintain the managed tools |
| `tools/` | The managed-tool runtime: the dispatcher every managed command name links to, and one driver per AI harness that owns its install, verification, and update lifecycle |
| `lib/` | The shared shell library, one module per subject, entered through `lib/mod.sh` |
| `image/` | Everything the image is built from: one installer per toolchain group, the patches they apply, and the version check that closes the build |
| `hooks/` | The lifecycle hooks the devcontainer CLI runs, on the host before creation and in the container after it |
| `pane/` | The tmux pane runtime, one directory per side of the container boundary, beside the example pane configuration |
| `test/` | Static environment parity (`source-check`) and executable workflow proofs (`infrastructure-check`) |
| `docs/` | The longer prose: host setup and networking |

Each script refuses the wrong side: host-side scripts call
`glowcap_require_host`, container-side ones `glowcap_require_devcontainer`, and
`lib/context.sh` owns the detection. A file's header says what it does and
where it runs. `image/zig.sh` also runs on CI runners, macOS included.
`hooks/post-create.sh` runs shellcheck over every shell file here, so a lint
finding fails container open and the CI push checks.

`test/env-sync.sh` runs in `zig build source-check`. The executable behavior
tests run in `zig build infrastructure-check`, so a source-only edit does not
create temporary repositories or exercise host workflow.

Cursor users can enable Serena from [`.cursor/mcp.json`](../.cursor/mcp.json).
The [Serena skill](../.agents/skills/serena/SKILL.md) covers project use.
