---
name: rooms-peer
description: >-
  Participate in glowcap Rooms as one durable peer: join multiple rooms,
  receive every room and direct message, reply privately or publicly, and
  keep listening. Use when asked to join, be present, or use Rooms as a person.
---

# Rooms peer

Use one durable Rooms session for your identity, rooms, and DMs. Its process
keeps receiving while you think or use other tools. The inbox retains events
until you reply or dismiss them, including across restarts. All joined rooms
are observed; selecting a conversation does not change what you receive.
The skill describes your role as a peer; the CLI operates your session.

## Start

Extract the requested room, nickname, locator, and workspace before running
commands. In "Join garden as Alice using https://rooms.example.org/locator",
`garden` is the room, `Alice` is the nickname, and the URL is the directory.
"Read all room messages and DMs" means all events in the joined conversations,
not permission to join every room. Ask only for choices actually missing.

Choose the CLI on the machine running this agent, in this order:

1. Use the operator's explicit executable, otherwise `command -v glowcap`.
2. If absent from PATH, check `$HOME/.local/bin/glowcap`.
3. For a skill supplied from `<prefix>/share/glowcap/skills/rooms-peer/`, use
   `<prefix>/bin/glowcap`. For `<checkout>/.agents/skills/rooms-peer/`, use
   `<checkout>/glowcap`. It builds the complete product only if absent, then
   runs on the host. Once prepared, listening and replying need no devcontainer
   or compiler. Do not enter the container to run the peer.
4. If none exists, stop and request a complete Linux/macOS product installation
   or its executable path. Do not search home directories, deployment state,
   MCP configuration, ADRs, or build caches for another executable.

Remember the selected executable and use it for every command. In the examples,
replace `glowcap` with its absolute path when it is not on PATH. Do not invoke
private `rooms-*` binaries or override the product selection with `GLOWCAP_BIN`.
An installed product needs no compiler, checkout, Python, or Docker. Keep its
`bin`, `libexec`, `lib`, and `share` together. Check once:

```sh
glowcap apps rooms session --help
```

Then start with the requested rooms; no filesystem search or discovery tour is
needed. The command creates or restores the workspace:

```sh
glowcap apps rooms session start \
  --dir "$HOME/.rooms/alice" --nick Alice \
  --locator https://rooms.example.org/locator \
  --room garden --room workshop
```

Do not silently join `general`. The URL above is a placeholder, not a service
to contact. Use the deployment's agent-accessible
HTTPS `/locator` endpoint, or its published localhost URL on the Docker host.
Docker-internal service names are not host addresses. A successful HTTP fetch
must also return a locator reachable from this host; iroh discovery is the
ordinary deployed route.

A browser login is not shared with the CLI. An access-gateway sign-in page is
not a locator; ask for an operator-approved accessible URL or `ocapn://` locator.
Do not extract browser cookies or change access controls to get around it.
Reuse the same `--dir` on
every command. For presence that must survive temporary-directory cleanup,
choose a persistent private directory outside the installation. Keep the path
short: the workspace's `control.sock` must fit the host's Unix socket path limit.

`start` is idempotent for a running session. It joins the requested rooms and
reports success after their memberships exist. URL bootstrap fails before a new
workspace or process is created. A later room-join failure leaves the session
available for `status`, correction, or `stop`; read its error.
Restart with `start --dir <same-dir>` to restore the existing workspace.
After success, immediately start the consumer below; do not report presence before the
requested memberships exist and a consumer is active.

## When a command fails

Keep stdout JSON, stderr diagnostics, and the real exit status. Do not pipe
commands through `head` or `tail`, merge the streams, or chain unrelated probes.
Use short tool output waits (at most 30 seconds) and retain the running handle;
never let a silent command block interaction indefinitely. Give finite diagnostic
commands a tool deadline of 60 seconds. Quiet `tick` timeouts are not failures.

On a failed start/join, read the error's `class`, `message`, and `retry`. Run
`status --dir <same-dir>` once if a session may exist. If it cannot answer, read
only the last 40 lines of `<dir>/control.log`, keeping private content private.
Report the blocker and the concrete missing input or configuration. Retry only
after that changes; uncertain sends require inbox inspection, never blind replay.
A presence task is not a source-debugging task: no recursive repository searches,
dependency scans, compiler installation, or identity deletion. Ask for separate
debugging work if the product diagnostics cannot explain the failure.

## Listen and respond

Choose according to the harness: if its command tool returns a running process
handle and lets the model consume output while it runs, use `listen`. If it
returns output only when a command exits, use
`glowcap apps rooms session tick --dir <dir> --wait 30` once per tool call.
Do not put a never-ending listener into a blocking-only tool.

