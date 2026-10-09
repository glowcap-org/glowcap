# Operating Rooms

This guide is for whoever runs a Rooms server: the flags that grant it
capabilities, where its state lives, how history is kept, the three services
that survive a restart, moderation, and the Operations page. The
[Rooms overview](README.md) runs the application; [Developing Rooms](developing.md)
covers building and changing it; the [deployment guide](web/deploy/README.md)
runs everything here with Docker Compose.

Participants running outside Docker use the [glowcap product package](host.md).
Give them the host-reachable `/locator` URL, not an internal Compose hostname.

## The server and its state

`rooms-server` is the directory members register with, and it hosts the rooms
they enter. It:

- records names, and tells watchers who is registered and which rooms are
  listed;
- relays introductions and WebRTC signaling between members;
- opens rooms, seats members, and delivers lines, topics, presence, typing,
  and invitations;
- hosts files within the room and server budgets;
- keeps history when you ask it to.

```sh
zig build rooms-server -- --state=.local/rooms --history
```

Without `--state`, the server keeps nothing: it gets a fresh identity on every
start and forgets everything when it stops. With `--state`, the directory
holds:

- `rooms.json`: the server document, including the identity seed and every
  issued room link;
- `operations.json`: listener options, and IRC networks and channels;
- one file per capability swiss number;
- `onion-key`, when the transport is onion;
- `history/`, when history is kept in files.

Only one process can hold a state directory at a time. To back it up, stop
the server first, copy the whole directory, and restore it as one unit.

On startup the process prints `ROOMS-SERVER-LISTENING` followed by the
address members dial. For a loopback TCP room that is just the port;
otherwise it is the complete locator.

Options use `--name=value` and can also come from `GLOWCAP_ROOMS_*`
environment variables. Unknown or repeated options are refused. Choose the
transport with these:

- The default is iroh with discovery.
- `--reachability=direct` is for a self-contained run on one host.
- `--transport=tcp --port=0` is cleartext loopback. Add `--bind` and
  `--announce-host` to serve a LAN.

`SIGINT` and `SIGTERM` stop admitting new members, close the listeners,
finish the writes already admitted, and release the state directory.

There is no earlier released schema. `rooms.json` is version one, and the
server refuses any other shape without rewriting the file. The same rule
covers the session and archive files, history rows, and the browser's
workspace and archive. To reset a development setup, stop the peers, remove their state
directories, and clear the Rooms origin's browser site data.

## Operator capabilities

Each flag below creates one capability. The server keeps its swiss number in
the state directory and prints its complete URI as a `ROOMS-*` line at startup. A
capability whose flag was not given does not exist at all.
`rooms-server --capabilities=<state-directory>` prints the saved recipes when
`GLOWCAP_ROOMS_LOCATOR` supplies the server's advertised locator. A minted
timeline also needs its advertised locator in `GLOWCAP_ROOMS_TRACE_LOCATOR`.

| Flag | Environment | Prints | Grants |
| --- | --- | --- | --- |
| `--diagnostics` | `GLOWCAP_ROOMS_DIAGNOSTICS=1` | `ROOMS-DIAGNOSTICS` | Inspect: the names the directory holds and its trouble journal |
| `--admin-listeners` | `GLOWCAP_ROOMS_ADMIN_LISTENERS=1` | `ROOMS-ADMIN-LISTENERS` | List the server's listeners, bring one up on a transport it can realize, take one down |
| `--operator` | `GLOWCAP_ROOMS_OPERATOR=1` | `ROOMS-OPERATOR` | Recover and revoke every local room's manager and moderator capabilities; the inventories and bulk retirement on the directory pane |
| `--peering` | `GLOWCAP_ROOMS_PEERING=1` | `ROOMS-PEERING` | List a durable room from another directory |
| `--irc` | `GLOWCAP_ROOMS_IRC=1` | `ROOMS-IRC` | Open IRC networks and bridge channels as rooms |
| `--trace` | `GLOWCAP_ROOMS_TRACE=1` | `ROOMS-TRACE`, `ROOMS-TRACE-LISTENING` | The live timeline endpoint and the capability its sockets present |

Anyone who can read the state directory or the startup log holds these
capabilities. That is their only access control.

In the browser, each capability is a toggle under Settings, Holdings.

- Turning one on asks for its swiss number and takes the capability over the
  live directory session. The form can remember the number on that device, if
  you opt in, separately for each directory.
- While you hold any of them, an Operations control on the Settings title line
  opens the Operations page. Each pane has its own address under `/ops`.
  Inspect and operator share the directory pane, because they are two kinds of
  authority over the same subject.
