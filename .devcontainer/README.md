# pancake devcontainer

This is the supported ready-to-build environment for VS Code and Cursor. It
installs Zig, conformance tools, binding runtimes, the Chromium the browser
proofs drive, and debugging utilities. The project check remains
`zig build check`.

Open the repository with **Dev Containers: Reopen in Container**, then run:

```sh
zig build check
```

On first use, `initialize.sh` runs [`configure.sh`](configure.sh). The primary
checkout needs no setup: the command derives its Git common directory, writes
the ignored `.env`, and creates an isolated `pancake-main-egress` network.
`post-create.sh` runs automatically after the image is ready and verifies the
toolchains before the editor opens the workspace.

The same container can be started from a host shell instead. [`up.sh`](up.sh)
drives the [devcontainer CLI](https://github.com/devcontainers/cli), the engine
behind the editor commands, so the editor later attaches to, reuses, or
rebuilds the container it started as if the editor had created it:

```sh
bash .devcontainer/up.sh              # Reopen in Container
bash .devcontainer/up.sh --rebuild    # Rebuild Container
bash .devcontainer/up.sh --no-cache   # Rebuild Container Without Cache
```

[`enter.sh`](enter.sh) wraps that in tmux. It starts or reuses the named
worktree's container, then attaches the default tmux session or an explicitly
named alternate session. `pancake` is the CapTP CLI inside the container, so
the host launcher does not take that name. Run it from the checkout, or symlink
it onto the host `PATH` under another name:

```sh
bash .devcontainer/enter.sh                          # tmux: pancake-main
bash .devcontainer/enter.sh --session review         # tmux: pancake-main-review
bash .devcontainer/enter.sh tree1                    # tmux: pancake-tree1
bash .devcontainer/enter.sh tree1 --session review   # tmux: pancake-tree1-review
bash .devcontainer/enter.sh tree1 --session review --rebuild

ln -s "$(pwd)/.devcontainer/enter.sh" ~/.local/bin/pancake-enter
pancake-enter tree1 --session review
```

The launcher follows its symlink and asks Git for the primary checkout, so it
contains no host path and works from any current directory. `main` is that
checkout. Every other name must be a linked worktree Git lists with that
directory basename. The launcher always asks the selected checkout's
[`up.sh`](up.sh) to start or reuse the container, then attaches.

The option `--session NAME` selects another tmux session without creating
another Docker container. Omitting it preserves the default
`pancake-<worktree>` session; supplying it uses
`pancake-<worktree>-<name>`. Each session opens its own shell, while all
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
container `pancake-tree1` and builds the image `vsc-pancake-tree1`.

[`enter-grid.sh`](enter-grid.sh) opens many worktrees at once: one tmux
session holding a grid with one column per worktree. With no arguments, every
worktree Git registers becomes a column; naming worktrees narrows the grid to
those columns. It runs the same per-checkout `up.sh` lifecycle as `enter.sh`,
so each column's panes share that worktree's container, and `--rebuild`,
`--no-cache`, `--session`, `--cc`, and `--no-cc` work as in `enter.sh`, with
sessions named `pancake-grid` or `pancake-grid-<name>`. Percentage splits
need tmux 3.1 or newer.

```sh
bash .devcontainer/enter-grid.sh                  # tmux: pancake-grid
bash .devcontainer/enter-grid.sh main tree2       # only these columns
bash .devcontainer/enter-grid.sh --session review # tmux: pancake-grid-review
```

Each worktree configures its own column through the ignored
`.devcontainer/panes.sh` in that checkout: plain bash that
[`pane-rc.sh`](pane-rc.sh) sources in each of the column's panes after the
container shell's own `~/.bashrc`. Top-level lines run in every pane, so an
export there configures the whole column. A `pane1`, `pane2`, … function runs
as that pane's startup command, and the highest `paneN` declared sets the
column's row count: one full-height shell when the file declares none or is
absent, at most twelve. Each command behaves as if typed at the prompt: it
can be interrupted,
it joins shell history, and the pane returns to its prompt when the command
exits, so re-running it is its function name or one up-arrow.
[`panes.example.sh`](panes.example.sh) shows the shape. With `--session NAME`,
a `panes-NAME.sh` file is preferred when it exists, so one worktree can carry
different grids, and different row counts, for different sessions.

## Worktree identity

Each checkout has one short name in its ignored `.devcontainer/.env`.
[`configure.sh`](configure.sh) derives the name and Git common directory. The
primary checkout uses `main`, so its Docker container is `pancake-main`. A
linked worktree uses the same lowercase name as its directory; its branch name
remains independent. Create and configure one with:

```sh
git worktree add .worktrees/tree1 -b failure-sweep
cd .worktrees/tree1
bash .devcontainer/configure.sh --port-offset 10000
```

The offset produces host ports 18000, 19099, 19200, 19300, 15173, and 11990. Requiring that
one explicit choice prevents a setup command from guessing whether ports are
free and then racing Docker for them.

`configure.sh` validates but never overwrites an existing `.env`. To change an
identity, port offset, or egress network, stop that checkout's container,
remove the ignored file, and run the command again with the new choice.

Opening that checkout creates `pancake-tree1`, even though its branch is
`failure-sweep`. Startup refuses a mismatched linked-worktree directory instead
of attaching an ambiguous container name. Names start with a letter, contain
only lowercase letters and digits, and are at most 12 characters.

These names are host-global Docker names. Two independent pancake clones may
run together only when their worktree designators differ; startup refuses a
duplicate container name rather than guessing which checkout the user meant.

The ignored file also records `PANCAKE_GIT_COMMON_DIR`, derived from:

```sh
git rev-parse --path-format=absolute --git-common-dir
```

All worktrees belonging to one primary checkout use the same value. Linked
worktrees keep their administrative Git state there, and their `.git` files can
contain its absolute host path. Compose mounts the directory at that identical
path inside every container so Git works from either side. This explicit mount
is necessary with the current Dev Containers CLI: its automatic common-dir
mount is not applied to custom Compose workspace mounts.

The same ignored file owns that worktree's host ports. The primary checkout
uses 8000, 9099, 9200, 9300, 5173, and 1990. `configure.sh --port-offset` gives every
concurrently running worktree a different set. The generated `tree1` file
contains:

```dotenv
PANCAKE_ROOMS_WEB_HOST_PORT=18000
PANCAKE_ROOMS_CAPTP_HOST_PORT=19099
PANCAKE_ROOMS_RELAY_HOST_PORT=19200
PANCAKE_ROOMS_TRACE_HOST_PORT=19300
PANCAKE_OCAPNVIZ_HOST_PORT=15173
PANCAKE_DOCS_HOST_PORT=11990
```

The file uses one plain `KEY=value` assignment per line. Exported host variables take
precedence over Compose `.env` files, so startup refuses an inherited
`PANCAKE_*` or `EGRESS_NET` value that differs from this checkout's file.

## What runs when

| Phase | What runs |
| --- | --- |
| Before creation | `initialize.sh` creates the shared host agent-state paths and missing primary-checkout configuration, validates Git identity and ports, and prepares the managed Docker networks |
| Image build | `Dockerfile`, `install-*.sh`, then `verify-toolchains.sh` |
| First open | `post-create.sh` fixes persistent-volume ownership and verifies the environment |
| Development | You run `zig build check` and focused build steps |

## Toolchains

Versions and canonical paths live in [`pins.sh`](pins.sh). Download hashes live
in [`checksums.sh`](checksums.sh).

| Group | Tools | Installer |
| --- | --- | --- |
| Zig | Zig and ZLS at matching versions | `install-zig.sh`, `install-zls.sh` |
| Conformance | Python, Racket, and Goblins | `install-python.sh`, `install-racket-goblins.sh` |
| Bindings | Rust, Deno, Node, npm, and Bun | `install-rust.sh`, `install-js-toolchains.sh` |
| Browsers | Playwright's Chromium and the libraries it needs | `install-playwright.sh` |
| Agents | Serena, Claude Code, the Cursor agent CLI, opencode, and Codex | their `install-*.sh` scripts |
| Debugging | gdb, lldb, strace, valgrind, perf, hyperfine | `Dockerfile` |
| Tor | the `tor` daemon the `onion` netlayer's live checks talk to | `Dockerfile` |

The image also puts the repository's own CapTP CLI on PATH: `pancake` links to
the repo-root shim, which builds `zig-out/bin/pancake` on first use, so the
[CLI](../docs/cli.md) is callable from any directory in the container.

Cursor's agent CLI answers to both of the names upstream installs, `agent` and
`cursor-agent`. Upstream unpacks it into the user's home directory; here it is
part of the image, under `/usr/local/share/cursor-agent`, so the pinned build
comes with the container. Its own `agent update` still writes into
`~/.local/bin`, which sits after `/usr/local/bin` on the path, so the pinned
build keeps answering and `update-pins.sh` stays the way to move it. There is
no browser in the container, so sign in with `NO_OPEN_BROWSER=1 agent login`
and open the printed URL on the host; `agent status` says who you are.

No Tor is running when the container opens, and that is deliberate: pancake
reaches an onion service through a daemon whoever deployed it started, so the
library never starts, supervises, or configures one. The image installs the
binary and stops there. A check that needs a live daemon starts its own with its
own configuration and shuts it down again; the in-tree onion checks talk to a
fake daemon instead and need no Tor at all.

To update a tool, use [`update-pins.sh`](update-pins.sh) rather than editing
by hand:

```sh
.devcontainer/update-pins.sh               # report pins vs upstream + submodule drift
.devcontainer/update-pins.sh bump <dep>    # rewrite pins.sh and checksums.sh
.devcontainer/update-pins.sh bump --safe   # bump everything outside the build graph
```

It fetches versions and hashes from each tool's own release channel, stages
the edits, and validates them before either file lands. Every bump ends with
a container rebuild; the report names the build check that proves anything
deeper (a new Zig means `zig build check`, a new Racket or Goblins means
`zig build check-external`). Path changes are still hand edits: keep the
`Dockerfile` environment and `devcontainer.json` `containerEnv` aligned with
`pins.sh`, which `check-env-sync.sh` enforces.

Host-side startup also uses the `DEVCONTAINER_CLI_VERSION` pin. An installed
CLI is used only when its version matches; otherwise `npx` runs the pinned
release.

## Persistent paths

| Variable | During image build | In an open container |
| --- | --- | --- |
| `CARGO_HOME` | `/usr/local/cargo` | `/home/vscode/.cargo` volume |
| `RUSTUP_HOME` | `/usr/local/rustup` | unchanged |
| `PLAYWRIGHT_BROWSERS_PATH` | `/usr/local/share/ms-playwright` | unchanged |
| `PLTUSERHOME` | `/opt/pancake-racket-userhome` | unchanged |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/zig` | same volume |
| `CLAUDE_CONFIG_DIR` | `/home/vscode/.claude` | same host bind mount |
| `CURSOR_CONFIG_DIR`, `CURSOR_DATA_DIR` | `/home/vscode/.cursor` | settings host bind; Linux tokens use `~/.config/cursor` |

Rustup seeds the image under `/usr/local/cargo`; open containers persist
downloaded crates in the user volume. `post-create.sh` also makes the ZLS cache
writable.

The last two rows are what make an agent CLI's settings survive a rebuild.
Both tools choose their state directory from the environment, and both are
pointed at the directories [`devcontainer.json`](devcontainer.json) binds from
the host. The Cursor agent CLI on Linux still writes login tokens under
`~/.config/cursor`, so that path is a separate host bind.
[Host configuration](host-configuration.md) covers the mounts themselves.

Playwright's default download directory is `~/.cache/ms-playwright`, which is
neither a volume nor a bind mount here, so a browser landing there would have to
be reinstalled by hand every time the container is rebuilt.
`PLAYWRIGHT_BROWSERS_PATH` moves it to a shared system directory that the image
build fills once. Root installs the browsers and every user reads them, so the
browser proofs (`zig build rooms-web-page` and its siblings) run in a fresh
container with no setup step.

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml). `perf` may
still depend on host kernel policy. Racket's package tool has no version flag;
use `racket --version`, not `raco --version`.

## Host and network setup

Two detailed guides cover the parts that vary by machine:

- [Docker networking](networking.md): the rooms network, the private egress
  network, and how the rooms peer reaches the deployed app.
- [Host configuration](host-configuration.md): Git, SSH, shared agent and
  authentication state, keyrings, and commit signing.

### Ports the container forwards

`docker-compose.yml` publishes six ports on every host interface: the rooms
web page (8000), the rooms directory's CapTP listener (9099), the reference
relay (9200), the protocol-visualizer trace feed (9300), the ocapnviz Vite
dev server (5173), and the documentation preview (1990). Services always use
those canonical numbers inside the container. Their host ports come from
`.env`, so the primary checkout's web page is `http://localhost:8000`, while
the example worktree above uses `http://localhost:18000`. The ocapnviz page
and the docs preview can be opened as localhost or as the machine's own
hostname on that published port.

They are declared rather than left to the editor noticing a listener, because a
guessed forward goes away again when it stops noticing, and
[`apps/rooms/developing.md`](../apps/rooms/developing.md) uses canonical
container ports. A host-side client uses the corresponding `*_HOST_PORT` value;
for the example above, the live trace is `ws://127.0.0.1:19300/`.

If a host port is already taken, the container will not start. Change that
worktree's offset by removing its ignored `.env` and rerunning `configure.sh`;
the editor never silently remaps it.

## Files

Each script declares where it runs and refuses the wrong side: host-side
scripts call `pancake_require_host`, container-side ones
`pancake_require_devcontainer` (`lib.sh` owns the detection). The two
exceptions are noted in their own headers: `install-zig.sh` also runs on CI
runners (including macOS), and `check-env-sync.sh` is pure file checks.
`post-create.sh` runs shellcheck over this whole family, so a lint finding
fails container open and the CI push checks.

| File | Role | Runs |
| --- | --- | --- |
| `pins.sh`, `checksums.sh` | Versions, paths, and download hashes | sourced |
| `update-pins.sh` | Reports and bumps the pins against upstream | container |
| `lib.sh` | Shared installer functions and context guards | sourced |
| `launcher-lib.sh` | Shared mechanics of the tmux launchers: option grammar, lifecycle delegation, pane commands, attach | sourced |
| `check-env-sync.sh` | Checks pins, mounts, names, and host lifecycle contracts | anywhere |
| `test-host-invariants.sh` | Tests checkout configuration, identity, networks, and Git-owned lookup | anywhere |
| `Dockerfile` | Builds the image | image build |
| `devcontainer.json` | Editor settings and volumes | editor / CLI |
| `.env.example` | Annotated primary-checkout form generated by `configure.sh` | host |
| `configure.sh` | Creates the ignored checkout identity, paths, ports, and egress name | host |
| `docker-compose.yml` | Worktree-specific container and image names, networks, host ports, and ptrace | host compose |
| `initialize.sh` | Bootstraps and validates checkout configuration, then prepares managed networks | host |
| `enter.sh` | Starts or reuses a worktree container and attaches its default or a named tmux session | host |
| `enter-grid.sh` | Starts or reuses every column worktree's container and attaches one tmux grid, rows per column set by each worktree's `panes.sh` | host |
| `pane-rc.sh` | Initializes one grid pane's shell, then runs that pane's function from the worktree's ignored `panes.sh` | container |
| `up.sh` | Starts or rebuilds the container from a host shell | host |
| `post-create.sh` | Verifies and prepares an open container | container |
| `verify-toolchains.sh` | Checks installed versions | image build + container |
| `verify-ptrace.sh` | Checks ptrace access | container |
| `install-zig.sh` | Installs pinned Zig | image build, container, CI runners |
| other `install-*.sh` | Installs one toolchain group | image build + container |

Cursor users can enable Serena from [`.cursor/mcp.json`](../.cursor/mcp.json).
The [Serena rule](../.agents/rules/serena-mcp.md) covers project use.