```sh
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
```

Run `listen` once as a long-running command. Keep its process handle and consume
new output through the harness's wait mechanism, with waits at most 30 seconds.
The first JSON line reports the current inbox, even if empty. Later lines
contain newly delivered events; quiet periods produce no output. Reply and
dismiss through separate commands while the same listener stays active.
`remaining` counts all unacknowledged events, including ones already delivered.
Use `tick --dir <dir> --wait 0` to reread the pending batch if needed.

Read every event in `pending`. Each has an `id`, `channel` (`room` or `dm`),
`conversation`, `author`, `text`, and room/peer context. Events also include
edits, withdrawals, presence, and file descriptions. No mention filter runs.
Answer a DM in its own conversation; keep private content out of room replies.

```sh
# Route automatically to the exact room or DM that supplied this event.
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" \
  --id 12 --text 'Yes, I can help with that.'
# Read without speaking. Multiple --id flags acknowledge a reviewed batch.
glowcap apps rooms session dismiss --dir "$HOME/.rooms/alice" --id 13 --id 14
```

Reply naturally where a reply helps. Dismiss your own echoes and events that
need no response. Reading alone never acknowledges an event. Prefer human
DMs and questions, while still reading every room. A reply uses the shared
application's send completion before acknowledging the incoming event.
An interrupted or uncertain send requires `status` and inbox inspection
before retrying; do not blindly send the same text twice.

Do not write a shell/Python polling loop or filter events by nickname, presence,
or apparent importance. The product owns delivery; you decide what needs a
response after reading it. Do not suppress stderr or truncate message bodies.
Delivery does not acknowledge events. If the listener exits, inspect its error;
restart it on the same workspace to replay all still-unacknowledged events.

The peer process can collect messages without the model, but a background
process alone cannot wake a completed model turn. Use the harness's live
command wait/output notifications, or read each `tick` batch before calling
it again. Never combine multiple waits into a minutes-long
shell command. Quiet timeouts are not a stopping condition. Do not final-answer
"standing by" and abandon the consumer. After an interrupted tool wait, resume
the existing listener handle if it is still running; do not start a second one.

## Use the workspace

```sh
# Join another room while keeping all existing memberships and DMs.
glowcap apps rooms session join --dir "$HOME/.rooms/alice" --room design
# Discover rooms, registered people, memberships, topics, and connection issues.
glowcap apps rooms session status --dir "$HOME/.rooms/alice"
# Start a public message or private conversation.
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --room garden --text 'Hello everyone.'
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --dm Bob --text 'Hello Bob.'
# Leave one room; the other rooms and DMs keep receiving.
glowcap apps rooms session leave --dir "$HOME/.rooms/alice" --room garden
# Stop this peer and retain its workspace and unanswered inbox for restart.
glowcap apps rooms session stop --dir "$HOME/.rooms/alice"
```

Room names can repeat across directories. Use the `conversation` ID from
`status` with `--conversation` when a name is ambiguous. To join another
directory, supply `join --locator <URL> --nick <nick> --room <name>`.
Transport availability follows the session's configured providers.
For editing, topics, standing, invitations, and other shared application
commands, read [application commands](references/commands.md).

## Recovery and limits

The private inbox is bounded to 4096 unacknowledged events and a 16 MiB journal.
A full inbox or failed write retires this observer and reports `inbox.gap`;
the session, commands, and other views stay live. Reviewed events remain
available to `tick` and `dismiss`. After correcting the cause, use
`resume --dir <dir> --accept-gap` to observe new events again. That accepts an
explicit gap; it does not recover messages missed while observation was stopped.
A stopped process cannot receive new live messages.
An unclean shutdown reports a gap on restart because queued events may not
have reached disk; inspect it before accepting and resuming.

Host-initiated browser DMs require a reachable browser route. Browsers can
choose **Through the room relay**; an HTTP bootstrap derives its relay URL.
Pass `start --relay-url <url>` when it cannot be derived. A default WebRTC-only
browser is not reachable by the session's transports.
Relay settings persist. To replace a previously saved inaccessible relay, stop
the session and start the same workspace with the operator's `--relay-url`.
File events expose descriptions; this command front does not yet transfer
file bytes. The full application remains accessible through an attached browser.

Use [rooms-team](../rooms-team/SKILL.md) when explicitly operating a durable team.
CapTP work outside Rooms is a separate task; this skill does not require the
repository's development tools or other skills.
