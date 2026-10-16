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
are observed, and selecting a conversation does not change what you receive.
The CLI operates your session.

## Start

Extract the requested room, nickname, locator, and workspace before running
commands. In "Join garden as Alice using https://rooms.example.org/locator",
`garden` is the room, `Alice` is the nickname, and the URL is the directory.
"Read all room messages and DMs" means all events in the joined conversations,
not permission to join every room. Ask only for choices that are missing.

Choose the CLI on the machine running this agent, in this order:

1. Use the operator's explicit executable, otherwise `command -v glowcap`.
2. If absent from PATH, check `$HOME/.local/bin/glowcap`.
3. For a skill supplied from `<prefix>/share/glowcap/skills/rooms-peer/`, use
   `<prefix>/bin/glowcap`. For `<checkout>/.agents/skills/rooms-peer/`, use
   `<checkout>/glowcap`, which builds the complete product only if absent and
   runs on the host. Once prepared, listening and replying need no devcontainer
   or compiler, so do not enter the container to run the peer.
4. If none exists, stop and request a complete Linux or macOS product
   installation or its executable path. Do not search home directories,
   deployment state, MCP configuration, ADRs, or build caches for another
   executable.

Use the selected executable for every command, and replace `glowcap` in the
examples with its absolute path when it is not on PATH. Do not invoke private
`rooms-*` binaries or override the product selection with `GLOWCAP_BIN`. An
installed product needs no compiler, checkout, Python, or Docker. Keep its
`bin`, `libexec`, `lib`, and `share` together. Check once:

```sh
glowcap apps rooms session --help
```

Then start with the requested rooms, with no filesystem search or discovery
tour. The command creates or restores the workspace:

```sh
glowcap apps rooms session start \
  --dir "$HOME/.rooms/alice" --nick Alice \
  --locator https://rooms.example.org/locator \
  --room garden --room workshop
```

Rules for `start`:

- Never silently join `general`.
- The URL above is a placeholder, not a service to contact. Use the
  deployment's agent-accessible HTTPS `/locator` endpoint, or its published
  localhost URL on the Docker host. Docker-internal service names are not host
  addresses.
- A successful HTTP fetch must also return a locator reachable from this host.
  iroh discovery is the ordinary deployed route.
- A browser login is not shared with the CLI, and an access-gateway sign-in
  page is not a locator. Ask for an operator-approved accessible URL or
  `ocapn://` locator, and never extract browser cookies or change access
  controls to get around it.
- Reuse the same `--dir` on every command. For presence that must survive
  temporary-directory cleanup, choose a persistent private directory outside
  the installation.
- Keep the path short, because the workspace's `control.sock` must fit the
  host's Unix socket path limit.

`start` is idempotent for a running session. It joins the requested rooms and
reports success after their memberships exist.

- URL bootstrap fails before a new workspace or process is created.
- A later room-join failure leaves the session available for `status`,
  correction, or `stop`, so read its error.
- Restart with `start --dir <same-dir>` to restore the existing workspace.

After success, start the consumer below at once. Report presence only after the
requested memberships exist and a consumer is active.

## When a command fails

- Keep stdout JSON, stderr diagnostics, and the real exit status. Do not pipe
  commands through `head` or `tail`, merge the streams, or chain unrelated
  probes.
- Use tool output waits of at most 30 seconds and retain the running handle, so
  a silent command never blocks interaction indefinitely. Give finite
  diagnostic commands a tool deadline of 60 seconds. Quiet `tick` timeouts are
  not failures.

On a failed start or join:

1. Read the error's `class`, `message`, and `retry`.
2. Run `status --dir <same-dir>` once if a session may exist.
3. If `status` cannot answer, read only the last 40 lines of
   `<dir>/control.log`, keeping private content private.
4. Report the blocker and the concrete missing input or configuration. Retry
   only after that changes. An uncertain send requires inbox inspection, never
   blind replay.

A presence task is not a source-debugging task: run no recursive repository
searches, dependency scans, compiler installation, or identity deletion. If the
product diagnostics cannot explain the failure, ask for separate debugging
work.

## Listen and respond

Choose by harness:

1. If its command tool returns a running process handle and lets the model
   consume output while it runs, use `listen`.
2. If it returns output only when a command exits, check whether the harness
   can hold a detached process (a tmux pane, a service manager, `nohup`). If it
   can, arm `listen` there. A tick-only loop starves whenever the model is
   between turns or busy, and messages then wait unanswered.
3. Only when nothing can hold the process, fall back to
   `glowcap apps rooms session tick --dir <dir> --wait 30` once per tool call.

Never put a never-ending listener into a blocking-only tool, and never start a
second listener while the first is alive.

```sh
glowcap apps rooms session listen --dir "$HOME/.rooms/alice"
```

Run `listen` once as a long-running command. Keep its process handle and
consume new output through the harness's wait mechanism, with waits of at most
30 seconds. When the process runs detached, redirect its stdout to a log file
beside the workspace (never inside it, because the product owns the workspace),
read the new lines at every wake, and check the listener is still alive before
replying.

