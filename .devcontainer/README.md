# pancake devcontainer

This is the supported ready-to-build environment for VS Code and Cursor. It
installs Zig, conformance tools, binding runtimes, the Chromium the browser
proofs drive, and debugging utilities. The project check remains
`zig build check`.

Open the repository with **Dev Containers: Reopen in Container**, then run:

```sh
bash .devcontainer/post-create.sh
zig build check
```

## What runs when

| Phase | What runs |
| --- | --- |
| Before creation | `initialize.sh` creates host bind-mount directories and `rooms-net` |
| Image build | `Dockerfile`, `install-*.sh`, then `verify-toolchains.sh` |
| First open | `post-create.sh` fixes cache ownership and verifies the environment |
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
| Agents | Serena, Claude Code, and opencode | their `install-*.sh` scripts |
| Debugging | gdb, lldb, strace, valgrind, perf, hyperfine | `Dockerfile` |
| Tor | the `tor` daemon the `onion` netlayer's live checks talk to | `Dockerfile` |

No Tor is running when the container opens, and that is deliberate: pancake
reaches an onion service through a daemon whoever deployed it started, so the
library never starts, supervises, or configures one. The image installs the
binary and stops there. A check that needs a live daemon starts its own with its
own configuration and shuts it down again; the in-tree onion checks talk to a
fake daemon instead and need no Tor at all.

To update a tool:

1. Change its version in `pins.sh`, and its hash in `checksums.sh` if it is one
   of the direct downloads listed there. Tools installed through npm or uv are
   pinned by version alone.
2. Keep the `Dockerfile` environment and `devcontainer.json` `containerEnv`
   aligned with `pins.sh`; `check-env-sync.sh` enforces this.
3. Rebuild the container and rerun `post-create.sh`.

## Persistent paths

| Variable | During image build | In an open container |
| --- | --- | --- |
| `CARGO_HOME` | `/usr/local/cargo` | `/home/vscode/.cargo` volume |
| `RUSTUP_HOME` | `/usr/local/rustup` | unchanged |
| `PLAYWRIGHT_BROWSERS_PATH` | `/usr/local/share/ms-playwright` | unchanged |
| `PLTUSERHOME` | `/opt/pancake-racket-userhome` | unchanged |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/zig` | same volume |

Rustup seeds the image under `/usr/local/cargo`; open containers persist
downloaded crates in the user volume. `post-create.sh` also makes the ZLS cache
writable.

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
- [Host configuration](host-configuration.md): Git, SSH, tool logins, bind
  mounts, keyrings, and commit signing.

### Ports the container forwards

`devcontainer.json` declares the four ports the rooms workflow needs, so they
reach the host without anyone forwarding them by hand: the web page on 8000, the
CapTP server clients dial on 9099, the relay peer on 9200, and the live trace
ocapnviz reads on 9300.

They are declared rather than left to the editor noticing a listener, because a
guessed forward goes away again when it stops noticing, and
[`apps/rooms/developing.md`](../apps/rooms/developing.md) tells a reader to point
the viewer at `ws://127.0.0.1:9300/`. If you run the viewer on the host and the
server in here, that address is the whole interface between them.

A port the editor is not forwarding shows in the Ports view of the *container*
window, next to the terminal. There is nothing to forward from a host window,
which is the usual reason the panel looks empty.

## Files

| File | Role |
| --- | --- |
| `pins.sh`, `checksums.sh` | Versions, paths, and download hashes |
| `lib.sh` | Shared installer functions |
| `check-env-sync.sh` | Checks environment values against `pins.sh` |
| `Dockerfile` | Builds the image |
| `devcontainer.json` | Editor settings and volumes |
| `docker-compose.yml` | Networks and ptrace capability |
| `.env.example` | Template for the private `EGRESS_NET` name |
| `initialize.sh` | Prepares host directories and `rooms-net` |
| `post-create.sh` | Verifies and prepares an open container |
| `verify-toolchains.sh` | Checks installed versions |
| `verify-ptrace.sh` | Checks ptrace access |
| `install-*.sh` | Installs one toolchain group |

Cursor users can enable Serena from [`.cursor/mcp.json`](../.cursor/mcp.json).
The [Serena rule](../.agents/rules/serena-mcp.md) covers project use.
