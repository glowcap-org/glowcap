---
type: static
description: How to run a Rooms server, what its flags allow, where it keeps data, and how history, moderation and the Operations page work.
audience: human
sources:
  - resource: /apps/rooms/rust/application/src/
  - resource: /apps/rooms/rust/services/src/
  - resource: /apps/rooms/web/deploy/
---

# Operating Rooms

This guide is for whoever runs a Rooms server: the flags that grant
capabilities, where state lives, the services that survive a restart,
moderation, and the Operations page. The [Rooms overview](README.md) runs the
application, [Developing Rooms](developing.md) covers changing it, and the
[deployment guide](web/deploy/README.md) runs everything here with Docker
Compose.

Participants running outside Docker use the [glowcap product package](host.md).
Give them the host-reachable `/locator` URL, not an internal Compose hostname.

## The server and its state

`rooms-server` is the directory members register with, and it hosts the rooms
they enter. It records names and tells watchers who is registered, relays
introductions and WebRTC signaling, seats members and delivers room traffic,
hosts files within the room and server budgets, and keeps history when you ask.
The [work admission guide](../../docs/rooms/admission.md) covers temporary
refusals and operation rates. Directory diagnostics show the effective policy
and class counters.

```sh
zig build rooms-server -- --state=.local/rooms --history
```

Without `--state`, the server gets a fresh identity on every start and forgets
everything when it stops. With `--state`, the directory holds:

- `rooms.json`: the server document, including the identity seed and every
  issued room link
- `operations.json`: listener options, and IRC networks and channels
- one file per capability swiss number
- `onion-key`, when the transport is onion
- `history/`, the kept lines of listed rooms, with `--history`

One process at a time can hold a state directory. To back it up, stop the
server, copy the whole directory, and restore it as one unit.

On startup the process prints `ROOMS-SERVER-LISTENING` followed by the
address members dial. For a loopback TCP room that is just the port.
Otherwise it is the complete locator.

Options use `--name=value` and can also come from `GLOWCAP_ROOMS_*`
environment variables. Unknown or repeated options are refused. Choose the
transport with these:

- The default is iroh with discovery.
- `--reachability=direct` is for a self-contained run on one host.
- `--transport=tcp --port=0` is cleartext loopback. Add `--bind` and
  `--announce-host` to serve a LAN.

`SIGINT` and `SIGTERM` stop admitting members, close the listeners, finish the
writes already admitted, and release the state directory.

`rooms.json` is version one, and the server refuses any other shape without
rewriting the file. The same rule covers the session and archive files, history
rows, and the browser's workspace and archive. To reset a development setup,
stop the peers, remove their state directories, and clear the Rooms origin's
browser site data.

## Operator capabilities

Each flag below creates one capability. The server keeps its swiss number in
the state directory and prints its complete URI as a `ROOMS-*` line at
startup. A capability whose flag was not given does not exist.

`rooms-server --capabilities=<state-directory>` prints the saved capabilities
again, given the server's advertised locator in `GLOWCAP_ROOMS_LOCATOR`. The
timeline capability also needs its own locator in
`GLOWCAP_ROOMS_TRACE_LOCATOR`. Without it, that one line says so and the rest
still print. `glowcap apps rooms deployment up` supplies the room locator
itself.

| Flag | Environment | Prints | Grants |
| --- | --- | --- | --- |
| `--diagnostics` | `GLOWCAP_ROOMS_DIAGNOSTICS=1` | `ROOMS-DIAGNOSTICS` | Inspect: the names the directory holds and its recent failures |
| `--admin-listeners` | `GLOWCAP_ROOMS_ADMIN_LISTENERS=1` | `ROOMS-ADMIN-LISTENERS` | List the server's listeners, bring one up on a transport it can realize, take one down |
| `--operator` | `GLOWCAP_ROOMS_OPERATOR=1` | `ROOMS-OPERATOR` | Recover and revoke every local room's manager and moderator capabilities, including the lists and bulk removal on the Directory page |
| `--peering` | `GLOWCAP_ROOMS_PEERING=1` | `ROOMS-PEERING` | List a durable room from another directory |
| `--irc` | `GLOWCAP_ROOMS_IRC=1` | `ROOMS-IRC` | Open IRC networks and bridge channels as rooms |
| `--trace` | `GLOWCAP_ROOMS_TRACE=1` | `ROOMS-TRACE`, `ROOMS-TRACE-LISTENING` | The live timeline endpoint and the capability its sockets present |

