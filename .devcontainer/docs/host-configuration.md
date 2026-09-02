# Host configuration in the devcontainer

VS Code and Cursor automatically reuse two parts of the host:

- Git identity and HTTPS credentials from the host Git configuration.
- SSH credentials through the forwarded `SSH_AUTH_SOCK`.

Use the forwarded SSH agent. Do not mount private key files into the
container.

Agent tools authenticate and keep user-level harness state for the host user
rather than a single checkout. The devcontainer binds their scoped host
directories into every worktree:

| Tool | Host path | Purpose |
| --- | --- | --- |
| Claude Code | `~/.claude` | Login, account, skills, memory, and sessions |
| Cursor agent CLI | `~/.cursor` | Settings, session history, and Darwin login tokens |
| Cursor agent CLI | `~/.config/cursor` | Login tokens on Linux |
| GitHub CLI | `~/.config/gh` | `gh` authentication and configuration |
| opencode | `~/.local/share/opencode` | Login and user data |
| opencode | `~/.config/opencode` | Providers and default model |
| Codex | `~/.codex` | Login, configuration, skills, and sessions |
| Agent resources | `~/.config/agents` | User-level resources for `.agents/` |
| Serena | `~/.serena` | User-level configuration |

Build caches use the same bind pattern so they are findable on either side of
the container: host `~/.cache/glowcap` is container `/home/vscode/.cache/glowcap`.
`tool/` is shared downloads, `cargo/` is `CARGO_HOME`, and
`work/<worktree>/` holds that container's Zig objects (`zig-local`) and
extracted packages (`zig-pkg`). A `LAYOUT` file sits at the root of that
directory. The [README](../README.md#persistent-paths) is the inventory.

`initialize.sh` creates every host path before Docker starts. A login, user
setting, or cache fill made on the host or in any glowcap worktree is therefore
available in every other worktree (caches: the shared `tool/` and `cargo/`
trees; each worktree still has its own `work/<name>/`) and survives container
replacement. A checkout can read and update these stores, so open only trusted
code in these containers.

The mounts target only the directories above. Mounting all of `~/.config`
would expose unrelated host configuration and overlap the narrower mounts.
`post-create.sh` checks access without changing ownership of host files.
Serena's per-clone memories remain under the workspace's `.serena/` directory,
which the workspace bind already carries.

A bind mount only shares a login if the tool writes it inside the directory
being bound, and two of these tools choose that directory from the
environment. `devcontainer.json` therefore sets `CLAUDE_CONFIG_DIR` and the
Cursor agent's `CURSOR_CONFIG_DIR` and `CURSOR_DATA_DIR` to the container-side
mount targets. Claude Code needs this: left alone it keeps its credentials in
`~/.claude` but its account and onboarding state in `~/.claude.json` beside it,
and that loose file cannot be bind-mounted, so it lived in the container's
writable layer and every rebuild opened on the login screen. Pointing the
variable at the directory brings the file inside it. The Cursor agent CLI has a
second split on Linux: settings go under `CURSOR_CONFIG_DIR`, while access and
refresh tokens go to `~/.config/cursor/auth.json`, so that directory is a
separate host bind. `test/env-sync.sh` holds each variable against its mount,
and holds the Linux token directory in the same inventory, because that file
does not follow `CURSOR_CONFIG_DIR`.

The first time a container opens after this, `initialize.sh` copies a host
`~/.claude.json` into `~/.claude/` if the shared copy is not there yet, so an
existing host login carries over. Afterwards the worktrees share that copy and
a host Claude Code keeps its own. A Darwin host keeps Cursor tokens at
`~/.cursor/auth.json`, and the Linux container reads `~/.config/cursor` instead,
so `initialize.sh` copies that file the same way when the Linux store is empty.

## Common login problems

If `gh auth status` works on the host but not in the container, the host may
keep its token in a desktop keyring instead of `~/.config/gh/hosts.yml`. Run
`gh auth login` once inside any glowcap container or provide `GH_TOKEN`; the
file-backed login is then shared by every worktree.

Claude Code credentials live in `~/.claude/.credentials.json`, opencode uses
`~/.local/share/opencode/auth.json`, Codex uses `~/.codex/auth.json`, and the
Cursor agent CLI on Linux keeps tokens in `~/.config/cursor/auth.json` (or takes
`CURSOR_API_KEY` from the environment). Their host binds include each file. The
`gh` binary and agent CLIs come from the image, and the [README](../README.md)
covers signing in to Cursor from a container with no browser.

GPG signing is not forwarded. Install `gnupg2` and forward the GPG agent socket
if you need signed commits. Personal shell dotfiles belong in the editor's
`dotfiles.repository` setting, not this repository.