- The first JSON line reports the current inbox, even if empty. Later lines
  contain newly delivered events, and quiet periods produce no output.
- Reply and dismiss through separate commands while the same listener stays
  active.
- `remaining` counts all unacknowledged events, including ones already
  delivered.
- Use `tick --dir <dir> --wait 0` to reread a pending page. If `more` is true,
  pass `--after-id <last-event-id>` for its successor. The continuous listener
  drains these pages automatically without acknowledging them.

Read every row in `pending`:

- `id` names the journal entry.
- `event.target` names the conversation with `kind` (`room` or `direct`) and
  `id`.
- `event.notice.kind` identifies lines, presence, and other domain events. Line
  notices carry `from`, `text`, and `marker` with the line `id` and `change`.
- `files` describes attachments.
- An unavailable journal row has `unavailable: true`.

No mention filter runs. Answer a DM in its own conversation and keep private
content out of room replies.

```sh
# Route automatically to the exact room or DM that supplied this event.
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" \
  --id 12 --text 'Yes, I can help with that.'
# Read without speaking. Multiple --id flags acknowledge a reviewed batch.
glowcap apps rooms session dismiss --dir "$HOME/.rooms/alice" --id 13 --id 14
```

Reply naturally where a reply helps. Dismiss your own echoes and events that
need no response. Reading alone never acknowledges an event. Prefer human DMs
and questions, while still reading every room. A reply uses the shared
application's send completion before acknowledging the incoming event. After
an interrupted or uncertain send, inspect `status` and the inbox before
retrying, and never send the same text twice blindly.

- Write no shell or Python polling loop, and filter no events by nickname,
  presence, or apparent importance. The product owns delivery, and you decide
  what needs a response after reading it.
- Do not suppress stderr or truncate message bodies.
- Delivery does not acknowledge events. If the listener exits, inspect its
  error and restart it on the same workspace to replay all still-unacknowledged
  events.

The peer process can collect messages without the model, but a background
process alone cannot wake a completed model turn. Use the harness's live command
wait and output notifications, or read each `tick` batch before calling it
again.

- Never combine multiple waits into a minutes-long shell command.
- A quiet timeout is not a stopping condition.
- Never final-answer "standing by" and abandon the consumer.
- After an interrupted tool wait, resume the existing listener handle if it is
  still running, and never start a second one.

## Use the workspace

```sh
# Join another room while keeping all existing memberships and DMs.
glowcap apps rooms session join --dir "$HOME/.rooms/alice" --room design
# Discover rooms, registered people, memberships, subjects, and connection issues.
glowcap apps rooms session status --dir "$HOME/.rooms/alice"
# Start a public message or private conversation.
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --room garden --text 'Hello everyone.'
glowcap apps rooms session reply --dir "$HOME/.rooms/alice" --dm Bob --text 'Hello Bob.'
# Leave one room; the other rooms and DMs keep receiving.
glowcap apps rooms session leave --dir "$HOME/.rooms/alice" --room garden
# Stop this peer and retain its workspace and unanswered inbox for restart.
glowcap apps rooms session stop --dir "$HOME/.rooms/alice"
```

Room names can repeat across directories. When a name is ambiguous, pass the
`conversation` ID from `status` with `--conversation`. To join another
directory, supply `join --locator <URL> --nick <nick> --room <name>`.
Transport availability follows the session's configured providers. For
editing, subjects, standing, invitations, and other shared application commands,
read [application commands](references/commands.md).

## Recovery and limits

The private inbox is bounded. The Rooms operating guide,
`apps/rooms/operating.md` in the glowcap source, holds the limits.

- A full inbox or failed write retires this observer and reports `inbox.gap`.
  The session, commands, and other views stay live, and reviewed events remain
  available to `tick` and `dismiss`.
- After correcting the cause, use `resume --dir <dir> --accept-gap` to observe
  new events again. That accepts an explicit gap and recovers no message missed
  while observation was stopped.
- A stopped process cannot receive new live messages.
- An unclean shutdown reports a gap on restart, because queued events may not
  have reached disk. Inspect it before accepting and resuming.

Browser DMs:

- A host-initiated browser DM requires a reachable browser route. Browsers can
  choose **Through the room relay**, and an HTTP bootstrap derives its relay
  URL. Pass `start --relay-url <url>` when it cannot be derived.
- A default WebRTC-only browser is reached when the session starts with
  `start --dial-transports webrtc`. The dial signals through the room that
  introduced the browser, and `--ice-servers` names its STUN or TURN servers.
  Without that family such a browser is not reachable.
- Relay settings persist. To replace a previously saved inaccessible relay,
  stop the session and start the same workspace with the operator's
  `--relay-url`.
- File events expose descriptions, and this command front does not transfer
  file bytes. The full application remains accessible through an attached
  browser.

Use [rooms-team](../rooms-team/SKILL.md) when explicitly operating a durable
team. CapTP work outside Rooms is a separate task, and this skill needs neither
the repository's development tools nor other skills.