Anyone who can read the state directory or the startup log holds these
capabilities. That is their only access control.

In the browser, each capability is a toggle under **Settings**, **Holdings**.

- Turning one on asks for its swiss number and takes the capability over the
  live directory session. If you opt in, the form remembers the number on that
  device, separately for each directory.
- While you hold any of them, an **Operations** control on the **Settings** title
  line opens the Operations page. Each page has its own address under `/ops`.
  Inspect and operator share the Directory page.
- Turning a toggle off drops the capability. So does a reconnect.

The web launcher forwards these flags to the server it starts, so
`zig build rooms-web -- --diagnostics` works. `zig build rooms-dev` passes all
of them.

## History

History is off by default. `--history` (or `GLOWCAP_ROOMS_HISTORY=1`) keeps
each listed room's recent lines and sends them to any member who asks. The page
asks when you enter a room whose log is empty, and shows the answer under a
divider naming the room as the keeper.

- Private rooms never record.
- A file line keeps its caption, never the file's bytes.
- Direct messages never reach the server. They go to the archive the reader
  chose, which is their browser by default.

**Limits.** One room keeps at most <!-- value rust/application/src/server/history.rs LINES_KEPT -->500<!-- /value --> lines. The whole server keeps at
most <!-- value rust/application/src/server/history.rs LINES_KEPT_TOTAL -->4,096<!-- /value --> lines across
<!-- value rust/application/src/server/history.rs ROOMS_KEPT -->256<!-- /value --> rooms. At either limit, the server drops the
entire history of the least recently active room before writing anything. On
startup it restores and validates storage before it opens the listener.

**Where history is stored.** Kept lines live in JSONL files, one per room,
under `history/` in the state directory. A server with no state directory keeps
them in memory. A history directory that cannot be used stops startup.

**File storage.** Startup is refused for a room file over
<!-- value rust/application/src/server/history.rs FILE_BYTES bytes -->64 MiB<!-- /value -->, a directory over
<!-- value rust/application/src/server/history.rs DISK_BYTES bytes -->512 MiB<!-- /value -->, an unexpected entry, or a corrupt complete row. A crash can leave an
unfinished final append, and startup repairs it. A crash can also lose an
append the operating system had not made durable, and the next start restores
the last complete state.

## The session service

A durable session owns one person's Rooms workspace: the directories and rooms
they are in, direct conversations, drafts, history and connection choices, and
the capabilities the session holds. Several browsers attach to it and see the
same thing. Closing every browser changes nothing.

```sh
glowcap apps rooms session serve --dir=.local/.state/rooms
```

When its workspace, listener and publications are ready, the process prints
`ROOMS-SESSION-LISTENING`. It writes the workspace use sturdyref to
`workspace.sturdyref` and the independent management sturdyref to
`control.sturdyref` in the state directory. `--readiness-file` moves the use
sturdyref's mirror. The Compose deployment uses a private tmpfs.

- The file has mode 0600. It is removed on an orderly stop and before every
  startup once this process has the session to itself. A refused second process
  cannot remove the running owner's files.
- `rooms-session --check-ready=<path>` reads it back as a health check.
- The workspace sturdyref authorizes use and the control sturdyref authorizes
  management. Protect both, and share narrower grants through the access
  editor.

In the browser, **Attach** (on the first screen, or under **Settings**, **Session**)
opens the workspace the session owns. It does not copy the browser's previous
session into it. Every attached browser is a view of the same session.

The access editor groups permissions into presets for reading, conversation
actions, workspace changes, and managing access. A held issuing control can
create narrower or equal-permission access, up to its own ceiling. Sharing
management creates a separately narrowed control, independent of workspace use
permissions. A held control can edit, pause, resume or revoke its scoped
grants, and those changes survive restart. The session checks the initiating
grant on every operation. A send of unknown outcome keeps its original receipt
and waits for review instead of resending.

