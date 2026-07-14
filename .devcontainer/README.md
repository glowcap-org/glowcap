# pancake devcontainer

Ready-to-build environment for Cursor / VS Code: Zig, conformance tooling,
dogfood runtimes, and debug utilities. **`zig build check`** is the project
gate; everything here only prepares the host.

## Lifecycle

| Phase                 | What runs                                                               |
| --------------------- | ----------------------------------------------------------------------- |
| **Host (pre-create)** | `initialize.sh` — bind-mount source dirs, create shared `rooms-net`     |
| **Image build**       | `Dockerfile` → `install-*.sh` → `verify-toolchains.sh`                  |
| **First open**        | `post-create.sh` — cache ownership, config sync, ptrace, toolchain pins |
| **You**               | `zig build check`                                                       |

```sh
bash .devcontainer/post-create.sh
zig build check
```

## Toolchains (pins in [`pins.sh`](pins.sh))

| Group       | Tools                                        | Install script                                |
| ----------- | -------------------------------------------- | --------------------------------------------- |
| Zig         | `zig`, `zls` (versions must match)           | `install-zig.sh`, `install-zls.sh`            |
| Conformance | Racket, Goblins                              | `install-racket-goblins.sh`                   |
| Dogfood     | Rust, Deno, Node, npm, Bun                   | `install-rust.sh`, `install-js-toolchains.sh` |
| Agents      | `uv`, Serena, Claude Code (`claude` on PATH), opencode (`opencode` on PATH) | `install-uv.sh`, `install-serena.sh`, `install-claude-code.sh`, `install-opencode.sh` |
| Debug       | gdb, lldb, strace, valgrind, perf, hyperfine | apt in `Dockerfile`                           |

Checksums for downloaded tarballs: [`checksums.sh`](checksums.sh).

## Maintain

1. Edit versions in [`pins.sh`](pins.sh); update [`checksums.sh`](checksums.sh)
   when a tarball changes.
2. Keep `Dockerfile` `ENV` and `devcontainer.json` `containerEnv` aligned with
   `pins.sh` — [`check-env-sync.sh`](check-env-sync.sh) enforces this.
3. Rebuild the image, then `bash .devcontainer/post-create.sh`.

## Paths

| Variable               | Image build (`Dockerfile`)     | Container open (`devcontainer.json`) |
| ---------------------- | ------------------------------ | ------------------------------------ |
| `CARGO_HOME`           | `/usr/local/cargo`             | `/home/vscode/.cargo` (volume)       |
| `RUSTUP_HOME`          | `/usr/local/rustup`            | same                                 |
| `PLTUSERHOME`          | `/opt/pancake-racket-userhome` | same (image dir, not a volume)       |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/zig`      | same (volume)                        |

`CARGO_HOME` differs on purpose: rustup seeds the image at build time; the open
container persists crates in a volume.

`post-create.sh` also ensures `${CACHE_ROOT}/zls` is writable (ZLS).

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml) (`cap_add` /
`security_opt`). `perf` may still depend on host kernel policy. `raco` has no
`--version` flag, use `racket --version`.

## Docker networks

The devcontainer attaches to two networks at container-create time:

- **`rooms-net`** — the fabric it shares with the rooms app
  ([`examples/apps/rooms/deno/deploy`](../examples/apps/rooms/deno/deploy/)). It
  has a fixed name and is committed in both compose files, so a rooms-bot in the
  devcontainer reaches the deployed room's internal CapTP by Docker DNS.
  `initializeCommand` runs `docker network create rooms-net` for you.
- **`egress-net`** — the container's one side network, named per host in the
  gitignored `.devcontainer/.env`. Here it is the LLM backend the agents reach.

```sh
cp .devcontainer/.env.example .devcontainer/.env
# edit .env: EGRESS_NET=llm-backend-net   (the real name stays out of tracked sources)
docker network create llm-backend-net   # once, if it does not exist
```

Then **Rebuild and Reopen** the container. Compose reads `.devcontainer/.env`
when creating the service (`docker-compose.yml` → `networks.egress-net`). `.env`
is gitignored; `.env.example` has an empty value on purpose so no network name
is committed. The rooms app sets its *own* `EGRESS_NET` (`cloudflare-tunnel-net`)
in its own `.env` — the two stacks share only `rooms-net`, not the side network.

CapTP for rooms-bot bootstraps from `http://pancake-rooms:8000/locator` over
`rooms-net` (Docker DNS; service alias `rooms` also works), then dials the
returned `ocapn://<nodeid>.iroh` URI over iroh Discovery. The browser UI stays
on `:8000` through the tunnel — CapTP itself is not that HTTP port.