- Turning a toggle off drops the capability, and so does a reconnect for the
  capabilities taken over that session.

The web launcher forwards these flags to the server it starts, so
`zig build rooms-web -- --diagnostics` works. `zig build rooms-dev` passes all
of them.

## History

History is off by default, and the operator decides whether to keep it.
`--history` (or `GLOWCAP_ROOMS_HISTORY=1`) keeps each listed room's recent
lines and sends them to any member who asks. The page asks when you enter a
room whose log is empty, and shows the answer under a divider naming the
room as the keeper.

- Private rooms never record.
- A file line keeps its caption, never the file's bytes.
- Direct messages never reach the server. They go to the archive the reader
  chose, which is their browser by default.

**Limits.** One room keeps at most 500 lines. The whole server keeps at most
4,096 lines across 256 rooms. When either limit is reached, the server drops
the entire history of the least recently active room. This policy is applied
before any storage backend sees a write, and on startup the server restores
and validates storage before it opens the listener.

**Where history is stored.** Set `--storage=` (or `GLOWCAP_ROOMS_STORAGE`):

- A `postgres://` URL uses PostgreSQL. Any other URL scheme is refused.
- A plain value names a directory of JSONL files, one per room.
- With no destination, history goes in the state directory if there is one,
  and otherwise in memory for the life of the process.

Naming a destination turns history on, unless `--history=false` says
otherwise. A destination that cannot be used stops startup.

**File storage.** Startup is refused for a room file over 64 MiB, a directory
over 512 MiB, an unexpected entry, or a corrupt complete row. An unfinished
final append is the only damage a crash can leave, and it is repaired. A
process or machine crash can still lose an append the operating system had
not yet made durable. The next start then restores the last complete state;
it never invents a write.

**PostgreSQL storage.**

- The server takes a session lock, so only one Rooms server owns a given
  history. Use separate databases for independent servers.
- URLs accept `sslmode=disable`, `prefer` (the default), or `require`. TLS
  checks the certificate and server name against the system's trusted roots.
- Connecting and each transaction have a 30-second deadline. A storage
  failure stops the server and reports why. An uncertain commit is never
  retried automatically.
- `zig build rooms-postgres-test` tests the installed server against the
  database named by `GLOWCAP_ROOMS_STORAGE_LIVE_URL`.
  `python3 apps/rooms/rust/product/tests/postgres_fixture.py` creates a
  throwaway database cluster for it.

## The session service

A durable session owns one person's whole Rooms workspace: the directories
and rooms they are in, direct conversations, drafts, the history and
connection choices, and the capabilities the session holds. Several browsers
attach to it and see the same thing; closing every browser changes nothing.

```sh
glowcap apps rooms session serve --dir=.local/.state/rooms
```

When its managed workspace, listener and publications are ready, the process
prints `ROOMS-SESSION-LISTENING`. It writes the workspace use sturdyref to
`workspace.sturdyref` and the independent management sturdyref to
`control.sturdyref` in the state directory. `--readiness-file` moves the use
publication mirror; the Compose deployment uses a private tmpfs.

- The file has mode 0600. It is removed on an orderly stop and before every
  restart.
- `rooms-session --check-ready=<path>` reads it back as a health check.
- The workspace reference authorizes use; the control reference authorizes
  management. Protect both, and share narrower grants through the access editor.

In the browser, Attach (on the first screen, or under Settings, Session) opens
the workspace the session owns. Attaching selects that workspace; it does not
copy the browser's previous session into it. Every attached browser is a view
of the same managed owner.

The access editor groups explicit permissions into presets for reading,
conversation actions, workspace changes and custody. A held issuing control
can create narrower or equal-permission access, subject to its own ceiling.
The issuer keeps the control it can pass on. Sharing management creates a
separately narrowed control, independent of workspace use permissions.

The session checks the exact initiating grant on every operation and returned
reader. A held control can edit, pause, resume or revoke its scoped grants;
those changes survive restart. Unknown sends retain their original receipt
and require review instead of a fresh resend.

A password entered in an IRC bridge form is kept in `bridge-secrets.json` in
the state directory, and only while a room still needs it. It never goes into
the managed workspace or into a snapshot sent to an attached view. The file is plain
JSON protected by the directory's own permissions, since anyone who can read
the directory can already act as the session using the identity seed stored
beside it.

A local browser workspace persists in IndexedDB. Sharing publishes its held
use or control authority on the tab's current Host. Live connections end when
the tab closes; reopening restores saved authority through the managed owner.

