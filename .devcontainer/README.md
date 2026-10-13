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
[`bin/configure.sh`](bin/configure.sh). The primary checkout needs no setup:
the command derives its Git common directory, writes the ignored `.env`, and
creates an isolated `glowcap-dev-main-egress` network. `hooks/post-create.sh`
runs after the image is ready, verifies the toolchains, and initializes the
conformance submodules before the editor opens the workspace.

## Starting from a host shell

[`bin/up.sh`](bin/up.sh) drives the [devcontainer
CLI](https://github.com/devcontainers/cli), the engine behind the editor
commands. The editor later attaches to, reuses, or rebuilds the container it
started:

```sh
bash .devcontainer/bin/up.sh              # Reopen in Container
bash .devcontainer/bin/up.sh --rebuild    # Rebuild Container
bash .devcontainer/bin/up.sh --no-cache   # Rebuild Container Without Cache
```

[`bin/enter.sh`](bin/enter.sh) wraps that in tmux. It starts or reuses the
named worktree's container, then attaches the default tmux session or a named
one. `glowcap` is the CapTP CLI inside the container, so the host launcher
does not take that name. Run it from the checkout, or symlink it onto the host
`PATH` under another name:

```sh
bash .devcontainer/bin/enter.sh                          # tmux: glowcap-dev-main
bash .devcontainer/bin/enter.sh --session review         # tmux: glowcap-dev-main-review
bash .devcontainer/bin/enter.sh tree1                    # tmux: glowcap-dev-tree1
bash .devcontainer/bin/enter.sh tree1 --session review   # tmux: glowcap-dev-tree1-review
bash .devcontainer/bin/enter.sh tree1 --session review --rebuild

ln -s "$(pwd)/.devcontainer/bin/enter.sh" ~/.local/bin/glowcap-dev-enter
glowcap-dev-enter tree1 --session review
```

The launcher follows its symlink and asks Git for the primary checkout, so it
works from any current directory. `main` is that checkout. Every other name
must be a linked worktree Git lists with that directory basename. The launcher
asks the selected checkout's own `up.sh` to start or reuse the container,
looking under `bin/` first and beside compose if that checkout has not moved it
yet, then attaches.

`--session NAME` selects another tmux session without creating another Docker
container. The default session is `glowcap-dev-<worktree>`, and a named one is
`glowcap-dev-<worktree>-<name>`. Each session opens its own shell, and all
sessions for a worktree share that container's processes and filesystem. A
session name starts with a lowercase letter, ends with a lowercase letter or
digit, contains only lowercase letters, digits, and hyphens, and is at most 24
characters. Reusing a name rejoins that session.

From iTerm2, both launchers attach in tmux control mode (`tmux -CC`), so
sessions and panes render as native iTerm2 windows and splits. Other terminals
attach as an ordinary tmux client. Pass `--cc` or `--no-cc` to force either.
Detection covers a local iTerm2 tab and, with iTerm2's shell integration
installed, an ssh session from one.

The same identity names both Docker artifacts. A `tree1` checkout uses the
container `glowcap-dev-tree1` and builds the image `vsc-glowcap-dev-tree1`.

[`bin/enter-grid.sh`](bin/enter-grid.sh) opens many worktrees at once: one tmux
session holding a grid with one column per worktree. With no arguments, every
worktree Git registers becomes a column. Naming worktrees narrows the grid.
Each column runs that checkout's own `up.sh`, so it keeps the tooling and
ports it was built with. `--rebuild`, `--no-cache`, `--session`, `--cc`, and
`--no-cc` work as in `bin/enter.sh`, with sessions named `glowcap-dev-grid` or
`glowcap-dev-grid-<name>`. Percentage splits need tmux 3.1 or newer.

```sh
bash .devcontainer/bin/enter-grid.sh                  # tmux: glowcap-dev-grid
bash .devcontainer/bin/enter-grid.sh main tree2       # only these columns
bash .devcontainer/bin/enter-grid.sh --session review # tmux: glowcap-dev-grid-review
```

Each worktree configures its column through the ignored
`.devcontainer/pane/panes.sh`: plain shell that the pane runtime sources in
each of the column's panes after the container shell's `~/.zshrc`. Top-level
lines run in every pane, so an export there configures the whole column. A
`pane1`, `pane2`, … function runs as that pane's startup command, and the
highest `paneN` declared sets the column's row count (one full-height shell
when the file declares none or is absent, at most twelve). Each command behaves
as if typed at the prompt: it can be interrupted, it joins shell history, and
the pane returns to its prompt when the command exits. Re-running it takes its
function name or one up-arrow. [`panes.example.sh`](pane/panes.example.sh)
shows the shape. With `--session NAME`, a `pane/panes-NAME.sh` file is
preferred when it exists, so one worktree can carry different grids for
different sessions. A session opened by `bin/enter.sh` reads the same file and
runs no startup command, so its pane functions are defined and wait to be named
at the prompt.

