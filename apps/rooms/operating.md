# Operating Rooms

This guide is for whoever runs a Rooms server: the flags that grant it
capabilities, where its state lives, how history is kept, the three services
that survive a restart, moderation, and the Operations page. The
[Rooms overview](README.md) runs the application; [Developing Rooms](developing.md)
covers building and changing it; the [deployment guide](web/deploy/README.md)
runs everything here with Docker Compose.

## The server and its state

`rooms-server` is the directory members register with and the rooms they
enter. It files names, tells watchers who is registered and which rooms are
listed, relays introductions and WebRTC signaling between members, opens
rooms, seats members, delivers lines, topics, presence, typing, and
invitations, hosts files under the room and server budgets, and keeps
history when asked.

```sh
zig build rooms-server -- --state=.local/rooms --history
```

Without `--state` the server is process-local: a fresh identity each start
and nothing kept past it. With one, the directory keeps `rooms.json` (the
server document, including the identity seed and every issued room link),
`operations.json` (listener options, IRC networks and channels), one file
per capability swiss number, `onion-key` when the transport is onion, and
`history/` when history is kept in files. Only one process may hold a state
directory at a time. Stop the server before copying the directory for a
backup, and restore it as one unit.

The process prints `ROOMS-SERVER-LISTENING` followed by the address members
dial: the bare port for a loopback TCP room and the complete locator
otherwise. Options use `--name=value` and may also come from the
`GLOWCAP_ROOMS_*` environment; unknown or repeated options are refused. The
transport is discovery-backed iroh by default, `--reachability=direct` for
a self-contained same-host run, and `--transport=tcp --port=0` for cleartext
loopback, with `--bind` and `--announce-host` for a LAN. `SIGINT` and
`SIGTERM` stop new admission, close the listeners, drain admitted writes, and
release the state directory.

There is no released schema before this one. `rooms.json` is version one and
refuses every other shape without rewriting it; the same rule covers the
session and archive files, history rows, and the browser's workspace and
archive. To reset a development setup, stop the peers, remove their state
directories, and clear the Rooms origin's browser site data.

## Operator capabilities

Each flag below mints one swiss number the state directory keeps and prints
it as a `ROOMS-*` line at startup. No flag, no object: a capability the
process was not started with does not exist. `rooms-server
--capabilities=<state-directory>` prints the kept lines again at any time.

| Flag | Environment | Prints | Grants |
| --- | --- | --- | --- |
| `--diagnostics` | `GLOWCAP_ROOMS_DIAGNOSTICS=1` | `ROOMS-DIAGNOSTICS` | Inspect: the names the directory holds and its trouble journal |
| `--admin-listeners` | `GLOWCAP_ROOMS_ADMIN_LISTENERS=1` | `ROOMS-ADMIN-LISTENERS` | List the server's listeners, bring one up on a transport it can realize, take one down |
| `--operator` | `GLOWCAP_ROOMS_OPERATOR=1` | `ROOMS-OPERATOR` | Recover and revoke every local room's manager and moderator capabilities; the inventories and bulk retirement on the directory pane |
| `--peering` | `GLOWCAP_ROOMS_PEERING=1` | `ROOMS-PEERING` | List a durable room from another directory |
| `--irc` | `GLOWCAP_ROOMS_IRC=1` | `ROOMS-IRC` | Open IRC networks and bridge channels as rooms |
| `--trace` | `GLOWCAP_ROOMS_TRACE=1` | `ROOMS-TRACE`, `ROOMS-TRACE-LISTENING` | The live timeline endpoint and the capability its sockets present |

Whoever can read the state directory or the startup log holds these; that
is the whole of their access control. In the browser, each capability is a
toggle under Settings, Holdings: flipping one on asks for its swiss number,
takes it on the live directory session, and lands the toggle on; the form
can remember the number on that device, opt-in and per directory. While any
is held, an Operations control on the Settings title line opens the
Operations page, one address per pane under `/ops`. Inspect and operator
share the directory pane, because they are two authorities over one subject.
Turning a toggle off drops the capability, and a reconnect drops the
session-fetched ones the same way. The web launcher forwards these flags to
the server it starts, so `zig build rooms-web -- --diagnostics` works, and
`zig build rooms-dev` passes every one.

## History

History is something the operator grants, off by default. `--history` (or
`GLOWCAP_ROOMS_HISTORY=1`) keeps each listed room's recent lines and answers
them to any member who asks; the page asks on entering a room whose log is
empty and stands the answer under a divider naming the room as the keeper.
Private rooms never record. A file line keeps its caption and never its
bytes. Direct messages never reach the server; they go to the archive their
reader selected, which is their browser by default.

One room keeps at most 500 lines. The whole server keeps at most 4,096 lines
across 256 rooms, and at either edge it drops the least recently active
room's whole tail. The index applies that policy before either storage
backend sees a write, and startup restores and validates storage before the
listener opens.