A password entered in an IRC bridge form is kept in `bridge-secrets.json` in
the state directory, only while a room still needs it. It never goes into the
workspace or a snapshot sent to an attached view. The file is plain JSON
protected by the directory's permissions, since anyone who can read the
directory can already act as the session using the identity seed beside it.

A local browser workspace persists in IndexedDB. Sharing publishes its held use
or control authority on the tab's current Host. Live connections end when the
tab closes, and reopening restores saved authority.

### Local command access

`glowcap apps rooms session start --dir <directory>` starts the shared session
with local control. Underneath, `rooms-session --state=<directory>
--local-control` adds a Unix socket at `<directory>/control.sock`.

- The process restricts its state directory to its owner.
- Access to this socket means full administration of the session, including
  its private conversations.
- JSON commands never arrive on a network port.

The socket takes one newline-terminated JSON request per connection. `RequestBody` in
[`control.rs`](rust/services/src/session/control.rs) lists every verb. The
everyday ones are `status`, `tick`, `ack`, `command`, and `stop`.
`command` takes an operation `id`, a command `name`, and string `args`, and the
shared Rooms application validates and runs it. This view observes every joined
conversation, even while another one is selected.

**Reading events.**

- `tick` returns up to <!-- value rust/services/src/session/control/inbox.rs PAGE_ROWS -->64<!-- /value --> retained events and waits up to
  <!-- value rust/services/src/session/control.rs MAX_TICK_WAIT_SECS seconds -->30 seconds<!-- /value --> for new ones. Reading does not acknowledge them.
- `ack` takes numeric event `ids`.
- `listen` uses the returned change cursor to wait for new commits even when
  unread events remain, so it does not fetch the same batch again.
- Unacknowledged events and their IDs survive a restart.
- File events describe the file and carry no bytes.

**The inbox and gaps.** The inbox holds at most
<!-- value rust/services/src/session/control/inbox.rs MAX_ROWS -->4,096<!-- /value --> events within a
<!-- value rust/services/src/session/control/inbox.rs MAX_BYTES bytes -->16 MiB<!-- /value --> log, and a bounded worker writes it to disk outside the Rooms event loop.
Queue pressure, a full disk, or a failed write stops only this observer, and
`status` reports `inbox.gap`. To recover, fix the cause, dismiss the events you
have reviewed, then run
`glowcap apps rooms session resume --dir <directory> --accept-gap`. That
accepts the missed events and does not recover them.

## The archive service

The archive is a member's own history, behind one sturdyref:

```sh
zig build rooms-archive -- --state=.local/member-archive
```

The process prints `ROOMS-ARCHIVE-LISTENING` followed by the sturdyref.
Whoever holds that sturdyref can read and write the whole archive.

- It keeps at most <!-- value rust/application/src/archive.rs MAX_RECORDS -->5,000<!-- /value --> records and bounds its log, so it is not an
  unlimited backup.
- A second process on the same directory is refused, and a crashed process
  leaves no stale lock.
- A corrupt complete row stops startup. An unfinished final append is
  repaired.

In the browser, **Settings**, **Holdings**, **Use an archive peer…** takes the
sturdyref and sends new history there.

- If the peer cannot be reached, it shows as unavailable and writes are
  refused, never redirected to the browser's own store.
- **Use this browser** sends later reads and writes back to IndexedDB.
- Reads come from every archive the member holds at once, with each archive
  named at its own divider.
- A conversation's card can give another member a read-only view of what the
  archive kept. From an archive peer it can instead give a durable share that
  lasts until revoked.

All three services also accept `--transport=onion`. Put a running Tor
daemon's endpoints in `GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`. The
services keep `onion-key` in the state directory and never start Tor
themselves.

## The IRC gateway

`--irc` creates the gateway capability. The Operations page shows it as a
generic bridge gateway, with a form to open a connection (an IRC network), a
form to add a channel under a connection, and a list of the connections it
holds.

