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

Run Rooms with the [overview](README.md) or the Docker Compose
[deployment guide](web/deploy/README.md). For source changes, see
[Developing Rooms](developing.md).

Participants running outside Docker use the [glowcap product package](host.md).
Give them the host-reachable `/locator` URL, not an internal Compose hostname.

Docker Compose sets the state directory, retained history, and transport
options. For Docker, start with [Operator capabilities](#operator-capabilities),
[The session service](#the-session-service),
[Watching the room live](#watching-the-room-live), and
[Security posture](#security-posture). Put those settings in the Compose
override. The state directory and flag sections cover host installations.

## The server and its state

`rooms-server` is the directory members register with, and it hosts the rooms
they enter. It records names and tells watchers who is registered, relays
introductions and WebRTC signaling, admits members and delivers room traffic,
hosts files within room and server limits, and optionally keeps history.
The [work admission guide](../../docs/rooms/admission.md) covers temporary
refusals and operation rates.

```sh
glowcap apps rooms directory serve --state="$HOME/rooms-state" --history
```

Without `--state`, the server gets a fresh identity on every start and forgets
everything when it stops. With `--state`, the directory holds:

- `rooms.json`: the server document, including the identity seed and the
  secret every room link is derived from
- `operations.json`: listener options, and IRC networks and channels
- one file per capability swiss number
- `onion-key`, when the transport is onion
- `history/`, the kept lines of each room, with `--history`
- `.rooms-server.lock`, held while a server runs

One process at a time can hold a state directory. To back it up, stop the
server, copy the whole directory, and restore it as one unit.

On startup the process prints `ROOMS-SERVER-LISTENING` followed by the
address members dial. For a loopback TCP room that is just the port, and with
`--announce-host` it is `host:port`. Otherwise it is the complete locator.
`GLOWCAP_ROOMS_READY_FORMAT=json` prints one JSON line instead, with the
address, the timeline listener, and the local endpoint. A server started on
its own prints its `ROOMS-*` link lines either way. Under `rooms-web` the
JSON record carries them and `rooms-web` prints them in its own block.

Options use `--name=value` and can also come from `GLOWCAP_ROOMS_*`
environment variables. Unknown or repeated options are refused, and so is a
listener option the chosen transport does not read, such as `--port` with
iroh.
`--transport=<transport>` chooses the announced listener from the transports
the Listeners page offers: `tcp`, `keyed-tcp`, `noise-tcp`, `iroh`,
`keyed-relay`, `noise-relay`, or `onion`.

- The default is iroh with discovery.
- `--reachability=direct` is for a self-contained run on one host.
- `--transport=tcp --port=0` is cleartext loopback. Add `--bind` and
  `--announce-host` to serve a LAN. `keyed-tcp` and `noise-tcp` take the
  same options and are dialed by the server's key.
- `--transport=noise-relay` registers at a relay named by `--relay=<ws-url>`
  or `GLOWCAP_ROOMS_RELAY_URL`. Under `rooms-web` the relay defaults to that
  server's own `/relay`. The relay listener advertises the relay as peers
  dial it, so behind a port forward or a proxy `rooms-web` takes
  `--http-public=<url>` and a standalone server takes
  `--relay-public=<ws-url>` (or `GLOWCAP_ROOMS_RELAY_PUBLIC_URL`).
  `rooms-web` refuses `--relay-public` for its own relay, which `--http-public`
  names, and accepts it with `--relay`.

`SIGINT` and `SIGTERM` stop admitting members, close the listeners, finish the
writes already admitted, and release the state directory.

`rooms.json` is version one, and the server refuses any other shape without
rewriting the file. The same rule covers the session and archive files, history
rows, and the browser's session and archive. To reset a development setup,
stop the peers, remove their state directories, and clear the Rooms origin's
browser site data. For a Docker deployment, see
[data and reset](web/deploy/README.md#data-and-reset).

### Listeners

Each `--listen=<transport>[,<name>=<value>...]` opens a listener beside the
`--transport` one, once per transport, with that transport's options as
`name=value` pairs. The server starts once
every listener is open. Its `/locator` then names the directory by its key
with every listener listed, so a browser that can open one of them itself,
such as `noise-relay`, reaches the directory with no Rooms server chosen.

The shared session takes the same choices under `--session-`:
`--session-transport` picks its listener, and any other `rooms-session`
option passes through as `--session-<option>`, such as `--session-bind`. The
page is offered the session through any listener a browser can open: iroh, a
relay, or a TCP listener this server forwards to. A relay listener registers
at this server's own relay unless `--relay` or `--session-relay` names
another, and `--relay-public` and `--session-relay-public` are accepted only then,
because peers dial this server's own relay at `--http-public`.

## Operator capabilities

An operator capability is a link that grants one power to whoever holds it.
`--capabilities` names the ones to create: `all`, or names from the table
below separated by commas, such as `--capabilities=diagnostics,peering`.
`GLOWCAP_ROOMS_CAPABILITIES` takes the same value, and the option wins over
the variable. Leave a name out to withhold it. A name that is unknown, empty,
or repeated is refused.

The server keeps each capability's swiss number (the
secret part of its link) in the state directory. A foreground server normally prints each
complete `ocapn://` link as a `ROOMS-*` line. The deployment image sets `GLOWCAP_ROOMS_PRIVATE_STARTUP`
to keep bearer links out of startup and restart logs. Set it in another supervisor's environment if it retains output.

`glowcap apps rooms capabilities --state=<state-directory>` prints the saved
capabilities again as complete links. Under Docker, run
`glowcap apps rooms deployment links`, or the `docker exec` form the
[deployment guide](web/deploy/README.md#read-your-links-again) shows.
These commands read the directory's advertised locators from the running web
server at `http://127.0.0.1:8080` or the address `--url` names. For a saved
timeline that is not running, they print the option needed to start it. Without a running
server, set the locator in `GLOWCAP_ROOMS_LOCATOR` and the timeline's in
`GLOWCAP_ROOMS_TRACE_LOCATOR`. Otherwise, the affected line reports the missing
locator while the others print.

| Name | Prints | Grants |
| --- | --- | --- |
| `admin-listeners` | `ROOMS-ADMIN-LISTENERS` | List the server's listeners, bring one up on a transport it can realize, take one down |
| `diagnostics` | `ROOMS-DIAGNOSTICS` | Inspect: the names the directory holds and its recent failures |
| `operator` | `ROOMS-OPERATOR` | Issue, recover, and revoke every local room's manager and moderator links, forget a room, and use the lists and bulk removal on the Operator page |
| `peering` | `ROOMS-PEERING` | List a durable room from another directory |
| `irc` | `ROOMS-IRC` | Open IRC networks and bridge channels as rooms |
| `trace` | `ROOMS-TRACE`, `ROOMS-TRACE-LISTENING` | The live timeline endpoint and the capability its sockets present |

Anyone who can read the state directory or a copy of these links holds the capabilities.
This includes logs collected from versions that printed them on startup.

In the browser, each one is a toggle under **Settings**, **Holdings**.

- Turning one on asks for its link and uses it on the live connection to the
  directory. If you opt in, the form remembers the link on that device,
  separately for each directory.
- While you hold any of them, an **Operations** control on the **Settings** title
  line opens the Operations page. Each page has its own address under `/ops`.
  The **Inspect this server** and **Operator** toggles both open the
  **Operator** page, which holds the **Inspect** section and, with the
  operator link, the operator's inventories.
- Turning a toggle off drops the link. So does a reconnect.

The web launcher forwards `--capabilities` to the server it starts, so
`glowcap apps rooms serve --capabilities=diagnostics` works.

## History

History is off by default. `--history` (or `GLOWCAP_ROOMS_HISTORY=1`) keeps
each room's recent lines and sends them to any member who asks. The page
asks when you enter a room whose log is empty, and shows the answer under a
divider naming the room as the keeper.

- For a file message, history keeps the caption text and not the file.
- Room history excludes direct messages. A member's chosen archive keeps
  them, in their browser by default.

**Limits.** One room keeps at most <!-- value rust/application/src/server/history.rs LINES_KEPT -->500<!-- /value --> lines. The whole server keeps at
most <!-- value rust/application/src/server/history.rs LINES_KEPT_TOTAL -->4,096<!-- /value --> lines across
<!-- value rust/application/src/server/history.rs ROOMS_KEPT -->256<!-- /value --> rooms. A room past its limit loses its oldest line. Past
either server limit, the server drops the whole history of the least recently
active room.

**Where history is stored.** Kept lines live in one JSONL file per room
under `history/`. A server with no state directory keeps them in memory.
Startup restores and validates storage before opening the listener. An
unusable history directory stops startup.

**File storage.** Startup is refused for a room file over
<!-- value rust/application/src/server/history.rs FILE_BYTES bytes -->64 MiB<!-- /value -->, a directory over
<!-- value rust/application/src/server/history.rs DISK_BYTES bytes -->512 MiB<!-- /value -->, an unexpected entry, or a corrupt complete row. A crash can leave an
unfinished final JSON row. Startup can skip that row, but leaves its bytes in
the file. A later append can turn it into a corrupt complete row that stops
the next startup. A crash can also lose a queued write that has not finished.

## The session service

A shared session is one person's Rooms session kept running on a server:
the directories and rooms they are in, direct conversations, drafts, history
and connection choices, and the links the session holds. Several browsers
attach to it and see the same thing. Closing every browser changes nothing.

```sh
glowcap apps rooms session serve --dir=./rooms-session
```

When its session, listener and publications are ready, a foreground session normally prints
`ROOMS-SESSION-LISTENING`. The deployment image keeps this link private. The session writes the use link to `use.sturdyref` and
the independent management link to `management.sturdyref` in the state directory.
`--readiness-file` sets where the use link is also written. The Compose
deployment uses a private tmpfs.

- The link files have mode 0600. They are removed on an orderly stop and before
  every startup once this process has the session to itself. A refused second
  process cannot remove the running owner's files.
- `glowcap apps rooms session ready --file=<path> --quiet` validates the readiness file and exits successfully
  when it holds a use link. Omit `--quiet` to print the link.
- The use link authorizes using the session and the management link authorizes
  managing it. Protect both, and share narrower grants through the access
  editor.
- `--dial-transports=<list>` names the transports the session dials beside
  the one it listens on: `noise-tcp`, `iroh`, `onion`, `webrtc`, and the
  cleartext `tcp` and `keyed-tcp`. Any TCP name adds `noise-tcp`. The session
  dials a cleartext transport only when it listens there or the list names
  it, so an address a room hands over never opens a cleartext dial by itself.

In the browser, **Attach** (on the first screen, or under **Settings**, **Session**)
opens the shared session. It does not copy the browser's previous
session into it. Every attached browser is a view of the same session.

**Session access** offers presets for reading, conversation actions, session
changes, and access management. A management link with permission to issue
grants can grant no broader authority than its own.

Sharing management creates a separate link with the powers you choose:
editing, pausing, resuming, or revoking grants within its scope. These powers
are independent of session use permissions. Changes survive restart, and the
session checks the initiating grant on every operation.

A password entered in an IRC bridge form is kept unencrypted in
`bridge-secrets.json` in the state directory, only while a room still needs it.
It never goes into the session, a snapshot, or an export. The file is plain
JSON protected by the directory's permissions, since anyone who can read the
directory can already act as the session using the identity seed beside it.

A local browser session persists in IndexedDB. When you share access, its use
or management link lets the recipient connect to this tab. Live connections end when the tab closes. Open Rooms again at the same address in the same browser profile to resume the last workspace, including its shared-session access.

If Rooms shows **Choose a session**, look under **Saved on this device** for workspaces this browser still holds. If several workspaces are listed, select one by its workspace ID. Rooms marks the last one you opened when it knows which one that was. Choose **Resume workspace** to reopen its rooms and drafts.

To try another saved workspace, open **Settings**, then **Session**, and select **Choose workspace…**. Each keeps its own access. If another tab has the workspace open, close it first. A Home Screen installation and Safari can keep separate workspaces.

To empty a workspace you administer, open it and choose **Settings** → **Session** → **Export or reset…**. Emptying a shared session affects everyone attached. To erase all Rooms workspaces and preferences in this browser profile, choose **Advanced** → **Delete browser data…** on the session setup screen.

### Local command access

To keep a coding agent present in Rooms through a session, see the
[bot guide](../../docs/rooms/bot.md).

`glowcap apps rooms session start --dir <directory>` starts the shared session
with local control. Underneath, `rooms-session --state=<directory>
--local-control` adds a Unix socket at `<directory>/control.sock`.

- The process restricts its state directory to its owner.
- Access to this socket means full administration of the session, including
  its private conversations.
- JSON commands never arrive on a network port.

The socket takes one newline-terminated JSON request per connection. `RequestBody` in
[`control.rs`](rust/services/src/session/control.rs) lists every request type.
The everyday ones are `status`, `tick`, `ack`, `command`, and `stop`.
`command` takes an operation `id`, a command `name`, and string `args`, and the
shared Rooms application validates and runs it. This view observes every joined
conversation, even while another one is selected.

**Reading events.**

- The `tick` request returns up to <!-- value rust/services/src/session/control/inbox.rs PAGE_ROWS -->64<!-- /value --> retained events and waits up to
  <!-- value rust/services/src/session/control.rs MAX_TICK_WAIT_SECS seconds -->30 seconds<!-- /value --> for new ones. Reading does not acknowledge them.
- The `ack` request takes numeric event `ids`.
- The CLI's `session listen` command uses the returned change cursor to wait
  for new commits even when unread events remain, so it does not fetch the
  same batch again.
- Unacknowledged events and their IDs survive a restart.
- File events describe the file and carry no bytes.

**The inbox and gaps.** The inbox holds at most
<!-- value rust/services/src/session/control/inbox.rs MAX_ROWS -->4,096<!-- /value --> events within a
<!-- value rust/services/src/session/control/inbox.rs MAX_BYTES bytes -->16 MiB<!-- /value --> log, written to disk in the background.
Queue pressure, a full disk, or a failed write stops only the inbox, and
`status` reports `inbox.gap`. To recover, fix the cause, dismiss the events you
have reviewed, then run
`glowcap apps rooms session resume --dir <directory> --accept-gap`. That
resumes recording events but cannot recover the ones missed.

## The archive service

The archive is a member's own history, behind one link:

```sh
glowcap apps rooms archive serve --state="$HOME/rooms-archive"
```

The process prints `ROOMS-ARCHIVE-LISTENING` followed by the link.
Whoever holds that link can read and write the whole archive.

- It keeps at most <!-- value rust/application/src/archive.rs MAX_RECORDS -->5,000<!-- /value --> records and bounds its log.
- A second process on the same directory is refused, and a crashed process
  leaves no stale lock.
- A corrupt complete row stops startup. An unfinished final append is
  repaired.

In the browser, **Settings**, **Holdings**, **Use an archive peer…** takes the
link and sends new history there.

- If the peer cannot be reached, it shows as unavailable and writes are
  refused, never redirected to the browser's own store.
- **Use session archive** sends later reads and writes back to the session's
  own archive.
- Reads come from every archive the member holds at once, with each archive
  named at its own divider.
- A conversation's card can give another member a read-only view of what the
  archive kept. From an archive peer it can instead give a durable share that
  lasts until revoked.

Every service also accepts `--transport=onion`. Put a running Tor
daemon's endpoints in `GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`. The
services keep `onion-key` in the state directory and never start Tor
themselves.

## The IRC gateway

The `irc` capability creates the gateway capability. The Operations page shows it as a
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
  They never go into snapshots or the browser's saved state. A shared session
  keeps them to log in again after a restart, and a browser asks again after a
  reload.
- A refused login restores the member's previous identity.

Being in a bridged room means being in the channel. `/me` crosses as an
action in both directions, and a member's own messages echoed back by the
channel are hidden. The channel's topic is the
room's subject, and a member who joins later hears it too. A topic that
cannot be a subject, for example because it is too long, appears as a message.
The room then has no subject.

[IRC on Rooms](irc/README.md) covers the standalone bridge and IRC server, the
network policy a bot must follow, and the bounds.

## Moderation

Rooms has no ranks. Moderation powers come from held links. Ignoring is a
local preference.

- **Ignoring.** `/ignore` hides someone in your own window only. No server
  learns of it.
- **The manager.** Creating a room through managed creation returns a manager
  link. Holding it lets you manage only the room's public registration,
  entry link, and moderator.
- **The moderator.** The manager issues the moderator explicitly, from room
  details or with `/moderator`. Someone else can take it with
  `/moderator <link>`, and the page checks that it governs this exact
  room before keeping it.
- **Kicking.** `/kick`, or the confirmed action on the member card, asks a
  member to leave through the moderator. The member is told directly, and the
  room sees why they left. Kicking creates no ban, because anyone can take
  the same nickname later.

Revoking one of these links replaces its secret. Every old copy and every
reference restored from one is refused at once, and the next issue creates an
unrelated one.

The `operator` capability can recover the moderator and manager links of any
local room, including private rooms. Its page lists every room the server
owns, including rooms nobody is in, with the links that stand for each. It
issues and copies the manager and moderator links, revokes either after a
second confirmation, and **Forget room** removes a room with its members,
its links, its subject, its kept messages, its name, and its settings. It
cannot enter a room or kick anyone on its own authority. Peered rooms stay under their source directory, and
bridged IRC rooms take no manager link and are removed with their bridge.

## The Operations page

The **Operator** page opens with **Inspect**, which lists what the directory holds: rooms, occupants, registrations,
and durable links (whether one is active, never its swiss number), beside the
server's recent failures.

**The operator's inventories** add the capabilities the server owns, grouped
by kind, with one search across all of them.

- The directory does the matching, so counts cover everything it holds. A
  page holds at most <!-- value rust/application/src/server/operations/operator.rs MAX_PAGE -->32<!-- /value --> rows.
- Every word of a search must appear in a row, in any field and any order.
- While a search has matches, each inventory that can retire rows offers to
  retire all of them. It asks first, then works in batches, and the operator
  can stop between batches.

**The Listeners page** has one switch per transport the server lists, each
described in its provider's own words.

- A listener that is up shows its locator. One that is down shows a field for
  each setting it accepts when brought up.
- The listener serving this page is marked and cannot be switched off.

**The Peering page** lets you list a room from another directory in this
one, provided this tab has joined that room. Each listing returns a lease
capability that can revoke it. Dropping the capability without revoking leaves
the listing in place until the directory connection ends.

**The Visualizer page** shows the endpoint this session publishes its trace to
and whether publishing is **on**, **refused**, or reconnecting. Publishing
starts when the **Live trace** toggle under **Holdings** holds the trace link,
and the page has no switch of its own.

## Watching the room live

The `trace` capability serves the live timeline endpoint at `--trace-bind`
(default `127.0.0.1`) and `--trace-port`
(default <!-- value rust/services/src/server/config.rs TRACE_PORT plain -->9300<!-- /value -->, or `0` for any free port).
The server prints `ROOMS-TRACE-LISTENING` followed by its trace link. The locator advertises separate
`captp-websocket` and `trace-publish` endpoints.

- `/captp` opens a CapTP byte channel for a viewer. Fetching the trace
  object requires its swiss number.
- `/publish` takes telemetry from a producer whose first message is the swiss
  number.
- A route with a query is refused, so no address carries the secret.
- `--trace-connect=<ws-url>` and `--trace-publish=<ws-url>` advertise exact
  routes through a deployment proxy, including its path prefixes.
- The listener speaks cleartext WebSocket, and the server refuses to
  advertise a `ws://` route off loopback. A specific `--trace-bind` address
  other peers reach needs a TLS proxy and both of its `wss://` routes named.
  A wildcard `--trace-bind` advertises loopback routes.

For a deployed stack, follow the protocol feed directly:

```sh
glowcap apps rooms deployment trace
```

Add `--json` for complete records, or `--dir` to select another deployment.
The command starts a disposable viewer on the deployment network, so no trace
port needs to be published. It receives replay followed by new protocol events.
Ctrl-C closes and removes the viewer.

For a local server, use `glowcap apps rooms trace --state=<directory>`.
`--url=http://127.0.0.1:<port>` selects its web address. `--print-link` prints
the complete trace link without subscribing.

To subscribe from another machine, pass the full link to
`glowcap apps rooms trace '<trace-link>'`. Its advertised WebSocket endpoint
must be reachable there.

To watch, open the [ocapnviz](../ocapnviz/README.md) protocol viewer, switch it
to **Live**, and paste the trace link into the **Source** field. Every session
the room accepts, every message in either direction, and every close then
appears on the timeline. **Record** captures, and **Stop** opens the capture in
**Play**.

The [viewer on the website](https://glowcap.org/ocapnviz/) watches a server on
the same computer as the browser. For a server on another machine,
[Developing Rooms](developing.md#building-and-deploying-from-a-checkout)
starts the viewer from a checkout.

Direct messages never pass through the room, so each member publishes its own
trace to the same endpoint.

- A member's trace records who it talked to, when, which request type, and how
  many bytes, never the bytes themselves. The room server publishes its own frames
  in full.
- A shared session publishes from the session process, and its attached tabs
  do not publish a second copy.
- An ephemeral trace port is carried in both advertised endpoints.

## The web launcher

`rooms-web` serves the page, its `/relay` WebSocket, `/locator`, `/page`,
`/ice`, and `/llms.txt`, and supervises the directory. `/page` answers the
link that opens the first allowed Rooms page with this server, which
`glowcap apps rooms page` prints.
On startup it prints `ROOMS-WEB-LISTENING` followed by the HTTP port it
bound, so a supervisor that passes `--http-port=0` learns where to reach it.

- It keeps one room identity across server crashes. A server that had been
  running comes straight back. One that exits as soon as it starts is
  restarted more slowly each time, up to half a minute apart, so the message
  it printed stays readable.
- By default it uses a private temporary state directory that lasts as long
  as the launcher. Set `GLOWCAP_ROOMS_STATE` when the identity, room links,
  and operator choices must survive. `glowcap apps rooms serve` keeps its
  state by default.
- If a TCP Rooms server already holds the room port, the launcher attaches to it
  instead of starting its own. The capabilities it prints are then that
  server's.

Some settings accept only environment variables. Set them when starting the
launcher, or under `services.directory.environment` in a deployment's
`docker-compose.override.yml`.

The relay's limits:

- `GLOWCAP_RELAY_MAX_SESSIONS` (<!-- value rust/services/src/web/relay/limits.rs DEFAULT_SESSIONS -->256<!-- /value -->) limits relay sessions and timeline
  connections through the web address.
- `GLOWCAP_RELAY_MAX_REGISTRATIONS` (<!-- value rust/services/src/web/relay/limits.rs DEFAULT_REGISTRATIONS -->256<!-- /value -->) and
  `GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY` limit rendezvous
  registrations.
- `GLOWCAP_RELAY_MAX_IROH_SESSIONS` (<!-- value rust/services/src/web/relay/limits.rs DEFAULT_IROH_SESSIONS -->16<!-- /value -->) and
  `GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` (twice the session limit) limit the
  iroh connections, each of which runs its own endpoint runtime.

Raise each limit only when its own resource runs short.

Browser-to-browser WebRTC and the relay's TCP peers:

- `GLOWCAP_ROOMS_ICE_SERVERS` replaces the default public STUN servers with a
  comma-separated list. Empty means host candidates only.
- `GLOWCAP_ROOMS_TURN_CREDENTIALS_URL` and `GLOWCAP_ROOMS_TURN_BEARER_TOKEN`,
  set together, name an HTTPS credential issuer that gives peers behind a
  restrictive NAT short-lived TURN access. The token stays in this server, and
  browsers receive only temporary username and password rows from `/ice`.
  `GLOWCAP_ROOMS_TURN_TTL_SECONDS` bounds each credential, 300 to 172800,
  default 86400.
- `GLOWCAP_RELAY_TCP_PEERS` lists `host:port` TCP peers, separated by commas,
  that the relay forwards browser connections to.

## Security posture

- The web launcher sets a hashed-script Content Security Policy,
  `frame-ancestors 'none'`, `nosniff`, `no-referrer`, and a permissions
  policy. The policy allows inline styles (`style-src 'unsafe-inline'`), which
  the page's React styles need.
- Link preview refuses private, loopback, link-local, and IPv4-mapped
  targets, and bounds redirects, connect time, and body size.
- Relay and preview upgrades check `Origin`. It must match the request's `Host`
  or an origin that `GLOWCAP_RELAY_ALLOW_ORIGINS` (or `--allow-origin`) lists,
  by origin or page address. Unset, the list holds the published glowcap.org
  Rooms page, and setting it replaces that default, so name the page there to
  keep it.

  By default, `glowcap apps rooms deployment up` prints a link that
  opens the published page with your server. Listing your own page first
  changes that link to yours. An empty value allows none. A request with no `Origin` header is
  accepted so non-browser clients can connect.
- The IRC encoder refuses NUL, CR, and LF in every parameter and bounds line
  length.
- Published authority tokens are looked up by their SHA-256 digest, so the
  cost of a guess does not follow how many of its leading bytes match a real
  token.
- Identity and state files are created `0600` under `0700` directories.
- Each caller's work is checked against an allowance before it runs
  ([work admission](../../docs/rooms/admission.md)).
- The browser UI has no `innerHTML`, no `dangerouslySetInnerHTML`, and no
  `eval`, and every external anchor carries `rel="noreferrer"`.

## Known limitations

[Rooms limitations](limitations.md) covers application limits. The library's
limits, including transports and browser reachability, are in [known limitations](../../docs/boundaries.md).