## Entering and leaving the container

Every pane both launchers open keeps a shell on the host, in that worktree's
checkout, and runs the container shell inside it. Two commands move between
them:

```sh
glowcap_devcontainer_exit    # step out to the host, in this worktree
glowcap_devcontainer_enter   # go back into the container
```

`exit` ends the pane, because the shell it ends is the host shell the
container one was opened from. Only the command above steps out and keeps the
pane. On the host side the prompt carries a `(host <worktree>)` marker, and you
can `cd` anywhere and run whatever the host has.

Going back in runs that pane's startup command again, so leaving and
re-entering restarts what the pane runs. Add `--bare` to enter without it. If
the container stopped or was rebuilt while you were away, entering starts it
again through [`bin/up.sh`](bin/up.sh). A container shell that a signal ends
leaves the pane standing.

The container half is `pane/container/.zshrc`, because zsh is the shell the
image configures for the workspace user and zsh finds an rc only through a
directory. The host half is `pane/host/.bashrc`, found by path. Each sources
your own `~/.zshrc` or `~/.bashrc` first and adds the two commands to it.

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

Keep the lock on for the worktree's whole life. A container mounts only the
clone's `.git` at its host path, so inside one the registered paths of every
linked worktree point at directories that do not exist there. A
`git worktree prune` run in that container removes every unlocked worktree's
registry entry and submodule stores, including its own. Git never prunes a
locked worktree.

The offset produces host ports 19080, 20099, 20200, 20300, 16173, and 12990.
The explicit offset keeps setup from guessing whether ports are free and then
racing Docker for them.

`bin/configure.sh` validates but never overwrites an existing `.env`. To change
an identity, port offset, or egress network, stop that checkout's container,
remove the ignored file, and run the command again with the new choice.

Opening that checkout creates `glowcap-dev-tree1`, though its branch is
`failure-sweep`. Startup refuses a linked-worktree directory whose name does
not match. Names start with a letter, contain only lowercase letters and
digits, and are at most 12 characters.

These are host-global Docker names. Two independent glowcap clones may run
together only when their worktree names differ. Startup refuses a duplicate
container name.

The ignored file also records two Git-owned paths: `GLOWCAP_CHECKOUT_DIR`, the
absolute path to this checkout, and `GLOWCAP_GIT_COMMON_DIR`, derived from:

```sh
git rev-parse --path-format=absolute --git-common-dir
```

All worktrees of one primary checkout share the common-directory value. Linked
worktrees keep their administrative Git state there, and their `.git` files
can contain its absolute host path. Compose mounts both paths at their
identical host locations inside every container and keeps `/workspaces/glowcap`
as the ordinary workspace. The checkout's same-path alias gives linked-worktree
submodules absolute Git paths that resolve from both sides. Primary clones use
relative submodule links so they survive a checkout move. The explicit mounts
are necessary because the Dev Containers CLI does not apply its automatic Git
mounts to custom Compose workspace mounts.

The same file owns that worktree's host ports. The primary checkout uses
offset 0: 9080, 10099, 10200, 10300, 6173, and 2990. Host port 8080 is
reserved for the Rooms deployment, and development configuration refuses it
even when that deployment is stopped. Linked worktrees choose distinct offsets
with `configure.sh --port-offset`. The generated `tree1` file contains:

```dotenv
GLOWCAP_ROOMS_WEB_HOST_PORT=19080
GLOWCAP_ROOMS_CAPTP_HOST_PORT=20099
GLOWCAP_ROOMS_RELAY_HOST_PORT=20200
GLOWCAP_ROOMS_TRACE_HOST_PORT=20300
GLOWCAP_OCAPNVIZ_HOST_PORT=16173
GLOWCAP_DOCS_HOST_PORT=12990
```

The file uses one plain `KEY=value` assignment per line. Exported host
variables take precedence over Compose `.env` files, so startup refuses an
inherited `GLOWCAP_*` or `EGRESS_NET` value that differs from this checkout's
file.

## What runs when

| Phase | What runs |
| --- | --- |
| Before creation | `hooks/initialize.sh` creates the shared host agent-state paths and missing primary-checkout configuration, validates Git identity and ports, and prepares the managed Docker networks |
| Image build | `Dockerfile`, `image/` installers, then `image/verify-toolchains.sh` |
| First open | `hooks/post-create.sh` verifies host binds are writable, proves the Zig cache filesystem, checks pins, holds the container to the environment Compose declares, and fills the conformance submodules |
| Development | You run `zig build check` and focused build steps |

## Toolchains

Versions and canonical paths live in [`pins.sh`](pins.sh). Download hashes live
in [`checksums.sh`](checksums.sh).

| Group | Tools | Installer |
| --- | --- | --- |
| Base images | Debian for development and distroless Debian for the Rooms runtime, pinned by digest | `Dockerfile`, `apps/rooms/web/deploy/rooms.Dockerfile` |
| Production database | PostgreSQL's latest stable Alpine image, pinned by version and digest | `apps/rooms/web/deploy/docker-compose.yml` |
| Workspace shell | zsh (`/bin/zsh`), which the pane runtime execs | `Dockerfile` |
| Zig | Zig and its matching ZLS language server | `image/zig.sh`, `image/zls.sh` |
| Conformance | Python, Racket, and Goblins | `image/python.sh`, `image/racket-goblins.sh` |
| Bindings | Rust, its Wasm target, wasm-bindgen, Deno, Node, npm, and Bun | `image/rust.sh`, `image/rust-wasm.sh`, `image/js-toolchains.sh` |
| Browsers | Playwright's Chromium and the libraries it needs | `image/playwright.sh` |
| Agents | Serena (image-pinned). Claude Code, Codex, opencode, and the Cursor agent CLI as managed tools on first use | `image/serena.sh`. `.devcontainer/tools` |
| Search | ripgrep (`rg`), which every agent CLI here reaches for by default | `Dockerfile` |
| Debugging | gdb, lldb, strace, valgrind, perf, hyperfine | `Dockerfile` |
| Tor | the `tor` daemon the `onion` netlayer's live checks talk to | `Dockerfile` |

The image installs the Rust browser target and the `wasm-bindgen` compiler.
The compiler version comes from `apps/rooms/rust/Cargo.lock`, which the image
copies and checks its installed compiler against.

ZLS is built from the checksummed source revision in `pins.sh`. A ZLS refresh
must compile with the selected Zig before the image counts as verified.

The image also puts the repository's CapTP CLI on PATH: `glowcap` links to the
repo-root development launcher, which runs `zig-out/product/bin/glowcap`. The
launcher bootstraps a missing product once. Run `zig build rooms-release` after
source edits. Session and inspection commands use the existing product. On
Linux, checkout deployment `up` and `reset` prepare the current source
automatically. `./glowcap install` uses the same verified product installer as
a platform archive. The [CLI](../docs/cli.md) is callable from any directory in
the container. The launcher and agent workflow share `.devcontainer/bin/run.sh`
for environment selection and a per-checkout build lease. Installed product
executables do not enter containers or run compilers.

Supply build environment overrides through the front:

```sh
.agents/skills/work/bin/glowcap-dev --env CARGO_BUILD_JOBS=1 zig build rooms-rust-test -j1
```