- A connection with no channels opens no socket.
- A channel appears beside the Rooms conversations as `network/#channel`, and
  IRC members appear as `irc/<nick>`.
- Removing a channel takes down only that channel. Closing a connection
  deletes the network and every channel under it.

One shared connection per network carries the channel feed. A member who wants
to speak on IRC opens their own connection from the IRC panel on their member
row.

- It uses their current nick, or an adapted one when the nick has characters
  IRC does not allow. They can log in to a registered account.
- Credentials travel only over TLS and are held only next to that connection.
  They never go into snapshots or the browser's saved state. A durable session
  keeps them to log in again after a restart, and a browser asks again after a
  reload.
- A refused login restores the member's previous identity.

Being in a bridged room means being in the channel. `/me` crosses as an
action in both directions, and a member's own messages echoed back by the
channel are hidden, so they never appear twice. The channel's topic is the
room's subject, and a member who joins later hears it too. A topic that
cannot be a subject, such as one longer than a subject allows, is shown as a
line, and the room then has no subject.

[IRC on Rooms](irc/README.md) covers the standalone bridge and IRC server, the
network policy a bot must follow, and the bounds.

## Moderation

Moderation uses capabilities instead of ranks.
- **Ignoring.** `/ignore` hides someone in your own window only. No server
  learns of it.
- **The manager.** Creating a room through managed creation returns a manager
  capability. Holding it lets you create, recover, and revoke the room's
  entry link and moderator, and nothing else.
- **The moderator.** The manager issues the moderator explicitly, from room
  details or with `/moderator`. Someone else can take it with
  `/moderator <sturdyref>`, and the page checks that it governs this exact
  room before keeping it.
- **Kicking.** `/kick`, or the confirmed action on the member card, asks a
  member to leave through the moderator. The member is told directly, and the
  room sees why they left. No ban is created, because a nickname is not an
  identity.

Revoking rotates the durable generation. Every old sturdyref and every
reference restored from one is refused at once, and the next issue creates an
unrelated one.

`--operator` is the recovery root for every local room, including private
ones. Its page lists the moderators, can give out an unissued moderator or
recover the current one, and can revoke room-link, manager, or moderator
generations after a second confirmation. It cannot enter a room or kick
anyone on its own authority. Peered rooms stay under their source directory,
and bridged IRC rooms get their moderator from the gateway.

## The Operations page

**Inspect** lists what the directory holds: rooms, occupants, registrations,
and durable links (whether one is active, never its swiss number), beside the
server's recent failures.

**The operator's inventories** add the capabilities the server owns, grouped
by kind, with one search across all of them.

- The directory does the matching, so counts cover everything it holds. A page is <!-- value rust/application/src/server/operations/operator.rs MAX_PAGE -->32<!-- /value --> rows whether the directory holds
  thirty rooms or three hundred thousand.
- Every word of a search must appear in a row, in any field and any order.
- While a search has matches, each inventory that can retire rows offers to
  retire all of them. It asks first, then works in batches, and the operator
  can stop between batches.

**The Listeners page** has one switch per transport the server lists, each
described in its provider's own words.

- A listener that is up shows its locator. One that is down shows a field for
  each setting it accepts when brought up.
- The listener serving this page is marked and cannot be switched off.

**The Peering page** lists a room this tab has joined on another directory in
this one. Each listing has one revocation, carried by its lease. Dropping the
capability without revoking leaves the listings in place until the directory
connection ends.

**The Visualizer page** names the endpoint this session publishes to, and
lets you override it.

## Watching the room live

`--trace` serves the live timeline endpoint on loopback at `--trace-port`
(default <!-- value rust/services/src/server/config.rs TRACE_PORT plain -->9300<!-- /value -->, or `0` for any free port). It prints `ROOMS-TRACE-LISTENING`
followed by its trace sturdyref. The locator advertises separate
`captp-websocket` and `trace-publish` endpoints.

- `/captp` opens a CapTP byte channel. Fetching the trace object still
  requires its swiss number.
- The `/` viewer and `/publish` telemetry routes additionally require
  `?cap=<swiss>`.
