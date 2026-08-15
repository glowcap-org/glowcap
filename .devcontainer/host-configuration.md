# Host configuration in the devcontainer

VS Code and Cursor automatically reuse two parts of the host:

- Git identity and HTTPS credentials from the host Git configuration.
- SSH credentials through the forwarded `SSH_AUTH_SOCK`.

Use the forwarded SSH agent. Do not mount private key files into the
container.

The repository keeps configuration that the editor does not forward in named
Docker volumes:

| Tool | Container path | Purpose |
| --- | --- | --- |
| Claude Code | `~/.claude` | Login, skills, and memory |
| GitHub CLI | `~/.config/gh` | `gh` authentication |
| opencode | `~/.local/share/opencode` | Login |
| opencode | `~/.config/opencode` | Providers and default model |
| Codex | `~/.codex` | Login, config, and sessions |
| Agent resources | `~/.config/agents` | User-level resources for `.agents/` |

The volumes persist across rebuilds and are scoped to one worktree identity.
They do not expose the host's credential files or another worktree's agent
sessions to code in a checkout. Log in once from that container when a tool
first needs access.

The image creates every target before an empty volume is first mounted, and
`post-create.sh` aligns its ownership with the runtime `vscode` UID. The source
check rejects host-home mounts in the committed configuration, so credential
sharing cannot return as an unnoticed convenience edit.

## Common login problems

Run `gh auth login` and each agent tool's login command inside the container.
The `gh` binary and agent CLIs come from the image; their resulting state stays
in the named volumes above.

GPG signing is not forwarded. Install `gnupg2` and forward the GPG agent socket
if you need signed commits. Personal shell dotfiles belong in the editor's
`dotfiles.repository` setting, not this repository.
