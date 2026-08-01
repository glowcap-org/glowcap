# pancake devcontainer

This is the supported ready-to-build environment for VS Code and Cursor. It
installs Zig, conformance tools, binding runtimes, and debugging utilities.
The project check remains `zig build check`.

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
| Conformance | Racket and Goblins | `install-racket-goblins.sh` |
| Bindings | Rust, Deno, Node, npm, and Bun | `install-rust.sh`, `install-js-toolchains.sh` |
| Agents | uv, Serena, Claude Code, and opencode | their `install-*.sh` scripts |
| Debugging | gdb, lldb, strace, valgrind, perf, hyperfine | `Dockerfile` |

To update a tool:

1. Change its version in `pins.sh` and its hash in `checksums.sh`.
2. Keep the `Dockerfile` environment and `devcontainer.json` `containerEnv`
   aligned with `pins.sh`; `check-env-sync.sh` enforces this.
3. Rebuild the container and rerun `post-create.sh`.

## Persistent paths

| Variable | During image build | In an open container |
| --- | --- | --- |
| `CARGO_HOME` | `/usr/local/cargo` | `/home/vscode/.cargo` volume |
| `RUSTUP_HOME` | `/usr/local/rustup` | unchanged |
| `PLTUSERHOME` | `/opt/pancake-racket-userhome` | unchanged |
| `ZIG_GLOBAL_CACHE_DIR` | `/home/vscode/.cache/zig` | same volume |

Rustup seeds the image under `/usr/local/cargo`; open containers persist
downloaded crates in the user volume. `post-create.sh` also makes the ZLS cache
writable.

Ptrace is enabled in [`docker-compose.yml`](docker-compose.yml). `perf` may
still depend on host kernel policy. Racket's package tool has no version flag;
use `racket --version`, not `raco --version`.

## Host and network setup

Two detailed guides cover the parts that vary by machine:

- [Docker networking](networking.md): the rooms network, the private egress
  network, and how the rooms peer reaches the deployed app.
- [Host configuration](host-configuration.md): Git, SSH, tool logins, bind
  mounts, keyrings, and commit signing.

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