- `--trace-connect=<ws-url>` and `--trace-publish=<ws-url>` advertise exact
  routes through a deployment proxy, including its path prefixes.

For a deployed stack, follow the protocol feed directly:

```sh
glowcap apps rooms deployment trace
```

Add `--json` for complete records, or `--dir` to select another deployment.
The command starts a disposable viewer on the deployment network, so no trace
port needs to be published. It receives replay followed by new protocol events.
Ctrl-C closes and removes the viewer. Ordinary service logs remain available
through `deployment logs directory`.

For a local server, use `glowcap apps rooms trace --state=<directory>`.
`--url=http://127.0.0.1:<port>` selects its web address. `--print-link` prints
the complete trace capability without subscribing. Deployment startup prints
that same capability after `ROOMS-TRACE-LISTENING`.

To subscribe from another machine, pass the full capability to
`glowcap apps rooms trace '<trace-capability>'`. Its advertised WebSocket
endpoint must be reachable there. The contributor command
`zig build rooms-trace-tail -- '<trace-capability>'` reads the same feed.

To watch: start the [ocapnviz](../ocapnviz/) viewer
(`zig build ocapnviz-dev`), switch it to **Live**, and paste that sturdyref
into the Source field. Every session the room accepts, every message in
either direction, and every close then appears on the stage. **Record**
captures, and **Stop** hands the capture to Play.

Direct messages never pass through the room, so each member publishes its own
trace to the same endpoint.

- A browser tab uses the advertised CapTP channel to acquire the trace
  capability and the separately advertised producer route to publish. It publishes only while it holds the trace
  swiss number, taken through the **Live trace** toggle under **Holdings**.
- A member's trace records who it talked to, when, which verb, and how many
  bytes, never the bytes themselves. The room server publishes its own frames
  in full.
- A shared session publishes from the session process, and its attached tabs
  do not publish a second copy.
- An ephemeral trace port is carried in both advertised endpoints. A proxy
  deployment supplies its public endpoints explicitly.

## The web launcher

`rooms-web` serves the page, its `/relay` WebSocket, `/locator`, `/ice`, and
`/llms.txt`, and supervises the room server.

- It keeps one room identity across server crashes. A server that had been
  running comes straight back. One that exits as soon as it starts is
  restarted more slowly each time, up to half a minute apart, so the message
  it printed stays readable.
- By default it uses a private temporary state directory that lasts as long
  as the launcher. Set `GLOWCAP_ROOMS_STATE` when the identity, room links,
  and operator choices must survive.
- If a Rooms server already holds the room port, the launcher attaches to it
  instead of starting its own. The capabilities it prints are then that
  server's.

The relay's limits are environment variables, listed in the deployment guide:

- `GLOWCAP_RELAY_MAX_SESSIONS`, `GLOWCAP_RELAY_MAX_REGISTRATIONS`, and
  `GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY` limit WebSocket sessions and
  rendezvous registrations.
- `GLOWCAP_RELAY_MAX_IROH_SESSIONS` (<!-- value rust/services/src/web/relay.rs DEFAULT_IROH_SESSIONS -->16<!-- /value -->) and
  `GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` (twice the session limit) limit the
  iroh connections, each of which runs its own endpoint runtime.

Raise a limit only for the resource it names.

## Security posture

- The web launcher sets a hashed-script Content Security Policy,
  `frame-ancestors 'none'`, `nosniff`, `no-referrer`, and a permissions
  policy. The policy keeps `style-src 'unsafe-inline'` for React inline
  styles until those styles can be hashed.
- Link preview refuses private, loopback, link-local, and IPv4-mapped
  targets, and bounds redirects, connect time, and body size.
- Relay and preview upgrades check `Origin` against `Host`. A request with
  no `Origin` header is accepted so non-browser clients can connect.
- The IRC encoder refuses NUL, CR, and LF in every parameter and bounds line
  length.
- Published authority tokens are looked up by their SHA-256 digest, so the
  cost of a guess does not follow how many of its leading bytes match a real
  token.