## Sharing host configuration

The editor already shares the two configs people reach for most, so the
container mounts nothing for them:

- **git identity and HTTPS credentials.** VS Code and Cursor copy your host
  `~/.gitconfig` into the container on attach and reuse your host credential
  helper, so commits carry your identity with no setup.
- **SSH keys.** The host SSH agent is forwarded automatically (`SSH_AUTH_SOCK`
  is set in the container). Bind-mounting `~/.ssh` directly is the less-safe
  path most guides warn against; rely on the forwarded agent instead.

What the editor does not share is bind-mounted from the host in
[`devcontainer.json`](devcontainer.json), so the login survives a rebuild:

| Tool        | Bind mount                                                       | Why it is not automatic      |
| ----------- | --------------------------------------------------------------- | ---------------------------- |
| Claude Code | `~/.claude` → `/home/vscode/.claude`                             | skills, memory, login        |
| GitHub CLI  | `~/.config/gh` → `/home/vscode/.config/gh`                       | `gh`'s own auth store        |
| opencode    | `~/.local/share/opencode` → `/home/vscode/.local/share/opencode` | login (`auth.json`)          |
| opencode    | `~/.config/opencode` → `/home/vscode/.config/opencode`           | config (providers, model)    |

Claude's login is the `.credentials.json` inside `~/.claude`, and opencode's is
the `auth.json` inside `~/.local/share/opencode`, so both survive a rebuild and
are shared with a host install of either tool. opencode's provider and default
model config lives in `~/.config/opencode`, bound for the same reason. Both
opencode binds are scoped to its own subdirs, not the whole `~/.config`, which
would nest under the `~/.config/gh` bind and drag in unrelated host config.

`initializeCommand` creates each host path first, so a fresh machine binds an
empty directory rather than the root-owned one Docker would otherwise make. Each
path resolves per-user through `${localEnv:HOME}`, so a teammate mounts their
own, and any line can be dropped.

Two caveats on the `gh` mount. If you ran `gh auth login` on a desktop that
keeps the token in a system keyring (GNOME Keyring, macOS Keychain), the token
is not in `~/.config/gh/hosts.yml`, so the mount carries no login; set
`GH_TOKEN` in the container or log in again inside it. And the `gh` binary
itself is installed by the `Dockerfile`, not shared from the host.

GPG signing is not forwarded: install `gnupg2` and forward the gpg-agent socket
yourself if you sign commits. Personal shell dotfiles belong in the editor's
`dotfiles.repository` setting, which clones them into every container without
touching this repo.

## Layout

| File                                           | Role                               |
| ---------------------------------------------- | ---------------------------------- |
| [`pins.sh`](pins.sh)                           | Version pins and canonical paths   |
| [`checksums.sh`](checksums.sh)                 | Per-arch SHA-256 for downloads     |
| [`lib.sh`](lib.sh)                             | Shared init and validation         |
| [`check-env-sync.sh`](check-env-sync.sh)       | Dockerfile / json vs pins          |
| [`Dockerfile`](Dockerfile)                     | Image build                        |
| [`devcontainer.json`](devcontainer.json)       | Editor, volumes, compose service   |
| [`docker-compose.yml`](docker-compose.yml)     | Compose service: networks + ptrace caps |
| [`.env.example`](.env.example)                 | `EGRESS_NET` (copy → `.env`)       |
| [`initialize.sh`](initialize.sh)               | Host pre-create: bind dirs + `rooms-net` |
| [`post-create.sh`](post-create.sh)             | Caches + verification after create |
| [`verify-toolchains.sh`](verify-toolchains.sh) | Installed versions vs pins         |
| [`verify-ptrace.sh`](verify-ptrace.sh)         | ptrace under compose `cap_add`     |
| `install-*.sh`                                 | One toolchain group per script     |

Cursor agents using Serena: enable **serena** in MCP settings; config is
[`.cursor/mcp.json`](../.cursor/mcp.json) (stdio, Cursor starts the server).
See [`.agents/rules/serena-mcp.md`](../.agents/rules/serena-mcp.md).