Where kept lines persist is `--storage=` (or `GLOWCAP_ROOMS_STORAGE`). A
`postgres://` URL opens PostgreSQL; any other scheme is refused; a plain
value names a directory for JSONL files, one file per room. Without a
destination, history uses the state directory when there is one and memory
for the process's life otherwise. Naming a destination turns retention on
unless `--history=false` says otherwise, and an unusable destination refuses
startup.

Files: a room file above 64 MiB, a directory above 512 MiB, an unexpected
entry, or a corrupt complete row refuses startup; an unfinished final append
is the one tear a crash can leave and is repaired. A process or machine crash
can still lose an append the operating system had not made durable, and the
next start restores the last complete state rather than inventing a write.

PostgreSQL: the server takes a session lock so only one Rooms server owns
that history; use separate databases for independent servers. URLs accept
`sslmode=disable`, `prefer` (the default), or `require`; TLS verifies the
certificate and server name against system trust. Connection and transaction
work has a 30-second deadline, a persistence failure ends the server with
the reason, and an uncertain commit is never retried on its own. `zig build
rooms-postgres-test` exercises the installed server against the database
`GLOWCAP_ROOMS_STORAGE_LIVE_URL` names; `python3
apps/rooms/rust/services/tests/postgres_fixture.py` creates a disposable
cluster for it.

## The session service

A durable session owns one person's whole Rooms workspace: the directories
and rooms they are in, direct conversations, drafts, the history and
connection choices, and the capabilities the session holds. Several browsers
attach to it and see the same thing; closing every browser changes nothing.

```sh
zig build rooms-session -- --state=.local/.state/rooms
```

Once its state, grants, listener, and administrator publication are ready
the process prints `ROOMS-SESSION-LISTENING` and writes the administrator
sturdyref to `admin.sturdyref` in the state directory (`--readiness-file`
puts it elsewhere; the Compose deployment uses a private tmpfs). The file is
mode 0600, removed on an orderly stop and before every restart, and
`rooms-session --check-ready=<path>` reads it back as a health check. The
sturdyref is complete administration of the session; give it only to its
owner.

In the browser, Attach on the first screen or under Settings, Session takes
up the workspace the peer owns. A newly created session adopts that
browser's current workspace once; from then on the peer is the owner and
every browser is a view. Administration issues narrower links: Observe reads
only, Interact uses ordinary room and workspace actions, Admin manages the
other links and the checkpoint. What a link may do is read from the session
each time it is used, so administration can narrow, pause, or revoke a link
while somebody is holding it. Revocation survives a restart.

A password answered to an IRC bridge form is kept in `bridge-secrets.json`
in the state directory, never in the checkpoint or a snapshot to an attached
view, and only while a room still needs it. The file is plain JSON under the
directory's own permissions: anyone who can read the directory can already
act as the session from the identity seed beside it.

Share on a local session is the tab-lifetime sibling: this browser hosts the
session until the tab closes or reloads.

## The archive service

The archive is a member's own history, behind one sturdyref:

```sh
zig build rooms-archive -- --state=.local/member-archive
```

The process prints `ROOMS-ARCHIVE-LISTENING` followed by the sturdyref,
which is bearer authority to read and write the whole archive. It keeps at
most 5,000 records and bounds its journal; it is durable storage, not an
unbounded backup. A second process on the same directory refuses at once,
a crashed process leaves no stale lock, a corrupt complete row refuses
startup, and an unterminated final append is repaired.

In the browser, Settings, Holdings, **Use an archive peer…** takes the
sturdyref for new history. A peer that cannot be reached is shown as
unavailable and writes refuse rather than falling back to the browser store;
**Use this browser** returns later reads and writes to IndexedDB. Reads
answer from every archive the member holds at once, each account's keeper
named at its own divider. A conversation's card can hand another member a
read-only view of what the archive kept, or, from an archive peer, a durable
share that lasts until revoked.

All three services also accept `--transport=onion` with a running Tor's
endpoints in `GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`, keep
`onion-key` in the state directory, and start no Tor themselves.

## The IRC gateway

`--irc` mints the gateway capability. The Operations page draws it as a
bridge gateway without knowing IRC: a form to open a connection (an IRC
network), a form to add a channel under one, and the connections it holds.
A connection may have no channels and then opens no socket. A channel stands
beside the native rooms as `network/#channel`, and IRC members appear as
`irc/<nick>`. Removing a channel takes down only that channel; closing the
connection deletes the network and every channel beneath it.