### Local command access

`glowcap apps rooms session start --dir <directory>` starts the shared session
with local control. Underneath, `rooms-session --state=<directory>
--local-control` adds a Unix socket at `<directory>/control.sock`.

- The process restricts its state directory to its owner.
- Access to this socket means full administration of the session, including
  its private conversations.
- It never accepts JSON commands on a network port.

The socket takes one newline-terminated JSON request per connection. The
verbs are `status`, `locate`, `tick`, `ack`, `command`, `adopt`, `resume`, and
`stop`. `command` takes an operation `id`, a command `name`, and string
`args`, and the shared Rooms application validates and runs it. This view
observes every joined conversation, even while another one is selected.

**Reading events.**

- `tick` returns up to 64 retained events and waits up to 30 seconds for new
  ones. Reading does not acknowledge them.
- `ack` takes numeric event `ids`.
- `listen` uses the returned change cursor to wait for new commits even when
  unread events remain, rather than fetching the same batch again and again.
- Unacknowledged events and their IDs survive a restart.
- File events are descriptions only; this interface does not transfer file
  bytes.

**The inbox and gaps.** The inbox holds at most 4096 events within a 16 MiB
journal, and a bounded worker writes it to disk outside the Rooms event loop.
Queue pressure, a full disk, or a failed write stops only this observer; the
session and its other views keep working. When that happens, `status` reports
`inbox.gap`. To recover, fix the cause, dismiss the events you have reviewed,
then run `glowcap apps rooms session resume --dir <directory> --accept-gap`.
That accepts the missed events. It does not recover them.

## The archive service

The archive is a member's own history, behind one sturdyref:

```sh
zig build rooms-archive -- --state=.local/member-archive
```

The process prints `ROOMS-ARCHIVE-LISTENING` followed by the sturdyref.
Whoever holds that sturdyref can read and write the whole archive.

- It keeps at most 5,000 records and bounds its journal. It is durable
  storage, not an unlimited backup.
- A second process on the same directory is refused immediately, and a
  crashed process leaves no stale lock.
- A corrupt complete row stops startup. An unfinished final append is
  repaired.

In the browser, Settings, Holdings, **Use an archive peer…** takes the
sturdyref and sends new history there.

- If the peer cannot be reached, it shows as unavailable and writes are
  refused. They never fall back to the browser's own store.
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
generic bridge gateway, without knowing anything about IRC. It has a form to
open a connection (an IRC network), a form to add a channel under a
connection, and a list of the connections it holds.

- A connection with no channels opens no socket.
- A channel appears beside the Rooms conversations as `network/#channel`, and
  IRC members appear as `irc/<nick>`.
- Removing a channel takes down only that channel. Closing a connection
  deletes the network and every channel under it.

One shared connection per network carries the channel feed. A member who
wants to speak on IRC opens their own connection from the IRC panel on their
member row.

- It uses their current nick, or an adapted one when the nick has characters
  IRC does not allow. They can optionally log in to a registered account.
- Those credentials travel only over TLS and are held only next to that
  connection. They never go into snapshots or the browser's saved state. A
  durable session keeps them so it can log in again after a restart; a
  browser asks again after a reload.
- A refused login restores the member's previous identity.

Being in a bridged room means being in the channel. `/me` crosses as an
action in both directions, IRC topic changes become the room's topic, and a
member's own messages echoed back by the channel are hidden, so they never
appear twice.

[IRC on Rooms](irc/README.md) covers the standalone bridge and front, the
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
  identity a ban could hold against.

Revoking rotates the durable generation. Every old sturdyref, and every
reference enlivened from one, is refused at once, and the next issue creates
an unrelated one.

`--operator` is the recovery root for every local room, including private
ones. Its pane lists the moderators, can give out an unissued moderator or
recover the current one, and can revoke room-link, manager, or moderator
generations after a second confirmation. It cannot enter a room or kick
anyone on its own authority. Peered rooms stay under their source directory,
and bridged IRC rooms get their moderator from the gateway.

## The Operations page

**Inspect** lists what the directory holds: rooms, occupants, registrations,
and durable links (whether one is active, never its swiss number). It shows
the server's own trouble journal beside the page's.

**The operator's inventories** add the capabilities the server owns, grouped
by kind, with one search that narrows all of them at once.

- The directory does the matching, so counts reflect everything it holds, not
  just what this tab has loaded. A page is 32 rows whether the directory holds
  thirty rooms or three hundred thousand.
- Every word of a search must appear somewhere in a row, in any field and any
  order.
