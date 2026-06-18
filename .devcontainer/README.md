# pancake devcontainer

Ready-to-build environment for Cursor / VS Code: Zig, conformance tooling,
dogfood runtimes, and debug utilities. **`zig build check`** is the project
gate; everything here only prepares the host.

## Lifecycle

| Phase           | What runs                                                               |
| --------------- | ----------------------------------------------------------------------- |
| **Image build** | `Dockerfile` → `install-*.sh` → `verify-toolchains.sh`                  |
| **First open**  | `post-create.sh` — cache ownership, config sync, ptrace, toolchain pins |
| **You**         | `zig build check`                                                       |

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
| Agents      | `uv`, Serena (`serena` on PATH)              | `install-uv.sh`, `install-serena.sh`          |
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

Ptrace requires `runArgs` in `devcontainer.json`. `perf` may still depend on
host kernel policy. `raco` has no `--version` flag — use `racket --version`.

## Layout

| File                                           | Role                               |
| ---------------------------------------------- | ---------------------------------- |
| [`pins.sh`](pins.sh)                           | Version pins and canonical paths   |
| [`checksums.sh`](checksums.sh)                 | Per-arch SHA-256 for downloads     |
| [`lib.sh`](lib.sh)                             | Shared init and validation         |
| [`check-env-sync.sh`](check-env-sync.sh)       | Dockerfile / json vs pins          |
| [`Dockerfile`](Dockerfile)                     | Image build                        |
| [`devcontainer.json`](devcontainer.json)       | Editor, volumes, ptrace            |
| [`post-create.sh`](post-create.sh)             | Caches + verification after create |
| [`verify-toolchains.sh`](verify-toolchains.sh) | Installed versions vs pins         |
| [`verify-ptrace.sh`](verify-ptrace.sh)         | ptrace under `runArgs`             |
| `install-*.sh`                                 | One toolchain group per script     |

Cursor agents using Serena: enable **serena** in MCP settings; config is
[`.cursor/mcp.json`](../.cursor/mcp.json) (stdio — Cursor starts the server).
See [`.agents/rules/serena-mcp.md`](../.agents/rules/serena-mcp.md).