One shared connection per network carries the feed. A member who wants to
speak on IRC opens their own identity connection from the IRC panel on their
member row, under their current nick or a projected one when it does not fit
IRC's alphabet, optionally logging in to a registered account. Those
credentials travel over TLS only, live only in the seat beside the
connection, and never enter snapshots or the browser's saved state; a
durable session keeps them so a restart can log in again, and a browser asks
again after a reload. A refused login restores the prior identity. Sitting
in a bridged room is joining the channel: `/me` crosses as an action in both
directions, IRC topic changes land as the room's topic, and a member's own
channel echo is suppressed so they never appear twice.

[IRC on Rooms](irc/README.md) covers the standalone bridge and front, the
network policy a bot must follow, and the bounds.

## Moderation

Moderation follows the capability model rather than adding ranks. `/ignore`
silences somebody in this window only, and no server learns of it. Creating
a room through managed creation returns a manager capability: possession of
it authorizes creating, recovering, and revoking the room's entry link and
moderator, and nothing else. The manager issues the moderator explicitly,
from room details or `/moderator`; another holder can take it with
`/moderator <sturdyref>`, and the page checks that it governs this exact
room before keeping it. `/kick` and the card's confirmed act ask a member
out through the moderator: the member hears it directly, the room reads why
the leave that follows happened, and no ban is minted, because a nickname is
not an identity to hold a ban against.

Revocation rotates the durable generation: every old sturdyref and every
reference enlivened from one refuses at once, and a later issue mints an
unrelated one. `--operator` is the recovery root for every local room,
private rooms included: its pane lists moderator inventory, gives an unissued
moderator or recovers the current one, and revokes room-link, manager, or
moderator generations after a second confirmation. It cannot enter or kick
by implication. Peered rooms stay with their source; bridged IRC rooms take
their moderator from the gateway.

## The Operations page

Inspect lists what the directory holds: rooms, occupants, registrations,
durable links (only that one is active, never its swiss), and the server's
own trouble journal beside the page's. The operator's inventories add the
capabilities the server owns, grouped by kind, and one search narrows all of
them at once. The directory does the matching, so counts are what it holds
rather than what this tab has read, and a page is thirty-two rows whether
the directory holds thirty or three hundred thousand. Every word of a search
has to appear somewhere in a row, in any field and any order. While a search
matches, each inventory that can retire rows offers to retire every matching
one; that act asks first, then runs in batches the operator can stop
between.

The listeners pane draws one switch per transport the server lists, each
described in its provider's words: on brings the listener up, off takes it
down, a row that is up carries its locator, and a row that is down draws one
field per knob its `up` accepts. The listener serving this very page is
marked and cannot be switched off. The peering pane publishes a room this
tab has joined on another directory into this one; each publication has the
one revocation its lease carries, and dropping the capability without
revoking leaves the listings until the directory connection ends. The
visualizer pane names the endpoint this session publishes to and holds an
override.

## Watching the room live

`--trace` serves the live timeline endpoint on loopback at `--trace-port`
(default 9300, `0` for any free port) and prints `ROOMS-TRACE-LISTENING`
followed by the sturdyref that admits its sockets. Start the
[ocapnviz](../ocapnviz/) viewer (`zig build ocapnviz-dev`), switch it to
**Live**, and give the Source field that sturdyref. Every session the room
accepts, every message in either direction, and every close then draws on
the stage; **Record** captures and **Stop** hands the capture to Play.

Direct messages never go through the room, so each member publishes its own
trace to the same endpoint. A browser tab reaches it through its own page
origin (`/trace` and `/publish` carry the socket), and publishes only while
it holds the trace swiss, taken through the Protocol visualizer toggle under
Holdings. What a producer sends is who it talked to, when, which verb, and
how many bytes, never the bytes themselves; the room server publishes its
own frames in full. A shared session publishes from the session process and
attached tabs do not add a second producer. `GLOWCAP_ROOMS_TRACE_PORT=0`
takes a free port, which a browser tab cannot discover on its own, so keep a
fixed port when members' direct messages should appear.

## The web launcher

`rooms-web` serves the page, its `/relay` WebSocket, `/locator`, `/ice`, and
`/llms.txt`, and supervises the room server. It keeps one room identity
across child crashes: a child that had been serving comes straight back, and
one that exits the moment it starts is restarted more slowly each time, up
to half a minute, so the line it printed stays readable. Its development
default is a private temporary state directory that lives as long as the
launcher; set `GLOWCAP_ROOMS_STATE` when identity, room links, and operator
choices must survive. If a Rooms server already holds the room port, the
launcher attaches to it instead of starting its own, and the capabilities it
prints are that server's.

The relay's budgets are environment variables the deployment guide lists:
`GLOWCAP_RELAY_MAX_SESSIONS`, `GLOWCAP_RELAY_MAX_REGISTRATIONS`, and
`GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY` bound WebSocket sessions and
rendezvous registrations, while `GLOWCAP_RELAY_MAX_IROH_SESSIONS` (16) and
`GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` (twice that) bound the iroh legs,
each of which owns an endpoint runtime. Raise a limit only for the resource
it names.
