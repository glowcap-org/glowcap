# glowcap devcontainer

This is the supported ready-to-build environment for VS Code and Cursor. It
installs Zig, conformance tools, binding runtimes, the Chromium the browser
proofs drive, and debugging utilities. The project check remains
`zig build check`.

Open the repository with **Dev Containers: Reopen in Container**, then run:

```sh
zig build check
```

On first use, `hooks/initialize.sh` runs
[`bin/configure.sh`](bin/configure.sh). The primary checkout needs no setup:
the command derives its Git common directory, writes the ignored `.env`, and
creates an isolated `glowcap-dev-main-egress` network. `hooks/post-create.sh` runs
automatically after the image is ready, verifies the toolchains, and initializes
the conformance submodules before the editor opens the workspace.

The same container can be started from a host shell instead.
[`bin/up.sh`](bin/up.sh) drives the [devcontainer
CLI](https://github.com/devcontainers/cli), the engine behind the editor
commands, so the editor later attaches to, reuses, or rebuilds the container it
started as if the editor had created it:

```sh
bash .devcontainer/bin/up.sh              # Reopen in Container
bash .devcontainer/bin/up.sh --rebuild    # Rebuild Container
bash .devcontainer/bin/up.sh --no-cache   # Rebuild Container Without Cache
```

[`bin/enter.sh`](bin/enter.sh) wraps that in tmux. It starts or reuses the named
worktree's container, then attaches the default tmux session or an explicitly
named alternate session. `glowcap` is the CapTP CLI inside the container, so
the host launcher does not take that name. Run it from the checkout, or symlink
it onto the host `PATH` under another name:

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
contains no host path and works from any current directory. `main` is that
checkout. Every other name must be a linked worktree Git lists with that
directory basename. The launcher always asks the selected checkout's own
`up.sh` to start or reuse the container, looking under `bin/` first and
beside compose if that checkout has not moved it yet, then attaches.

The option `--session NAME` selects another tmux session without creating
another Docker container. Omitting it preserves the default
`glowcap-dev-<worktree>` session; supplying it uses
`glowcap-dev-<worktree>-<name>`. Each session opens its own shell, while all
sessions for a worktree share that container's processes and filesystem.
A session designator starts with a lowercase letter, ends with a
lowercase letter or digit, contains only lowercase letters, digits, and
hyphens, and is at most 24 characters. Reusing the same command rejoins that
exact session.

From iTerm2, both launchers attach in tmux control mode (`tmux -CC`), so
sessions and panes render as native iTerm2 windows and splits. Every other
terminal attaches as an ordinary tmux client. Pass `--cc` or `--no-cc` to
force either behavior; detection covers a local iTerm2 tab and, with iTerm2's
shell integration installed, an ssh session from one.

The same identity names both Docker artifacts. A `tree1` checkout uses the
container `glowcap-dev-tree1` and builds the image `vsc-glowcap-dev-tree1`.

[`bin/enter-grid.sh`](bin/enter-grid.sh) opens many worktrees at once: one tmux
session holding a grid with one column per worktree. With no arguments, every
worktree Git registers becomes a column; naming worktrees narrows the grid to
those columns. It runs that checkout's own `up.sh`, looking under `bin/` first
and beside compose if that checkout still keeps it there, so each column keeps
the tooling and ports it was built with. `--rebuild`, `--no-cache`,
`--session`, `--cc`, and `--no-cc` work as in `bin/enter.sh`, with sessions
named `glowcap-dev-grid` or `glowcap-dev-grid-<name>`. Percentage splits need tmux 3.1
or newer.

```sh
bash .devcontainer/bin/enter-grid.sh                  # tmux: glowcap-dev-grid
bash .devcontainer/bin/enter-grid.sh main tree2       # only these columns
bash .devcontainer/bin/enter-grid.sh --session review # tmux: glowcap-dev-grid-review
```

Each worktree configures its own column through the ignored
`.devcontainer/pane/panes.sh` in that checkout: plain shell that the pane
runtime sources in each of the column's panes after the container shell's own
`~/.zshrc`. Top-level lines run in every pane, so an export there configures
the whole column. A `pane1`, `pane2`, … function runs as that pane's startup
command, and the highest `paneN` declared sets the column's row count: one
full-height shell when the file declares none or is absent, at most twelve.
Each command behaves as if typed at the prompt: it can be interrupted, it joins
shell history, and the pane returns to its prompt when the command exits, so
re-running it is its function name or one up-arrow.
[`panes.example.sh`](pane/panes.example.sh) shows the shape. With `--session
NAME`, a `pane/panes-NAME.sh` file is preferred when it exists, so one worktree
can carry different grids, and different row counts, for different sessions. A
session opened by `bin/enter.sh` reads the same file and runs no startup
command, so its pane functions are defined and waiting to be named at the
prompt.

## Entering and leaving the container

Every pane both launchers open keeps a shell on the host, in that worktree's
checkout, and runs the container shell inside it. Two words move between them:

```sh
glowcap_devcontainer_exit    # step out to the host, in this worktree
glowcap_devcontainer_enter   # go back into the container
```

`exit` still ends the pane, container shell and tmux pane together, because
the shell it ends is the host shell the container one was opened from. Only
the verb above steps out and keeps the pane. On the host side the prompt
carries a `(host <worktree>)` marker, and you are free to move around: `cd`
anywhere, run whatever the host has, and come back when you want the
container again.

Going back in runs that pane's startup command again, so leaving and
re-entering is how a pane restarts what it runs. Add `--bare` to enter without
it, for a look around that must not restart a server. If the container stopped
or was rebuilt while you were away, entering starts it again through
[`bin/up.sh`](bin/up.sh), and a container shell that a signal ends leaves the
pane standing rather than closing it.

Each side is named for the shell that reads it. The container half is
`pane/container/.zshrc`, because zsh is what the image configures for the
workspace user, and zsh finds an rc only through a directory, which is why
that side is a directory holding one file. The host half is
`pane/host/.bashrc`, the shell most hosts still start scripts with, found by
path. Neither one replaces your shell: each sources your own `~/.zshrc` or
`~/.bashrc` first and adds the two verbs to it.

## Worktree identity

Each checkout has one short name in its ignored `.devcontainer/.env`.
[`bin/configure.sh`](bin/configure.sh) derives the name and Git common
directory. The primary checkout uses `main`, so its Docker container is
`glowcap-dev-main`. A linked worktree uses the same lowercase name as its
directory; its branch name remains independent. Create and configure one with:

```sh
git worktree add --lock .worktrees/tree1 -b failure-sweep
cd .worktrees/tree1
bash .devcontainer/bin/configure.sh --port-offset 10000
```

The lock matters. A container mounts only the clone's `.git` at its host path,
so from inside one the registered paths of every linked worktree point at
directories that do not exist there. A `git worktree prune` run in that
container removes every unlocked worktree's registry entry and submodule
stores, including its own. Git never prunes a locked worktree, so keep the
lock on for the worktree's whole life.

The offset produces host ports 19080, 20099, 20200, 20300, 16173, and 12990.
Requiring that one explicit choice prevents a setup command from guessing
whether ports are free and then racing Docker for them.

`bin/configure.sh` validates but never overwrites an existing `.env`. To change
an identity, port offset, or egress network, stop that checkout's container,
remove the ignored file, and run the command again with the new choice.

Opening that checkout creates `glowcap-dev-tree1`, even though its branch is
`failure-sweep`. Startup refuses a mismatched linked-worktree directory instead
of attaching an ambiguous container name. Names start with a letter, contain
only lowercase letters and digits, and are at most 12 characters.

These names are host-global Docker names. Two independent glowcap clones may
run together only when their worktree designators differ; startup refuses a
duplicate container name rather than guessing which checkout the user meant.

The ignored file also records two Git-owned paths: `GLOWCAP_CHECKOUT_DIR`,
the absolute path to this checkout, and `GLOWCAP_GIT_COMMON_DIR`, derived from:

```sh
git rev-parse --path-format=absolute --git-common-dir
```

All worktrees belonging to one primary checkout share the common-directory
value. Linked worktrees keep their administrative Git state there, and their
`.git` files can contain its absolute host path. Compose mounts both paths at
their identical host locations inside every container while keeping
`/workspaces/glowcap` as the ordinary workspace. The checkout's same-path alias
gives linked-worktree submodules absolute Git paths that resolve from both
sides. Primary clones use relative submodule links so they also survive a
checkout move. These explicit mounts are necessary with the current Dev Containers
CLI: its automatic Git mounts are not applied to custom Compose workspace
mounts.

The same ignored file owns that worktree's host ports. The primary checkout
uses offset 0: 9080, 10099, 10200, 10300, 6173, and 2990. Host port 8080
is reserved for the Rooms deployment; development configuration refuses it
even when that deployment is stopped. Linked worktrees choose distinct offsets
with `configure.sh --port-offset`. The generated `tree1` file
contains:

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
| Agents | Serena, Claude Code, the Cursor agent CLI, opencode, and Codex | their `image/` installers |
| Search | ripgrep (`rg`), which every agent CLI here reaches for by default | `Dockerfile` |
| Debugging | gdb, lldb, strace, valgrind, perf, hyperfine | `Dockerfile` |
| Tor | the `tor` daemon the `onion` netlayer's live checks talk to | `Dockerfile` |

The Rust browser target and `wasm-bindgen` compiler are installed by the image.
The compiler version comes from `apps/rooms/rust/Cargo.lock`; the image copies
that lockfile and verifies its installed compiler against it.

ZLS is built from the checksummed source revision in `pins.sh`.
`image/zls.sh` applies `image/patches/zls-directory-contents.patch` for the
pinned Zig's build API. A ZLS refresh must recheck or remove that patch and
compile with the selected Zig before the image can be considered verified.

The image also puts the repository's own CapTP CLI on PATH: `glowcap` links to
the repo-root development launcher, which runs `zig-out/product/bin/glowcap`.
It bootstraps a missing product once; use `zig build rooms-build` explicitly
after source edits. Operating an existing product does not acquire a build lease.
The launcher also serves `./glowcap install`, which uses the same verified
product installer as a platform archive. The [CLI](../docs/cli.md) is callable
from any directory in the container.
The launcher and agent workflow share `.devcontainer/bin/run.sh` for environment
selection and a per-checkout build lease. Installed product executables do not
enter containers or run compilers.

Cursor's agent CLI answers to both of the names upstream installs, `agent` and
`cursor-agent`. Upstream unpacks it into the user's home directory; here it is
part of the image, under `/usr/local/share/cursor-agent`, so the pinned build
comes with the container. Its own `agent update` still writes into
`~/.local/bin`, which sits after `/usr/local/bin` on the path, so the pinned
build keeps answering and `bin/update-pins.sh` stays the way to move it. There
is no browser in the container, so sign in with `NO_OPEN_BROWSER=1 agent login`
and open the printed URL on the host; `agent status` says who you are.

No Tor is running when the container opens, and that is deliberate: glowcap
reaches an onion service through a daemon whoever deployed it started, so the
library never starts, supervises, or configures one. The image installs the
binary and stops there. A check that needs a live daemon starts its own with its
own configuration and shuts it down again; the in-tree onion checks talk to a
fake daemon instead and need no Tor at all.

To update a tool, use [`bin/update-pins.sh`](bin/update-pins.sh) rather than
editing by hand:

```sh
.devcontainer/bin/update-pins.sh               # report pins vs upstream + submodule drift
.devcontainer/bin/update-pins.sh bump <dep>    # rewrite the pin and everything restating it
.devcontainer/bin/update-pins.sh bump --safe   # bump everything outside the build graph
```

It fetches versions and hashes from each dependency's own release channel,
then validates every edit before replacing a file. Rebuild the container when
an updated tool is installed there. The report also lists the checks required
for that dependency. For example, Zig requires `zig build check`, while Racket
and Goblins require `zig build check-external`. A deployment image such as
PostgreSQL lists its Compose and application checks instead.

A few pins are restated outside `pins.sh`, because a Dockerfile and a
`deno.json` cannot source a shell file. A bump rewrites those copies with the
pin itself, so they cannot fall a version behind, and `test/env-sync.sh` fails
the build if one ever does. Path changes are still hand edits: keep the
`Dockerfile` environment and `devcontainer.json` `containerEnv` aligned with
`pins.sh`, which the same check enforces.

The script's own modules are in `lib/`, one per subject, named
`update-pins-*.sh`. To start tracking a new dependency, add it to
[`lib/update-pins-deps.sh`](lib/update-pins-deps.sh): a name in
`GLOWCAP_PINS_DEPS`, its `pins.sh` variable, how a bump is proven, and the query
that asks its release channel what the latest version is. If a file outside
`pins.sh` also names that version, give it a row in
`lib/update-pins-companions.sh` and you are done: the bump rewrites it from that
row, and `test/env-sync.sh` reads the same row to check it.

Host-side startup also uses the `DEVCONTAINER_CLI_VERSION` pin. An installed
CLI is used only when its version matches; otherwise `npx` runs the pinned
release.

The pin report covers image tools and conformance submodules. A complete
dependency refresh also checks these owners:

| Dependency | Update and evidence |
| --- | --- |
| Devcontainer features | Run the pinned `@devcontainers/cli`'s `upgrade --workspace-folder .`; rebuild to exercise the regenerated feature lock |
| Rust crates | Update direct requirements, then `cargo update` in each crate or workspace; run the affected Zig build steps and `runtime-check` |
| Deno packages | Update imports and task specifiers together, then `deno update --frozen=false` in each scope; normal builds keep frozen locks |
| Python packages | Update direct requirements, then `uv lock --upgrade --project <directory>`; run binding and conformance checks |
| Vendored code and Zig packages | Review upstream changes, retain only required compiler adaptations, record exact revisions, and exercise the consuming build steps, including `site` |
| CI actions | Resolve current releases to full commit hashes; keep workflow references immutable |

An update is verified only with the new tool or dependency in use. Source
checks alone do not prove a new base image or feature installation.

## Persistent paths

Generated bytes here have distinct owners. The wrong owner is a race, a cold
rebuild, or a `git clean` that throws away the wrong thing.

The **image** holds compilers, Goblins in `PLTUSERHOME`, Playwright browsers,
rustup, uv tools, and the Cursor agent binary. A pin bump is a rebuild.

The **host user** holds agent logins, downloads, and language-manager caches.
Those scoped binds are in [`devcontainer.json`](devcontainer.json). Look at
`~/.cache/glowcap` on the host and `/home/vscode/.cache/glowcap` in the
container: same tree, with a `LAYOUT` file at the root. [Host
configuration](docs/host-configuration.md) covers the shared mounts.

Each worktree keeps Zig's local cache and extracted packages in a Docker named
volume. This gives Zig the Docker daemon's filesystem semantics under native
Linux Docker and Docker Desktop instead of inheriting whichever atomic-file
behavior a host bind provides. The volume name is
`glowcap-dev-<worktree>-zig-work`, so worktrees do not share build objects.

| Path | Owner | What |
| --- | --- | --- |
| `tool/zig` | `ZIG_GLOBAL_CACHE_DIR` | Zig compiler / global cache |
| `tool/deno`, `npm`, `pip`, `bun`, `uv`, `zls` | those tools' cache vars | shared downloads |
| `cargo/` | `CARGO_HOME` | registry, git, `cargo install` bins |
| `/home/vscode/.cache/glowcap-dev-zig-work/zig-local` | `ZIG_LOCAL_CACHE_DIR` | that container's Zig compile objects |
| `/home/vscode/.cache/glowcap-dev-zig-work/zig-pkg` | `ZIG_LOCAL_PKG_DIR` | that container's extracted Zig packages |

Checkout paths that are **install products or product state** stay on the
worktree bind, where the tree already names them:

| Path | Why it stays |
| --- | --- |
| `zig-out/` | install prefix (`bin/`, `lib/`, wasm, site, benches) |
| crate `target/` | sidecar `.a` files and relay bins the Zig graph links by path |
| `.local/` | occupancy and MCP scratch |

`git clean -fdx` still removes those worktree paths. It no longer removes
incremental Zig objects or extracted packages. After recreate, leftover
`.zig-cache/`, `zig-pkg/`, and Racket `compiled/` directories in the checkout
are unused; post-create deletes them.

| Variable | During image build | In an open container |
| --- | --- | --- |
| `CARGO_HOME` | `/usr/local/cargo` | `~/.cache/glowcap/cargo` host bind |
| `RUSTUP_HOME` | `/usr/local/rustup` | unchanged |
| `PLAYWRIGHT_BROWSERS_PATH` | `/usr/local/share/ms-playwright` | unchanged |
| `PLTUSERHOME` | `/opt/glowcap-racket-userhome` | unchanged |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/glowcap/tool/zig` | same path on the host bind |
| `ZIG_LOCAL_CACHE_DIR` | unset (image build uses a checkout `.zig-cache`) | `zig-local` in the worktree's Docker volume |
| `ZIG_LOCAL_PKG_DIR` | unset (image build uses a checkout `zig-pkg/`) | `zig-pkg` in the worktree's Docker volume |
| `UV_CACHE_DIR` | unset | `tool/uv` on the host bind |
| `CLAUDE_CONFIG_DIR` | `/home/vscode/.claude` | same host bind mount |
| `CURSOR_CONFIG_DIR`, `CURSOR_DATA_DIR` | `/home/vscode/.cursor` | settings host bind; Linux tokens use `~/.config/cursor` |

Rustup seeds the image under `/usr/local/cargo`. The first locked cargo build
of an in-tree crate fills `cargo/` on the host bind; later builds reuse it.

The last two rows are what make an agent CLI's settings survive a rebuild.
Both tools choose their state directory from the environment, and both are
pointed at the directories [`devcontainer.json`](devcontainer.json) binds from
the host. The Cursor agent CLI on Linux still writes login tokens under
`~/.config/cursor`, so that path is a separate host bind.
[Host configuration](docs/host-configuration.md) covers the mounts themselves.

Playwright's default download directory is `~/.cache/ms-playwright`, outside
the glowcap cache bind, so a browser landing there would vanish with the
container. Browsers still belong to the image: `PLAYWRIGHT_BROWSERS_PATH`
points at a shared system directory the image build fills once. Root installs
the browsers and every user reads them, so the browser proofs
(`zig build rooms-web-page` and its siblings) run in a fresh container with no
setup step.

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml). `perf` may
still depend on host kernel policy. Racket's package tool has no version flag;
use `racket --version`, not `raco --version`.

## Host and network setup

Two detailed guides cover the parts that vary by machine:

- [Docker networking](docs/networking.md): the rooms network, the private egress
  network, and how the rooms peer reaches the deployed app.
- [Host configuration](docs/host-configuration.md): Git, SSH, shared agent and
  authentication state, keyrings, and commit signing.

### Ports the container forwards

`docker-compose.yml` publishes six ports on host loopback: the rooms
web page (8080), the rooms directory's CapTP listener (9099), the reference
relay (9200), the protocol-visualizer trace feed (9300), the ocapnviz Vite
dev server (5173), and the documentation preview (1990). Services always use
those canonical numbers inside the container. Their host ports come from
`.env`, so the primary checkout's web page is `http://localhost:9080`, while
the example worktree above uses `http://localhost:19080`. The ocapnviz page
and the docs preview open as localhost on that published port. A tailnet
listener such as Tailscale Serve can bind the same numbers on the machine's
tailnet addresses without colliding with this publish.

`zig build rooms-dev` binds its Vite listener to the container interface and
keeps its native backend on an ephemeral container-loopback port. This leaves
the published web port as the only Rooms development address exposed to the
host. Outside the container, the same command defaults to host loopback.

They are declared rather than left to the editor noticing a listener, because a
guessed forward goes away again when it stops noticing, and
[`apps/rooms/developing.md`](../apps/rooms/developing.md) uses canonical
container ports. A host-side client uses the corresponding `*_HOST_PORT` value;
for the example above, the live trace is `ws://127.0.0.1:20300/`.

If a host port is already taken, the container will not start. Inspect its
owner before choosing a different offset; the editor never silently remaps it.
Existing `.env` files retain their ports when `configure.sh` runs. To change
an existing assignment, edit its six `*_HOST_PORT` values together, preserving
the checkout paths and egress network. Recreate the devcontainer from a host
shell with `bash .devcontainer/bin/up.sh --rebuild` to apply the mapping.
This disconnects sessions inside that devcontainer; restarting it alone does
not change the published ports.

## Layout

Each directory has one job, so a reader knows where to look before opening
anything. The root holds what the container tooling requires by name, the two
files that carry versions, and the front-door prose.

| Directory | Holds |
| --- | --- |
| `bin/` | The commands a person or a tool runs: configure a checkout, bring its container up, open a tmux session, find a container, bump the pins |
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
| `bin/build-lease` | Serializes finite builds over one checkout | host or container (Python 3) |
| `lib/mod.sh` | The library's front door, and the one call that loads a checkout's pins | sourced |
| `lib/launcher.sh` | Shared mechanics of the tmux launchers: option grammar, checkout resolution, pane commands, attach | sourced |
| `lib/update-pins-*.sh` | `bin/update-pins.sh`'s own modules, one subject each: the dependency table and its release channels, staged edits to `pins.sh` and `checksums.sh`, and the files outside `pins.sh` that restate a pin | sourced |
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
| `test/build-front.sh` | Tests host/container routing, launcher bootstrap and build-independent operation, streams, timeout injection, and the build lease | Host or devcontainer (needs Bash and Python 3) |
| `test/host-invariants.sh` | Tests checkout configuration, identity, networks, Git-owned lookup, and the pane runtime | Host or devcontainer (needs Bash and Git) |

`test/env-sync.sh` runs in `zig build source-check`. The two executable behavior
tests run in `zig build infrastructure-check`, so a source-only edit does not
create temporary repositories or exercise host workflow.

Cursor users can enable Serena from [`.cursor/mcp.json`](../.cursor/mcp.json).
The [Serena skill](../.agents/skills/serena/SKILL.md) covers project use.
