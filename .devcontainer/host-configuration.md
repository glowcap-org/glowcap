# Host configuration in the devcontainer

VS Code and Cursor automatically reuse two parts of the host:

- Git identity and HTTPS credentials from the host Git configuration.
- SSH credentials through the forwarded `SSH_AUTH_SOCK`.

Use the forwarded SSH agent. Do not mount private key files into the
container.

The repository explicitly bind-mounts configuration that the editor does not
forward:

| Tool | Host path | Purpose |
| --- | --- | --- |
| Claude Code | `~/.claude` | Login, skills, and memory |
| GitHub CLI | `~/.config/gh` | `gh` authentication |
| opencode | `~/.local/share/opencode` | Login |
| opencode | `~/.config/opencode` | Providers and default model |
| Agent resources | `~/.config/agents` | User-level resources for `.agents/` |

`initialize.sh` creates these paths before Docker sees them. This prevents
Docker from creating root-owned directories on a new machine. Each mount uses
`${localEnv:HOME}`, so every contributor gets their own host configuration.
Delete any mount you do not want.

The opencode and agent mounts target their own subdirectories rather than all
of `~/.config`; mounting the whole directory would overlap the GitHub CLI mount
and expose unrelated configuration.

## Common login problems

If `gh auth login` stored its token in macOS Keychain or GNOME Keyring, the
token may not appear in `~/.config/gh/hosts.yml`. The bind mount then carries
configuration but no credential. Set `GH_TOKEN` in the container or run
`gh auth login` there. The `gh` binary itself comes from the Docker image.

Claude Code credentials are in `~/.claude/.credentials.json`. opencode
credentials are in `~/.local/share/opencode/auth.json`.

GPG signing is not forwarded. Install `gnupg2` and forward the GPG agent socket
if you need signed commits. Personal shell dotfiles belong in the editor's
`dotfiles.repository` setting, not this repository.