`-j1` limits Zig's build graph, and Cargo sets its child concurrency
separately. The front passes `--env` values into the selected environment and
refreshes Zig's cached configuration so its Run steps receive them. Compiled
artifacts stay cached, and the build lease and per-test deadline stay active.
Compilation and linking are outside that deadline, so a slow gate needs
timings from those processes as well as from the tests.

A tool run through `docker exec` writes files as the container's user, so a
`zig fmt` that rewrites files leaves them owned by that user and the host
session can no longer edit them. Chown the touched paths back to the host
user after a container-side format, or format from the front, which keeps
ownership on the side the session edits from.

The front reads some variables itself, on the host, before selection.
`GLOWCAP_DEV_WORKDIR` names the checkout to mount and takes the prefix form,
`GLOWCAP_DEV_WORKDIR=... glowcap-dev ...`. A host-side prefix on any other
variable stops at the front, so a child that needs an environment value gets it
through `--env`.

Cargo keeps intermediate objects, fingerprints, and incremental state on the
worktree's Linux volume. Final artifacts keep their declared output paths. The
build front applies this to existing containers too. Native Linux Rust links
use the active compiler's bundled LLD. Rooms tests retain source locations for
backtraces, and `--env CARGO_PROFILE_TEST_DEBUG=2` gives full debugger data.
The container defaults to four Cargo jobs, and `--env CARGO_BUILD_JOBS=N`
overrides that. Changing linker or debug settings requires one rebuild.
Native Rooms tests and peers build only the static archives and iroh companion
they link. Rust lint checks metadata without rebuilding native transport
archives. Browser proofs reuse the browser library, and `rooms-browser-build`
alone requests its deployable Wasm module. The contract crate also builds a
library for native tests, so browser proof steps request its Wasm module
explicitly and skip an unused native shared-library link. Browser contracts use
the separate `browser-proof` profile with optimized loops and parallel code
generation. Deployment modules keep whole-program optimization. The source
analyzer uses optimized code with safety checks, and its checks and scope are
unchanged.

## Managed tools: the AI harnesses

`claude`, `codex`, `opencode`, and the Cursor agent CLI (`agent` and
`cursor-agent`) are not installed by the image, and neither is Playwright's
browser set. A harness's first PATH use installs the checkout's seed into the
shared cache at `~/.cache/glowcap/installed/<platform>/<tool>`. The seed is
the version `pins.sh` names, verified by registry integrity for npm packages
and by checksum for archives. Every worktree container shares that cache, so
one download serves all of them and a rebuild keeps the installed version.

Playwright is the first exact-requirement asset. Its registry row is
`pinned`, its requirement is the checkout's `PLAYWRIGHT_VERSION` pin, and
several requirements can coexist in the cache. Browser proof steps run under
the front's exec seam, which prepares the exact requirement and points the
command at its browser directory:

```sh
.devcontainer/bin/tools.sh exec playwright -- deno run --allow-all tools/some-browser-step.ts
```

The image keeps only the apt libraries the browsers launch against
(`image/playwright.sh`). An apt operation belongs to the image, not to a
running container. If a later pin names libraries the image does not carry, a
rebuild runs the dependency install for that pin.

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
Updates are explicit and persist across rebuilds. A pin bump is adopted on the
next ensure or the next cold first use. `claude install` and
`opencode uninstall` are refused, because native installer migration and
shared-cache removal are not managed operations. Each install carries a receipt
recording what was installed, from where, and how it was verified. Upstream
tarballs that publish no digest (Cursor) are recorded as unverified. The
container has no browser, so sign in with `NO_OPEN_BROWSER=1 agent login` and
open the printed URL on the host. `agent status` says who you are.

No Tor runs when the container opens. glowcap reaches an onion service through
a daemon its deployer started, so the library never starts, supervises, or
configures one. The image installs the binary and stops there. A check that
needs a live daemon starts its own with its own configuration and shuts it
down again. The in-tree onion checks talk to a fake daemon and need no Tor.

## Updating pins

Use [`bin/update-pins.sh`](bin/update-pins.sh) to update a tool:

```sh
.devcontainer/bin/update-pins.sh               # report pins vs upstream + submodule drift
.devcontainer/bin/update-pins.sh bump <dep>    # rewrite the pin and everything restating it
.devcontainer/bin/update-pins.sh bump --safe   # bump everything outside the build graph
```

It fetches versions and hashes from each dependency's release channel, then
validates every edit before replacing a file. Rebuild the container when an
updated tool is installed there. The four harness seeds are not image content,
so their check is the cold-seed smoke run (`test/tool-install.sh <name>`), and
the running cache adopts a bumped seed on the next `tools.sh ensure` or cold
first use. The report also lists the checks required for each dependency. Zig
requires `zig build check`, Racket and Goblins require
`zig build check-external`, and a deployment image such as PostgreSQL lists its
Compose and application checks.

A few pins are restated outside `pins.sh`, because a Dockerfile and a
`deno.json` cannot source a shell file. A bump rewrites those copies with the
pin, and `test/env-sync.sh` fails the build if one drifts. Path changes are
hand edits: keep the `Dockerfile` environment and `devcontainer.json`
`containerEnv` aligned with `pins.sh`, which the same check enforces.

The script's modules are in `lib/`, one per subject, named
`update-pins-*.sh`. To track a new dependency, add it to
[`lib/update-pins-deps.sh`](lib/update-pins-deps.sh): a name in
`GLOWCAP_PINS_DEPS`, its `pins.sh` variable, how a bump is proven, and the
query that asks its release channel for the latest version. If a file outside
`pins.sh` also names that version, add a row in
`lib/update-pins-companions.sh`. The bump rewrites the file from that row, and
`test/env-sync.sh` reads the same row to check it.

Host-side startup also uses the `DEVCONTAINER_CLI_VERSION` pin. An installed
CLI is used only when its version matches. Otherwise `npx` runs the pinned
release.

The pin report covers image tools and conformance submodules. A complete
dependency refresh also covers these owners. [Dependencies](../docs/dependencies.md)
says what each group is for, and `source-check` fails when a pinned tool or Zig
package is missing from it.

| Dependency | Update and evidence |
| --- | --- |
| Devcontainer features | Run the pinned `@devcontainers/cli`'s `upgrade --workspace-folder .`. Rebuild to exercise the regenerated feature lock |
| Rust crates | Update direct requirements, then `cargo update` in each crate or workspace. Run the affected Zig build steps and `runtime-check` |
| Deno packages | Update imports and task specifiers together, then `deno update --frozen=false` in each scope. Normal builds keep frozen locks |
| Python packages | Update direct requirements, then `uv lock --upgrade --project <directory>`. Run binding and conformance checks |
| Zig packages | Review upstream changes, then move each `build.zig.zon` entry (root and `site/`). Fetch each over `git+https` at a commit, so `zig fetch --save` gives the hash the build checks. Update its revision and notice in `LICENSE-THIRD-PARTY`, and exercise the consuming build steps, including `site` and `cli-test` |
| CI actions | Resolve current releases to full commit hashes. Keep workflow references immutable |

An update is verified only with the new tool or dependency in use. Source
checks do not prove a new base image or feature installation.

## Persistent paths

Generated bytes have distinct owners. The wrong owner causes a race, a cold
rebuild, or a `git clean` that throws away the wrong thing.

The **image** holds compilers, Goblins in `PLTUSERHOME`, rustup, uv tools, and
the Cursor agent binary. A pin bump is a rebuild.

The **host user** holds agent logins, downloads, and language-manager caches.
Those scoped binds are in [`devcontainer.json`](devcontainer.json). The tree is
`~/.cache/glowcap` on the host and `/home/vscode/.cache/glowcap` in the
container, with a `LAYOUT` file at the root. [Host
configuration](docs/host-configuration.md) covers the shared mounts.

Each worktree keeps Zig's local cache and extracted packages in a Docker named
volume. That gives Zig the Docker daemon's filesystem semantics under native
Linux Docker and Docker Desktop, instead of the atomic-file behavior of a host
bind. The volume name is `glowcap-dev-<worktree>-zig-work`, so worktrees do
not share build objects.

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

