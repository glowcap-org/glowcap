# Changelog

Every release lists what changed for people using glowcap, in the form
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) describes. The
release notes on each [GitHub release](https://github.com/glowcap-org/glowcap/releases)
open with that version's section, so a release needs its section here first.
glowcap is alpha software, and a minor or patch version can change APIs, ABIs,
and storage formats before 1.0.
Releases before 0.1.7 are in the
[earlier changelog](docs/history/CHANGELOG.md).

## [Unreleased]

### Added

- Every Rooms session activity event now carries `mentions`, which says whether the line names you or the whole room. The session decides it once from the line's Markdown, so every reader agrees.
- A program can attach to a running Rooms session over CapTP with a session link, using the `rooms_services::session::attached` Rust library. It reads activity after a saved position, posts lines that stay editable and withdrawable, shows typing, and moves file bytes. With the session's management link it also issues, lists, pauses, resumes, and revokes access.
- `glowcap apps rooms session access` gives someone access to your running session from a terminal. `issue` prints a link for an observer, collaborator, or administrator. `list` shows each access with its id and state, the same accesses the session page lists. `pause`, `resume`, `revoke`, and `forget` change one by that id, and `forget` refuses an access that still works. The session saves an access's row before it issues the access, so an issue stopped partway is listed as unfinished and `issue --id` with the same label and rights finishes it, or `forget` drops it. The saved row also names the access's inventory entry, so a revoked access still lists once under its id.
- `glowcap apps rooms bot` keeps a coding agent (Claude, Codex, or Pi) present in Rooms through a session link. `serve` runs it and shows it typing while its agent works, `status` reports it, and during a turn the agent calls `say`, `send`, and `command` a fixed number of times at most, and `workspace`. `say --dm` and `send --dm` answer someone in the turn's conversation privately, opening a direct message with them or reusing the open one. `--allow` limits who it answers and whose lines reach the agent, and sender, conversation, and back-to-back limits bound how much anyone can start. A line that is exactly `/reset` starts a new agent conversation, and `--instructions` adds your own instructions to every reply. A bot answers only while its access is active, and a full bot belongs in a container or under its own user, as the [bot guide](docs/rooms/bot.md) says.
- A Rooms bot has a home, `home/` in the bot directory, that its agent keeps across every conversation and restart, and `/reset`, letting a conversation go, and a new link leave it alone. The agent saves one small file per memory in `home/memory/` and sees their list, newest first, before every reply. `bot status` reports the home and how many memories it holds, and a deployment keeps the home in its own volume, `glowcap-rooms-bot-home`, so starting the bot fresh keeps it.
- A Rooms deployment can run a bot as Compose services in your override. The override example has the commented block and [Run a bot](apps/rooms/web/deploy/README.md#run-a-bot) has the steps. `up` also names the selected image `glowcap-rooms:selected`, so an image you build can start from it. `glowcap apps rooms bot ready` exits 0 only while a `serve` holds the bot directory, its access is active, and its session answers, for a container health check, and each `bot serve` setting is also the variable `GLOWCAP_ROOMS_BOT_<NAME>`. A bot directory written by another build of the bot may be refused as unreadable, and Compose then restarts the bot again and again. To start it fresh with the same link, run `docker rm -f glowcap-rooms-bot` and `docker volume rm glowcap-rooms-bot-state`, then `up`.

### Changed

- Dependencies move to their current releases. The development container takes Rust 1.100, Node 26.13.1, Bun 1.4.5, Playwright 1.65.1, uv 0.13.9, and ruff 0.17.6, so rebuild it. The Rooms server image takes the current Distroless base, the relay's TLS build takes Mbed TLS 4.3.0, and the iroh transport takes iroh 1.5. The CLI's REPL takes libvaxis fixes for key parsing, wrapping, and terminal restore.

### Fixed

- Reloading a Rooms page on a private room while its server restarts keeps you in that room. Before, a reload that found the server down sent you to the join card.
- `glowcap ocapn listen --once` and `--publish` exit with the protocol-abort or timeout code when their one partner's session fails, rather than 0. In MCP and the REPL, `info` reports that session's cause as `listener_stopped` rather than "served its one partner".
- A `rooms session` send, direct message, room join, or directory registration that saves while the session's supervisor is also saving now plans its change again and keeps it. Before, it reported a failure, even after the command had committed, and named a recovery that could never succeed. Saving a session access that keeps losing to other writes now says so and asks for another try, instead of reporting a peer failure.
- `glowcap apps rooms session start` refuses a `--nick` that differs from the workspace's nickname and names the one it has, instead of reporting success and keeping the old one. A nickname belongs to its workspace, so a new one needs a new `--dir`.
- Two people who go to the same new Rooms room at the same moment both enter it. Before, the one who lost the race to open it could be told that the room is no longer listed, because a room its opener had not yet entered was missing from a lookup by name.
- `deployment logs` accepts the services an override adds, not only `directory` and `session`.
- A direct message opened through a Rooms session link with collaborator rights, from the session page or a bot, now receives the other member's replies. Before, the session refused to set up its receiving side without administrator rights. Opening a direct message with a member who already has an open one, from the session page, a bot, or the terminal, reuses that one and gives the extra route back, even after the directory registers again. When the other member opens one again, it lands in the open conversation, which keeps its history, or else arrives as a new one beside the closed one. The session refuses any change that would open a second, and a workspace that already holds two keeps both working.
- Match release image metadata to the Docker or OCI manifest format when publishing the multi-platform image.
- Reuse the authenticated release lookup when validating installers on shared CI hosts.
- Use the browser's login on the Rooms server's own page and explain when Settings cannot read a server reply.
- Stop a Racket call on the driver loop from waiting forever when its answer arrives just as it starts waiting.
- Stop a Racket server on the driver loop from spinning a core while a session sits idle.
- Highlight a Rooms line that mentions you from the one reading the session uses. A mention inside IRC bold or colour from the IRC bridge now counts, and your own line, including one read back from an archive, never highlights.
- Report a refused `poll` from `Connection.runUntil` and `Connection.closeGracefully` as its own cause, such as `SystemResources`, instead of `ConnectionLost`. A Zig switch over `runUntil`'s errors needs arms for `SystemResources`, `InvalidWait`, and `Unexpected`.
- Report an accept the kernel refuses on a TCP or onion listener, such as for a full descriptor table, as `AcceptRefused` with the kernel's cause, as the driver loop's listeners already do. It was reported as `ConnectionLost`, which means the listener shut down. A refused readiness poll on the listener or in the WebRTC transport keeps its own cause too.
- Report a refused readiness poll on an in-process listener as `AcceptRefused`, as TCP and onion listeners do, rather than `ConnectionLost`, which means the listener closed.
- Keep a listener accepting when one queued connection fails before it is taken, such as with a network error Linux reports from `accept`, as `accept(2)` directs. A TCP or onion listener reported `AcceptRefused`, and a driver loop's listener stopped. `AcceptRefusal` no longer holds `NetworkDown`.
- Stop a `listen` started from the MCP server or the REPL when its listener fails, such as when the kernel refuses an accept for a full descriptor table, and name that cause in `info`. It kept reporting a live listener while spinning a core.
- Keep `glowcap listen` serving when one partner fails its handshake or its session, as a `listen` from the MCP server or the REPL already does. It exited with an internal error.
- Classify a closed `driver.Server`'s `ServerClosed` as `closed` rather than `io`, so a caller choosing by `OperationFailure.classify` reads a stopped listener as stopped.

### Security

- The Python binding's `rendezvous` extra requires websockets 17.4 or later, the first release that limits how many frames one relay message may span.

## [0.1.8] - 2026-11-20

This release includes the [changes prepared for 0.1.7](docs/history/0.1.7/changes/CHANGELOG.md).
Read the [migration notes](docs/history/0.1.7/migration/CHANGELOG.md) before
upgrading a client, provider, or Rooms deployment with saved state.

### Changed

- Open glowcap rooms and ocapnviz from the website's Apps menu and project footer.

### Fixed

- Verify the installed glowcap executable before publishing the host archives.

## [0.1.7] - 2026-11-19

Read the [migration notes](docs/history/0.1.7/migration/CHANGELOG.md) before
upgrading a client, provider, or Rooms deployment with saved state. Browse
the [features and fixes](docs/history/0.1.7/changes/CHANGELOG.md), including
the WebRTC reopen fix, and the [earlier changes](docs/history/0.1.7/CHANGELOG.md)
in this release.

[Unreleased]: https://github.com/glowcap-org/glowcap/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/glowcap-org/glowcap/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/glowcap-org/glowcap/compare/v0.1.6...v0.1.7