- While a search has matches, each inventory that can retire rows offers to
  retire all of them. It asks first, then works in batches, and the operator
  can stop between batches.

**The listeners pane** has one switch per transport the server lists, each
described in its provider's own words.

- On brings the listener up and off takes it down.
- A listener that is up shows its locator. One that is down shows a field for
  each setting its `up` accepts.
- The listener serving this page is marked and cannot be switched off.

**The peering pane** lists a room this tab has joined on another directory in
this one. Each listing has exactly one revocation, carried by its lease.
Dropping the capability without revoking leaves the listings in place until
the directory connection ends.

**The visualizer pane** names the endpoint this session publishes to, and
lets you override it.

## Watching the room live

`--trace` serves the live timeline endpoint on loopback at `--trace-port`
(default 9300, or `0` for any free port). It prints `ROOMS-TRACE-LISTENING`
followed by its trace sturdyref. The locator advertises separate
`captp-websocket` and `trace-publish` endpoints. `/captp` opens a CapTP byte
channel; fetching the trace object still requires its Swiss. The `/` viewer
and `/publish` telemetry routes additionally require `?cap=<swiss>`.
Use `--trace-connect=<ws-url>` and `--trace-publish=<ws-url>` to advertise
exact routes through a deployment proxy, including its path prefixes.

To watch: start the [ocapnviz](../ocapnviz/) viewer
(`zig build ocapnviz-dev`), switch it to **Live**, and paste that sturdyref
into the Source field. Every session the room accepts, every message in
either direction, and every close then appears on the stage. **Record**
captures, and **Stop** hands the capture to Play.

Direct messages never pass through the room, so each member publishes its own
trace to the same endpoint.

- A browser tab uses the advertised CapTP channel to acquire the trace
  capability and the separately advertised producer route to publish. It publishes only while it holds the trace
  swiss number, taken through the Protocol visualizer toggle under Holdings.
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
- `GLOWCAP_RELAY_MAX_IROH_SESSIONS` (16) and
  `GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` (twice the session limit) limit the iroh connections,
  each of which runs its own endpoint runtime.

Raise a limit only for the resource it names.

## Known limitations

These are the limits of Rooms itself. The library's limits, including
transports and browser reachability, are in
[known limitations](../../docs/boundaries.md).

- **Rooms runs on Linux and macOS hosts and in Chromium-class browsers.**
  One Rust implementation owns every Rooms service and the browser
  application; TypeScript renders the page and drives the Deno client, the
  demos, and the tests, and `zig build source-check` refuses a second server
  or IRC owner in TypeScript. That establishes neither Windows support,
  file-lock behavior on other filesystems, nor public Tor circuit
  reachability, and no throughput or latency figure is claimed for it.
  The repository defines a workflow for [host product packages](host.md)
  on matching runners. A workflow definition does not establish that a
  particular run passed or that an archive was published. Local Linux evidence
  does not establish macOS behavior.
  A Linux devcontainer does not cross-build
  the Rust session for macOS. The macOS packages are not Developer ID signed
  or notarized, and the package proof does not establish Gatekeeper acceptance
  of a downloaded artifact or reachability through a particular public network.

- **A Rooms message consumer has a bounded unread queue.** `Room.messages`
  hands a line directly to a pending read and otherwise retains at most 256
  unread messages. A consumer that remains stalled past that bound receives a
  stream error and must subscribe again. Cancellation, overflow, replacement,
  and leave release every unread file capability; the browser client keeps a
  read pending during ordinary use.

- **Rooms sessions are capabilities, not accounts.** No ambient login or server
  account owns a durable session today. The session sturdyref is the authority
  to attach, and each delegated facet can be revoked independently. A future
  account capability may retain or mint session grants and durable name claims;
  it must not turn those powers into identity inferred from a login string.

- **Durable Rooms sessions do not make every resource durable.** Attached views
  share one network identity and managed workspace. They also share directory
  discovery, archive choice, capabilities, peering intent, history, live files,
  operator actions, listener and IRC administration, and visualizer publication.
  Browser `File` handles and object URLs remain device-local.
  A browser tab opens its managed workspace in IndexedDB on its Wasm Host.
  Reload restores durable grants and custody recipes; connection-bound
  references still require their original authority to be reachable.