The last two rows keep an agent CLI's settings across a rebuild. Both tools
choose their state directory from the environment, and both point at the
directories [`devcontainer.json`](devcontainer.json) binds from the host. The
Cursor agent CLI on Linux writes login tokens under `~/.config/cursor`, so that
path is a separate host bind.

Playwright's browsers are runtime content. The shared browser prerequisite in
`build.zig` runs `tools.sh ensure playwright`, which installs the checkout's
pinned requirement into the shared cache on first browser use. Every browser
proof step (`zig build rooms-web-page` and its siblings) runs under
`tools.sh exec playwright`, which points the process at that installation.
Browser garbage collection is off, so one worktree's run cannot delete another's
installation. A browser in the container's own `~/.cache/ms-playwright` would
vanish with the container, and nothing points Playwright there.

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml). `perf` may
still depend on host kernel policy. Racket's package tool has no version flag:
use `racket --version`, not `raco --version`.

## Host and network setup

Two guides cover the parts that vary by machine:

- [Docker networking](docs/networking.md): the rooms network, the private egress
  network, and how the rooms peer reaches the deployed app.
- [Host configuration](docs/host-configuration.md): Git, SSH, shared agent and
  authentication state, keyrings, and commit signing.

### Ports the container forwards

`docker-compose.yml` publishes six ports on host loopback: the rooms web page
(8080), the rooms directory's CapTP listener (9099), the reference relay
(9200), the protocol-visualizer trace feed (9300), the ocapnviz Vite dev
server (5173), and the documentation preview (1990). Services use those
canonical numbers inside the container, and their host ports come from `.env`.
The primary checkout's web page is `http://localhost:9080`, and the example
worktree above uses `http://localhost:19080`. The ocapnviz page and the docs
preview open as localhost on that published port. A tailnet listener such as
Tailscale Serve can bind the same numbers on the machine's tailnet addresses
without colliding with this publish.

`zig build rooms-dev` binds its Vite listener to the container interface and
keeps its native backend on an ephemeral container-loopback port, so the
published web port is the only Rooms development address exposed to the host.
Outside the container, the same command defaults to host loopback.

The ports are declared because an editor-guessed forward goes away when the
editor stops noticing the listener. [`apps/rooms/developing.md`](../apps/rooms/developing.md)
uses canonical container ports, and a host-side client uses the matching
`*_HOST_PORT` value. For the example above, the live trace is
`ws://127.0.0.1:20300/`.

If a host port is already taken, the container does not start. Inspect its owner
before choosing a different offset. Existing `.env` files keep their ports when
`configure.sh` runs. To change an assignment, edit the six `*_HOST_PORT` values
together, keeping the checkout paths and egress network. Then recreate the
devcontainer from a host shell with `bash .devcontainer/bin/up.sh --rebuild`.
This disconnects sessions inside that devcontainer, and restarting it alone does
not change the published ports.

## Layout

The root holds what the container tooling requires by name, the two files that
carry versions, and the front-door prose.

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

Each script declares where it runs and refuses the wrong side: host-side
scripts call `glowcap_require_host`, container-side ones
`glowcap_require_devcontainer`, and `lib/context.sh` owns the detection. The
shared fronts and tests state their supported environments in their headers.
`image/zig.sh` also runs on CI runners, macOS included.
`hooks/post-create.sh` runs shellcheck over every shell file here, so a lint
finding fails container open and the CI push checks.