- Identity and state files are created `0600` under `0700` directories.
- Each caller has a work allowance that is checked before anything runs.
- The browser UI has no `innerHTML`, no `dangerouslySetInnerHTML`, and no
  `eval`, and every external anchor carries `rel="noopener noreferrer"`.

## Known limitations

These are the limits of Rooms itself. The library's limits, including
transports and browser reachability, are in
[known limitations](../../docs/boundaries.md).

- **Rooms runs on Linux and macOS hosts and in Chromium-class browsers.** One
  Rust implementation runs every Rooms service and the browser application,
  and TypeScript draws the page.
  - Windows support, file-lock behavior on other filesystems, and public Tor
    circuit reachability are not established, and no throughput or latency
    figure is claimed.
  - The repository defines a workflow for [host product packages](host.md) on
    matching runners. A workflow definition does not show that a run passed or
    that an archive was published.
  - Local Linux evidence does not cover macOS, and a Linux devcontainer does
    not cross-build the Rust session for macOS.
  - The macOS packages are not Developer ID signed or notarized, so Gatekeeper
    acceptance of a downloaded artifact is untested.

- **A Rooms deployment runs on one host and backs up stopped volumes.**
  Everything durable lives in the directory and session state volumes, kept
  lines included. Back each up as one unit while the stack is stopped. A live
  snapshot of a running store is not built, and nothing places one directory's
  rooms across hosts.

- **A Rooms message consumer has a bounded unread queue.** `Room.messages`
  hands a line directly to a pending read and otherwise retains at most <!-- value rust/application/src/room/inbox/queue.rs MAX_MESSAGES -->256<!-- /value -->
  unread messages. A consumer that remains stalled past that bound receives a
  stream error and must subscribe again. Cancellation, overflow, replacement,
  and leave release every unread file capability. The browser client keeps a
  read pending during ordinary use.

- **Rooms sessions are capabilities, not accounts.** No ambient login or server
  account owns a durable session. The session sturdyref is the authority
  to attach, and each delegated part can be revoked independently. Nothing
  infers an identity from a login string.

- **A durable session does not make everything durable.** Every view attached
  to a session shares its network identity and workspace: directories,
  archive choice, capabilities, peering, history, live files, operator
  actions, listener and IRC administration, and visualizer publication.
  Browser `File` handles and object URLs stay on the device that made them.
  A browser tab keeps its workspace in IndexedDB, and a reload restores the
  saved grants and links. A reference tied to a connection still needs the
  peer that issued it to be reachable.

- **A durable session's bridge credentials are retained, not encrypted.** The
  password a member answers a bridge form with lives in the session peer's
  `bridge-secrets.json`, under the state directory's permissions, beside the
  identity seed that already grants the whole session. It never enters a
  managed workspace, snapshot, or export, and it is dropped once no room still names
  its scope. A browser's local workspace holds none across a reload, and a
  workspace adopted into a peer carries the bridge settings without the
  password. Both ask the member to answer the bridge once more (ADR-0141).
- **Attachments and shares outlast their connection only in part.**
  - A live transferred attachment remains available only while its room,
    direct line, and session are still open. A selected member archive may
    retain the same message's bytes separately and serve them after restart
    through its own scoped capability. The workspace stores neither copy nor an
    invented promise that an archive retained one.
  - Room-link invitations are saved with the workspace. A browser and a
    durable Rooms session both keep the sturdyref they were handed until the
    reader accepts or dismisses it.
  - Received archive-share rows are runtime-only. A live share dies with its
    session or one read. A durable offer's sturdyref is the Host publication.
    The reminder on the conversation card is not saved, so a restart forgets
    the reminder without revoking the share.

- **One-shot room invitations are live capabilities.** Rooms and IRC bridges
  limit how many exist and retire them when the room's live generation ends.
  If the answer to a claim is lost, its receipt survives, and every retry
  competes for the same single membership. Invitations do not survive a
  server restart as separately revocable sturdyrefs.