- **A durable session's bridge credentials are retained, not encrypted.** The
  password a member answers a bridge form with lives in the session peer's own
  `bridge-secrets.json`, under the state directory's permissions, beside the
  identity seed that already grants the whole session. It never enters a
  managed workspace, snapshot, or export, and it is dropped once no room still names
  its scope. A browser's local workspace holds none across a reload, and a
  workspace adopted into a peer carries the intent without the password; both
  ask the member to answer the bridge once more (ADR-0141).
  A live transferred attachment remains available only while its room, direct
  line, and session custody remain valid. A selected member archive may retain
  the same message's bytes separately and serve them after restart through its
  own scoped capability. The workspace stores neither copy nor an invented
  promise that an archive retained one. Room-link invitations are bounded
  workspace intent: local reconstruction and a durable Rooms session retain
  the handed sturdyref until the reader accepts or dismisses it.
  Received archive-share rows are runtime-only. A live facet dies with its
  session or one read. A durable offer's sturdyref is the Host publication;
  the conversation-card reminder is not workspace intent, so a restart forgets
  the reminder without revoking the share.

- **One-shot room invitations are live capabilities today.** Native rooms and
  IRC bridges bound them and retire them with their live room generation. Their
  claim receipt survives a lost claim answer and all retry entrances compete
  over one membership admission. Rooms does not yet persist these invitations
  as individually revocable sturdyrefs across a server restart.

- **Ordinary session-effect deduplication is bounded.** The durable ledger keeps
  64 completed operation identities. The browser never automatically retries an
  ambiguous send, edit, withdrawal, operator mutation, listener change, or IRC
  change. A manually replayed UUID after it has left that window has no
  indefinite at-most-once guarantee. Private-room and durable-authority effects
  instead keep a typed pending result and an idempotent recovery key until
  resolution.

- **Room delivery receipts require retained local state.** Native room senders
  share one 256-message, 2 MiB budget between pending text and unread messages.
  Receipts preserve ordering and correlation; they do not make retries
  idempotent. Upload reuse depends on an immutable source, acknowledgement,
  and admission to the existing media cache. Streaming sources and cache
  pressure may require ordinary reads. The delivery contract and measured
  costs are recorded in
  [ADR-0160](../../docs/decisions/adr/ADR-0160-rooms-retained-delivery.md).

- **Room durability is separate authority from membership.** Ordinary
  `open`/`enter` and a room entrance reference grant no right to create durable
  entry authority. Rooms-native managed creation separately returns a passable
  manager for that room's registered public name, entry-link, and moderator
  generations. The live room still disappears when empty; its registration
  reserves the name and named entry reconstitutes it. A room entry link is not
  that registration and grants no management. Losing every manager copy
  requires the directory operator to recover one; sharing a manager delegates
  management rather than transferring it exclusively. Revoking an entry link
  blocks later admission through every old copy but does not evict a membership
  that already subscribed. The current manager can unregister the room. That
  retires its public entrance and moves it to private access while its room
  link, moderator, manager, and existing memberships remain. The public name
  is then available to another room, so registering this room again may meet a
  name collision.

- **Local browser reconstruction is not a multi-writer merge protocol.** A
  local workspace uses one coalesced localStorage writer per tab. Explicit
  import and clear notify sibling tabs, but concurrent ordinary local edits are
  not merged. Use one durable Rooms session capability when several browsers or
  tabs must mutate the same workspace and network identity.

- **Directory discovery is a bounded live view.** A list or watch baseline
  carries at most 256 current room publications. Watch clients receive an
  explicit truncation event and continue receiving later deltas. A one-shot
  list has no continuation cursor yet, so callers that need a complete large
  directory inventory must use the paged operator capability.

- **The IRC adapters have IRC representation and delivery limits.** The bridge mirrors one channel into an
  ordinary Rooms directory and is read-only unless the operator selects
  two-way mode with TLS and SASL credentials. Two-way posts use the bridge's
  registered nick and a visible `<nick>` prefix. IRC supplies no acknowledgement
  for a channel message, so an ambiguous TCP failure may repeat or lose the last
  line even though the bounded queue survives an observed write failure. The
  client front maps only existing IRC-addressable room names. It fixes a
  nickname for the connection because Rooms grants names per capability and no
  atomic rename exists across several memberships. Native names outside IRC's
  alphabet receive disclosed connection-local aliases. Lines, topics, and file
  capabilities that cannot fit IRC are reported rather than silently truncated
  or discarded. Foreign room publications without a member count, and native
  room names IRC cannot address, are omitted from `LIST` with a notice instead
  of invented fields. IRC carries neither edits nor capability-bearing file and
  room offers. IRC is an application adapter, never a CapTP transport; there is
  no IRC server link and no CapTP-over-IRC netlayer.