| File | Role | Runs |
| --- | --- | --- |
| `devcontainer.json` | Editor settings, mounts, and the lifecycle hooks | editor / CLI |
| `Dockerfile` | Builds the image | image build |
| `docker-compose.yml` | Worktree-specific container and image names, networks, host ports, and ptrace | host compose |
| `.env.example` | Annotated primary-checkout form generated by `bin/configure.sh` | host |
| `pins.sh`, `checksums.sh` | Versions, paths, and download hashes | sourced |
| `.shellcheckrc` | One lint setting for editors, hand runs, and the hook alike | sourced by shellcheck |
| `bin/configure.sh` | Creates the ignored checkout identity, paths, ports, and egress name | host |
| `bin/up.sh` | Starts or rebuilds the container from a host shell | host |
| `bin/container-id.sh` | Names this checkout's running container, starting it when it is down | host |
| `bin/enter.sh` | Starts or reuses a worktree container and attaches its default or a named tmux session | host |
| `bin/enter-grid.sh` | Starts or reuses every column worktree's container and attaches one tmux grid, rows per column set by each worktree's `pane/panes.sh` | host |
| `bin/update-pins.sh` | Reports and bumps the pins against upstream | container |
| `bin/run.sh` | Selects the development environment and runs the checkout launcher's or agent's build | host or container |
| `bin/tools.sh` | The managed-tool maintenance front: status, ensure, update, repair | container |
| `tools/wrapper.sh`, `tools/lib/` | The dispatcher every managed command name links to, plus the shared lifecycle and one driver per harness: first use installs the checkout's seed, updates are explicit and intercepted, selections persist across rebuilds | container, entered through the PATH links |
| `image/tool-links.sh` | Links every managed command name to the checkout's dispatcher. Installs nothing | image build |
| `bin/build-lease` | Serializes finite builds over one checkout | host or container (Python 3) |
| `lib/mod.sh` | The library's front door, and the one call that loads a checkout's pins | sourced |
| `lib/launcher.sh` | Shared mechanics of the tmux launchers: option grammar, checkout resolution, pane commands, attach | sourced |
| `lib/update-pins-*.sh` | `bin/update-pins.sh`'s modules, one subject each: the dependency table and its release channels, staged edits to `pins.sh` and `checksums.sh`, and the files outside `pins.sh` that restate a pin | sourced |
| other `lib/*.sh` | One subject each: context guards, name grammars, settings tables, checkout lookup, the ignored `.env`, Docker, verified downloads | sourced |
| `image/zig.sh` | Installs pinned Zig | image build, container, CI runners |
| other `image/*.sh` | Installs one toolchain group | image build + container |
| `image/verify-toolchains.sh` | Checks installed versions | image build + container |
| `hooks/initialize.sh` | Bootstraps and validates checkout configuration, then prepares managed networks | host |
| `hooks/post-create.sh` | Verifies an open container and fills the conformance submodules | container |
| `hooks/verify-ptrace.sh` | Checks ptrace access | container |
| `hooks/verify-compose-env.sh` | Holds the running container to the environment Compose declares, so one created before a new variable says so instead of falling back to a default | container |
| `pane/host/.bashrc` | Host half of the pane runtime: enters the container, and decides whether the pane ends with the shell that leaves it | host |
| `pane/container/.zshrc` | Container half: initializes the shell, runs that pane's function from the worktree's ignored `pane/panes.sh`, and owns `glowcap_devcontainer_exit` | container |
| `pane/panes.example.sh` | The shape a worktree's own `pane/panes.sh` takes | example |
| `test/env-sync.sh` | Checks pins, mounts, names, structure, and host lifecycle contracts | anywhere |
| `test/tool-runtime.sh` | Offline black-box proof of the managed-tool lifecycle and forwarding, with stub drivers and stub release metadata | devcontainer (prints a visible skip elsewhere) |
| `test/tool-install.sh` | Strict cold-seed proof: every named harness installs its exact seed through the real dispatcher into an isolated root | container, network |
| `test/tool-shared-cache.sh` | Two-container exclusion proof on one shared filesystem, from a candidate image | host (Docker) |
| `test/build-front.sh` | Tests host/container routing, launcher bootstrap and build-independent operation, streams, timeout injection, and the build lease | Host or devcontainer (needs Bash and Python 3) |
| `test/host-invariants.sh` | Tests checkout configuration, identity, networks, Git-owned lookup, and the pane runtime | Host or devcontainer (needs Bash and Git) |

`test/env-sync.sh` runs in `zig build source-check`. The two executable
behavior tests run in `zig build infrastructure-check`, so a source-only edit
does not create temporary repositories or exercise host workflow.

Cursor users can enable Serena from [`.cursor/mcp.json`](../.cursor/mcp.json).
The [Serena skill](../.agents/skills/serena/SKILL.md) covers project use.