- **A session remembers only its recent changes for retries.** It keeps the
  identities of its last 64 completed changes. The browser never retries an
  ambiguous send, edit, withdrawal, operator change, listener change, or IRC
  change on its own. A change replayed by hand after it has left those 64 may
  happen twice. Private-room and durable-authority changes instead keep a
  pending result and a recovery key until they resolve.

- **Delivery receipts depend on what the room keeps.** A room's senders share
  one budget of <!-- value rust/application/src/room/inbox/queue.rs MAX_MESSAGES -->256<!-- /value --> messages and
  <!-- value rust/application/src/room/inbox/queue.rs MAX_MESSAGE_BYTES bytes -->2 MiB<!-- /value --> across pending text and unread messages.
  Receipts keep order and match each answer to its send, but they do not make
  a retry safe. An upload is reused without a second read only when its source
  cannot change, it was acknowledged, and the media cache took it. A streaming
  source or a full cache means an ordinary read.
  [ADR-0160](../../docs/decisions/adr/ADR-0160-rooms-retained-delivery.md)
  records the contract and its measured costs.

- **Keeping a room is separate from being in it.** Joining with `open` or
  `enter`, or holding a room's entrance, gives no right to keep the room.
  Creating a managed room returns a manager reference you can pass on. It
  controls the room's registered public name, its entry links, and its
  moderators.
  - The live room still disappears when empty. Its registration holds the
    name, and entering by that name brings the room back. An entry link is
    not the registration and grants no management.
  - If every copy of the manager is lost, the directory operator has to
    recover one. Sharing the manager shares management. It does not hand it
    over.
  - Revoking an entry link blocks later admission through every old copy but
    does not evict a membership that already subscribed.
  - The current manager can unregister the room. That retires its public
    entrance and moves it to private access while its room link, moderator,
    manager, and existing memberships remain. The public name is then
    available to another room, so registering this room again may meet a name
    collision.

- **Two tabs editing one local workspace do not merge.** Each tab writes the
  workspace to localStorage on its own. Import and clear tell the other tabs,
  but ordinary edits made at the same time are not merged. When several
  browsers or tabs must change the same workspace, attach them all to one
  durable session.

- **A subject's link is offered to copy, not opened.** A member can set a
  room subject that links an object by its sturdyref, and every reader sees
  the link. The browser and the terminal clients do not redeem it or draw the
  object, so taking part happens in whatever client that object comes with.
  The room never attenuates the link, so whoever sets it decides what holding
  it allows.

- **Directory discovery is a bounded live view.** A watch baseline carries
  at most <!-- value rust/application/src/directory.rs MAX_ROWS -->256<!-- /value --> current room publications. Watch clients receive an explicit
  truncation event and continue receiving later deltas. A one-shot list
  answers <!-- value rust/application/src/directory.rs MAX_ROWS -->256<!-- /value --> publications a page with a cursor for the page after it. The
  cursor is the position of the page's last row in listing order, so a room
  that closes between two pages moves no other row, and a room open for the
  whole walk is listed exactly once. A room that opens behind the cursor
  shows up on the next walk or in a watch.

- **The IRC adapters have IRC representation and delivery limits.** IRC is an
  application adapter, not a CapTP transport. There is no IRC server link and
  no CapTP-over-IRC netlayer. IRC carries neither edits nor capability-bearing
  file and room offers.
  - The bridge mirrors one channel into an ordinary Rooms directory and is
    read-only unless the operator selects two-way mode with TLS and SASL
    credentials. Two-way posts use the bridge's registered nick and a visible
    `<nick>` prefix. IRC supplies no acknowledgement for a channel message, so
    an ambiguous TCP failure may repeat or lose the last line even though the
    bounded queue survives an observed write failure.
  - The IRC server maps only existing IRC-addressable room names. It fixes a
    nickname for the connection because Rooms grants names per capability and
    no atomic rename exists across several memberships. Rooms names outside
    IRC's alphabet receive disclosed connection-local aliases.
  - Lines, subjects, and file capabilities that cannot fit IRC are reported
    rather than silently truncated or discarded. Foreign room publications
    without a member count, and Rooms room names IRC cannot address, are
    omitted from `LIST` with a notice instead of invented fields.
