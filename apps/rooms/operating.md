# Operating Rooms

What an operator grants a room server, and how each grant is used: watching the room's protocol activity live, bridging
IRC channels in, keeping history and choosing where it persists, the steward's word on memberships, and the operations
capabilities behind the `/ops` page. [Developing Rooms](developing.md) covers testing and extending the application; the
[Rooms overview](README.md) covers running it.

## Watching the room live

The room server can broadcast its own protocol activity as a timeline the [ocapnviz](../ocapnviz/) viewer draws. Start
the server with `--viz` (or `GLOWCAP_ROOMS_VIZ=1`), switch the viewer to **Live**, and point the Source sturdyref field
at the printed `ROOMS-VIZ-LISTENING` capability. The endpoint serves on port 9300; `GLOWCAP_ROOMS_VIZ_PORT` changes that
default and enables nothing on its own. Enabling also mints the viz capability: one swiss number, persisted under
`GLOWCAP_ROOMS_STATE` and printed as a `ROOMS-VIZ` token line, which the endpoint requires of every socket — reading the
timeline and writing traces into it alike. The sturdyref carries that swiss as its swissnum, so the viewer needs nothing
beyond the announcement:

```sh
zig build rooms-server -- --transport=tcp --port=9099 --viz
```

Entering Live connects to the feed. Press **Record** to capture: every session the room accepts, every message in either
direction, and every close draws on the stage from that moment. **Stop** hands the capture to Play, where it replays
like any other recording. The stream is the same versioned timeline schema `glowcap griddle run` prints.

Direct messages never go through the room, so each member also publishes its own trace to the same viz endpoint. A
browser tab reaches it through its own page origin: `/viz` and `/publish` on the web server carry the socket to the
endpoint, so the endpoint's own port never has to be published to the browser's host (in the devcontainer it is not),
and an HTTPS page keeps working where a bare `ws://` port could not. Reaching it is still not the authority to publish:
a local tab's sending arms only while it holds the viz swiss, taken through the "Protocol visualizer" toggle in
Settings under Holdings (the same take-and-remember flow as the other operations capabilities, presented to the endpoint
rather than fetched on the directory session). A shared session publishes from the session process with that same
toggle writing the session's capability set; attached tabs do not arm a second producer. What a producer sends travels
on a socket that carries nothing back but the endpoint's admission mark. The conversation stays private; the timeline
only merges the telemetry, and when both ends of one conversation report it, the endpoint draws it once. What a producer
sends is who it talked to, when, which verb, and how many bytes, never the bytes themselves: the other end of a direct
message never agreed to appear on a shared timeline. The room server publishes its own frames in full, so a room line
still shows its bytes on the timeline and a direct message never does.

The same works with the browser UI. The web supervisor forwards the flag to the room server it spawns, so `-Dviz` on
`rooms-web` or `rooms-web-tcp` traces the room and every tab's sessions with it:

```sh
zig build rooms-web -Dviz
zig build rooms-web-tcp -Dviz
```

The supervisor keeps one room identity across child crashes. A child that had been serving and then died comes straight
back; one that exits the moment it starts, the shape of a taken port or an unreachable state directory, is
restarted more slowly each time up to half a minute, so the line it printed about why stays readable instead of
scrolling past under copies of itself.

Its development default is a private temporary `GLOWCAP_ROOMS_STATE` directory that lives as long as `rooms-web`. Set
`GLOWCAP_ROOMS_STATE` yourself when identity, issued room links, public topics, operator-added listeners, and IRC bridge
choices must survive restarting the web supervisor. The container deployment does this with its `rooms-state` volume.
Rooms has no released persistence predecessor. The current `rooms.json` uses version one and refuses every other shape
without rewriting it. Delete stale development state explicitly before starting a peer built against a replaced
prerelease schema. The same rule covers durable session and archive files, room-history rows, the browser workspace
document, and its IndexedDB archive. For a clean development reset, stop the peers, remove their chosen state
directories, and clear the Rooms origin's browser site data.

Cargo must be on `PATH` for the iroh transport sidecar; Deno is required for the UI either way. The TCP form drops the
Cargo requirement and the encryption with it. Either command prints a `ROOMS-VIZ-LISTENING` line once the room server is
up. Open [ocapnviz](../ocapnviz/) (`cd apps/ocapnviz && bash dev.sh`), switch the top bar to **Live**, and give the
Source field that sturdyref.

## Session archive identity

Earlier Rust `rooms-session` builds encoded the private identity seed as the
archive source field. A history reader or remote archive receiving those records
could recover that identity. New recordings use the public identity instead.
This change does not rewrite existing archives or retract copies already shared.
If history from an affected session crossed its private storage boundary, treat
that session identity as exposed. Replacing it also changes identity-bound links;
account for those links and retained history before replacing the session state.
The ordinary browser tab's separate archive source was not produced by this code.

## Web relay admission

The web relay keeps file-descriptor admission separate from iroh endpoint admission. Every live iroh relay leg owns a
native endpoint runtime, so `GLOWCAP_RELAY_MAX_IROH_SESSIONS` sets that live limit (16 by default) and
`GLOWCAP_RELAY_MAX_IROH_DIALS_PER_MINUTE` bounds how quickly failed legs can replace it (32 by default). The existing
`GLOWCAP_RELAY_MAX_SESSIONS`, `GLOWCAP_RELAY_MAX_REGISTRATIONS`, and
`GLOWCAP_RELAY_MAX_REGISTRATIONS_PER_IDENTITY` settings govern the transport-neutral WebSocket and registration costs.
Raise each limit only for the resource it names.

## The IRC gateway

`--irc` (or `GLOWCAP_ROOMS_IRC=1`) mints an operator capability and prints it as `ROOMS-IRC`. The gateway describes
itself as an ordinary bridge gateway, so the Operations pane draws it without knowing IRC: a form to open a connection
(an IRC network), a form to add a lease under one (a channel), and the connections it currently holds. Opening a
connection retains a named network configuration. The connection may have no channels, and in that state it stays
manageable without opening a socket. Adding a channel stands it beside the native rooms. Readers enter, list, and watch
it like any other room, and IRC members appear as `irc/<nick>`. Removing a channel takes down only that channel.
Parting the last one closes the shared feed transport but keeps the network, and closing the connection deletes the
network and every channel beneath it. Either removal ends each live Rooms membership before another send can be
admitted. Recreating the same named bridge mints a fresh publication generation, and durable sessions rebind that saved
conversation only after the directory advertises the replacement.

One shared IRC connection per configured network carries the feed whenever at least one channel enacts it. Members are
IRC citizens through one identity connection per network. Subscribing adds that channel to the connection under the
member's current nick, projected when it does not fit IRC's alphabet. A post reaches IRC as that member before the room
echoes it, or fails closed with the network's reason. Leaving removes only that channel membership. The shared feed can
log into a registered account. The Operations pane sends those credentials over TLS, and the server retains them in its
protected operations state so it can reconnect after a restart. They never enter snapshots, the browser's saved state,
or the trouble journal. A member manages their own nick and optional registered account from the IRC panel on their
member row. The password is cleared before the request starts, never enters the composer or its recall history, and the
credentials live only in the seat beside the connection they authenticate. A durable session peer that submitted them
keeps its own copy, described under running one below, so a restart can log in again; a browser holds none across a
reload and asks the member to answer the bridge form again. Changing identity is transactional: a refused
login restores the prior working identity. Disconnecting keeps the Rooms membership explicitly Rooms-only, and a later
post never silently reconnects it. A cleartext bridge refuses registered credentials, the same custody rule as the
feed's. An automatically projected Rooms name may take one collision suffix, but a nick the member chose explicitly
either lands exactly or fails and restores the prior identity. Sitting in a bridged room is joining the channel: the
seat opens at subscribe, `/me` crosses as the CTCP ACTION it is in both directions, and IRC topic changes land as the
room's own topic line. Rooms standing stays room-scoped and does not emit IRC's network-wide `AWAY`. A seated member is one person everywhere:
the feed suppresses their own channel echo (their join, their lines, their roster entry) so they never appear twice, a
services force-rename follows them (the room tells them their new outward nick), and a dropped seat is said in the room,
not only the journal. The member list keeps one row per person and distinguishes IRC-only participants, Rooms-only
members, linked Rooms + IRC members, and connecting or failed links. The gateway's `snapshot` lists retained networks
and the channel leases beneath each one without exposing passwords.

## Storage and room history

Storage is something the operator grants the server, off by default. `--history` (or `GLOWCAP_ROOMS_HISTORY=1`) turns
retention on: each listed room keeps its last lines and answers them to any member who asks; the browser asks on
entering a room whose log is empty and stands the answer under a divider that names the room as the keeper. Where kept
lines persist is one separate value, `--storage=` (or `GLOWCAP_ROOMS_STORAGE`), whose shape picks the implementation
in the native server: a `postgres://` or `postgresql://` URL opens PostgreSQL, any other scheme is refused,
and a plain value names a directory for JSONL files. Without a destination, history uses the state directory when
one exists, or memory for the process's life. Naming a destination turns retention on unless `--history=false`
explicitly disables it. An unusable destination refuses startup before the listener opens.

The shared Rust history index owns retention; native adapters persist its admitted changes. PostgreSQL keeps the
existing `room_lines` schema and takes a database session lock so only one native Rooms server can own that history.
Use separate databases for independent servers. Stop the old TypeScript server before migrating; it does not take
this lock. Database URLs accept `sslmode=disable`, `prefer` (the default), or `require`. TLS verifies the certificate
and server name against system trust. Use `require` when the connection must be encrypted; `prefer` permits plaintext
when the database declines TLS. Connection and transaction work has a 30-second deadline. A persistence failure
ends the server with an error; an uncertain commit is never retried automatically.

`zig build rooms-postgres-test` exercises the installed Rust binary against the database named by
`GLOWCAP_ROOMS_STORAGE_LIVE_URL`. The process contracts require TLS and the repository fixture CA;
use a disposable cluster because the test creates and removes schemas. To create that cluster, run
`python3 apps/rooms/rust/native/tests/postgres_fixture.py` after `zig build rooms-server-build`.
The fixture requires PostgreSQL server/client tools on PATH, or `--pg-bin=/path/to/postgresql/bin`.
It owns its temporary cluster, uses TLS with SCRAM authentication, and stops the cluster on exit.
Run again with `--auth=password` to exercise password authentication over TLS.

The contracts cover existing schema recovery, edits, withdrawals, multiple rooms, restart,
competing-server refusal, bounded writer admission, malformed rows, transaction failure, wrong
password, hostname mismatch, and missing trust. Passwords must not appear in refusal diagnostics.
The native unit and process suite separately exercises connection deadlines and shutdown while
waiting for database startup, including closure of the unfinished connection before readiness.
File lines retain only their captions. Refiling changes that kept caption, and withdrawing or
refiling to an empty line removes it; file bytes remain under the attachment store's separate bounds and never enter
room history.

One room keeps at most 500 lines. The whole server keeps at most 4,096 lines across 256 rooms; reaching either global
edge drops the least recently active room's complete tail, with the room name breaking an equal-time tie. The same index
applies that policy before either backend sees a write. Startup restores and validates storage before opening a
listener. File storage refuses a room file above 64 MiB, more than 512 MiB across the history directory, unexpected
entries, and complete corrupt rows; an unfinished final append is the one recoverable tear. PostgreSQL refuses more than
the retained 4,096 rows and bounds field sizes before reading them into Rust. `SIGINT` and `SIGTERM` stop new history admission, close the listeners, drain admitted writes,
and then release storage. A process or machine crash can still lose an append the operating system had not made durable;
the next startup restores the last complete bounded state rather than inventing a successful write.

Server room history follows the operator's retention configuration rather than discovery policy. Open, moderated, and
private managed rooms all record when server history is enabled. A server without retention refuses the verb, which
clients read as the feature not existing there. Direct messages are separate. Their plaintext is end-to-end encrypted
and goes only to the member archive their
reader selected, which is their browser by default. The Message history switch on the Session tab in Settings controls that
recorder. Its contract is [ADR-0129](../../docs/decisions/adr/ADR-0129-member-owned-archive-capability.md): a bounded
`put`/paged `read` object whose records retain recorder source and live-conversation generation. The tab can project it
as an ordinary capability. When this browser is the recorder, turning retention off clears its rows and advances their
write epoch in one IndexedDB transaction; queued work from another tab cannot put an erased line back. A failed clear
leaves the switch on and reports the failure. A standalone peer can retain the same object beyond the tab. Capabilities
in Settings accepts its whole-archive sturdyref as the direct-message recorder and can remember that bearer when the
reader explicitly asks. History reads answer from every archive the member holds at once — this browser's store
beside a selected peer — coalesced by recorder coordinates with each account's keeper named at its own divider
([ADR-0144](../../docs/decisions/adr/ADR-0144-combined-archive-views.md)); an unreachable peer refuses writes without
hiding what this browser already kept. A direct conversation's details can narrow the selected recorder to a read-only account of that
line and offer it to the other member. The receiver reads it only by choice, or gives it back unread.

### Running a durable user session

A durable session peer owns one user's intended Rooms workspace. Attach from the
browser to its administrator sturdyref. The native `rooms-session` process
answers the whole attached-view contract: snapshot and watch, workspace
adoption and checkpoint replacement, grant administration, checkpoint commands,
live room and direct-message effects including files and refiling, typing,
history and archived-attachment reads, archive shares issued and received,
managed-room results and their resumption, operator and operations inspection
and mutation, and narrower delegated facets. It reconnects the committed
directories, sits in the committed public and managed rooms, opens direct
conversations as they are needed, records kept history into a session-owned
archive, and reports what it could not reach as issues in the snapshot. An
attached view sees exactly what the authority it attached through allows,
re-read on every call: narrowing or revoking a grant reaches the views already
holding it, and a grant without the history right cannot read the archive. A
visualizer credential the endpoint refuses shows that refusal in the operations
snapshot rather than retrying forever:

```sh
zig build rooms-session -- --state=.local/.state/rooms
```

After its durable state, grants, listener, and administrator publication are ready, the native process prints `ROOMS-SESSION-LISTENING` and by default writes the same administrator sturdyref to
`admin.sturdyref` in that state directory. `--readiness-file` can put this generated process fact on ephemeral runtime
storage instead, as the Compose deployment does. The mode-0600 file is removed on an orderly stop and before every
restart; while the process is running, its presence is the readiness fact, and `rooms-session --check-ready=<path>`
reads it back as the deployment's healthcheck. An unreachable saved directory remains
visible for repair and retry; it does not prevent the owner from attaching. It is a generated mirror of the durable Host
identity and publication—not another source of authority. The sturdyref grants complete session administration. Give it
only to the owner; use a narrower facet when another person should merely observe or interact.

In the browser, **Attach** takes up the workspace the peer owns; a revision-zero peer adopts that browser's current
workspace. The control does not start a process. The deployment stack starts one session peer and prints its capability
through `./up.sh`; an account-backed site would need a separate bounded provisioning and recovery authority rather than
a public session-root endpoint. **Share** on a local session is the tab-lifetime sibling: this browser hosts the actor
until the tab closes or reloads. Join a room on this page's directory first, then Share. Other browsers Attach from
Holdings, including from a different Rooms page: the capability names this directory so they can reach it without the
hosting tab joining theirs. Reloading the tab ends sharing.

A password the member answered a bridge form with is kept in `bridge-secrets.json` in that directory, never in the
checkpoint, a snapshot to an attached view, or an export. The peer writes it before the checkpoint that records the
answer, so a restart replays the bridged identity without asking again. It keeps that credential only while a room in
the checkpoint still holds an intent that needed one: leaving the last room on that network, or submitting the form
again with the password field empty, removes it. A workspace adopted from a browser carries the intent without the
password, because the browser never had custody of it, and that room asks the member to answer the bridge once more.
The file is plain JSON under the directory's own permissions, not an encrypted store: anyone who can read the directory
can already act as the session from the identity seed beside it.

Only one process may hold the state directory. Stop it before copying the directory for backup, and restore the
directory as a unit. The checkpoint, effect ledger, bridge credentials, session-owned archive, Host identity, and
publication entropy are one custody boundary; copying only `session.json` does not preserve it.

### Running the native room server

The native room server is the directory members register with and the rooms they enter. It files names, tells
watchers who is registered and which rooms are listed, relays introductions and direct-route requests between
members, and carries WebRTC signaling between them. It opens rooms, seats members, delivers lines, topics, presence,
typing, and invitations, derives room links, managers, and stewards from its room-state document, hosts files under
the room and host budgets, and retains history in a file journal. It needs one state directory, where it keeps
`rooms.json`, the same server document the TypeScript server keeps, and takes its Host identity from that document's
seed:

```sh
zig build rooms-server -- --state=.local/rooms --history
```

Without `--state` the server is process-local: a fresh identity each start and nothing kept past it. To build it
separately, run `zig build rooms-server-build`; `zig-out/bin/rooms-server` uses the companion library in
`zig-out/lib`. The process prints `ROOMS-SERVER-LISTENING` followed by the address members dial, the bare port for a
loopback TCP room and the complete locator otherwise, and answers `directory` there. Options use `--name=value` and
may also come from the `GLOWCAP_ROOMS_*` environment variables the TypeScript server reads; unknown or repeated
options are refused. `--history` keeps listed rooms' recent lines in the `history` directory under `--storage=<dir>`
or the state directory, and in memory when there is neither. A PostgreSQL URL selects the database backend described
above. The transport options are the archive peer's: discovery-backed iroh by
default, `--reachability=direct` for a self-contained same-host run, and `--transport=tcp --port=0` for cleartext
loopback inspection, with `--bind` and `--announce-host` for a LAN. SIGINT and SIGTERM close the listener, end every
accepted connection, and release state custody. Only one process may use a state directory at once.

All three native peers also accept `--transport=onion`. Supply a running Tor's
endpoints through `GLOWCAP_ONION_SOCKS` and `GLOWCAP_ONION_CONTROL`, or
`--onion-socks=<endpoint>` and `--onion-control=<endpoint>`. Endpoints may be
absolute Unix socket paths or host/port pairs; the control endpoint must accept
unauthenticated local control. The peers start no Tor themselves. With onion,
`--port` selects the loopback port Tor forwards to; zero chooses one.
`--onion-forward=<absolute-path> --port=0` selects a Unix forwarding socket.
Each state
directory keeps `onion-key` before readiness and restores it unchanged on restart.
An unusable saved key refuses startup. A room server without a state directory
creates a fresh onion service each run.

The operator capability flags are `--admin-listeners`, `--diagnostics`,
`--operator`, `--peering`, `--irc`, and `--viz`, or their `GLOWCAP_ROOMS_*` environment twins. Each mints a swiss number
the state directory keeps, and the boot block prints its `ROOMS-*` token line; under a supervisor only the token
lines print. `--viz` binds the live timeline endpoint on loopback at `--viz-port` (default 9300, `0` for any) and
prints `ROOMS-VIZ-LISTENING` followed by the sturdyref that admits its sockets.
`rooms-server --capabilities=<state-directory>` reads the kept token lines without
starting a server; `--capabilities` uses `GLOWCAP_ROOMS_STATE`. It can read while
the server owns that directory. Missing capabilities are identified, while unreadable
or malformed state fails the command without a partial handoff. Kept tokens do not
by themselves show which capabilities the current server has enabled.

The native `--irc` gateway currently supports network and channel leases,
subscriptions, posting, member identity changes, durable moderators and one-shot
observer/participant invitations. Its operator inventories include IRC rooms,
stewards and membership inboxes, with reference release, bulk retirement and
room reset. Diagnostics include IRC rooms and occupants without exposing their
authority tokens; the timeline follows membership annotations. Pending public
names remain reserved during durable writes. Replacing a subscriber retains its
IRC channel lease while retiring the old capability. Failed identity changes
restore through surviving channels and cannot alter a newly joined identity.
TLS/SASL and pressure coverage remain part of final migration verification.

The web front starts the installed Rust server by default and forwards the
operator flags it was given, including `--irc`. `GLOWCAP_ROOMS_SERVER_BIN` can
name another native executable. The `zig build rooms-web*` launch steps build
their native server first; direct `deno run` use requires `zig build
rooms-server-build` beforehand. Onion selections pass the supervised Tor endpoints
and local forward port to the native server.

### Running a member archive peer

The archive peer is a native Rust executable and needs one state directory. It keeps its Host identity, archive authority, and retained revision log
together there:

```sh
zig build rooms-archive -- --state=.local/member-archive
```

This command builds and runs the service without Deno. To build it separately,
run `zig build rooms-archive-build`; `zig-out/bin/rooms-archive` uses the companion
library in `zig-out/lib`. Keep those directories together when moving the build.
SIGINT and SIGTERM drain admitted archive work before releasing state custody.
Options use `--name=value`; unknown or repeated options are refused.

The ordinary transport is discovery-backed iroh, so the sturdyref's bare node ID stays dialable when endpoint addresses
change across restart. The process prints `ROOMS-ARCHIVE-LISTENING` followed by that complete sturdyref. It is bearer
authority to read and write the whole archive, so protect it like the history itself. A self-contained same-host run can
add `--reachability=direct`. For local inspection only, `--transport=tcp --port=0` uses cleartext loopback TCP.

To use the peer, open the Holdings tab in Settings, choose **Use an archive peer…**, and paste the printed sturdyref under
**Archive peer capability**. Leave **Remember this archive peer in this browser** clear for a page-lifetime selection.
If a selected or remembered peer is unavailable, Rooms says so and declines archive writes; it does not conceal a second
history in the browser store. **Use this browser** returns later reads and writes to IndexedDB and forgets any
remembered peer. Changing targets does not copy earlier history. New writes select the new target immediately, while
writes already admitted to the old target drain there. A displayed archived file keeps its source peer available until
that file occurrence leaves the conversation, so a lazy read never retargets its bytes. Read and write failures enter
the page's bounded trouble journal rather than appearing as empty history. Turning history off stops remote writes but
cannot erase records already held by a peer whose capability has no erase verb.

Only one process may use a state directory at once. A second process refuses without waiting, while a crashed process
leaves no stale lock to clear. Startup also refuses a corrupt complete log row. It recovers only an unterminated final
append, which is the boundary a crash can tear. Stop the peer before copying the directory for backup, and restore the
directory as one unit. The archive keeps at most 5,000 current records and bounds its revision log and file size; it is
durable custody, not an unbounded backup.

History is scoped state, and every scope has a natural owner. The server keeps a room's lines because the room is the
server's; a reader keeps a direct line's history because only their browser ever sees its plaintext; a directory-wide
archive would be an operator statement about every room at once. Sharing is capability handoff like everything else here
— a member who wants to hand their view of a conversation to somebody hands a reference that answers reads, the same
gesture as handing a room or a line. The storage seam, passable object, standalone peer, whole-archive selection,
read-only direct-line handover, and bounded attachment storage ship. Room and standing facets, independently revocable
or durable offers, and a storage operations pane remain separate work. Archive files are content-addressed and fetched
through scoped capabilities; a metadata-only record says when no bytes were retained. None of that changes what a kept
line is.

## Moderation

Moderation follows the capability model rather than adding ranks. Reading is the reader's: `/ignore` silences somebody
in this window only, and no server learns of it. Creating a room through the Rooms-only managed-open operation also
returns a durable room-manager capability. Possession of that capability authorizes creation, recovery, and exact
revocation of the room's durable entry-link and moderator generations. It grants neither entry nor moderation itself,
and its durable behavior retains only the room's opaque durable identity—not the live room—so a manager cannot keep an
empty room resident.

The manager and moderator sturdyrefs are independently passable. Sharing a manager delegates management. Discarding a
local occurrence changes no other copy; if every copy is discarded or lost, the directory operator is required to
recover one. A manager issues the moderator capability explicitly from room details or `/moderator`. The details card
separates possession from operations: member-removal controls appear only while this session holds the moderator
reference. Another holder can take it with `/moderator <sturdyref>`, and the client checks that either capability
governs this exact room before retaining it. Restart restores current publications without granting them to the first
member back. `/kick` and the card's confirmed action ask a member out through the held moderator: the member hears the
ask directly, the room reads why the leave that follows happened, and no ban is minted, so the person can walk straight
back in. A ban needs an identity to hold against a name, and a nick is not one.

`--operator` (or `GLOWCAP_ROOMS_OPERATOR=1`) mints the separate `ROOMS-OPERATOR` capability. It is the recovery root for
management and moderation on every local room this server owns, including private rooms by opaque durable identity.
Active IRC bridges also appear, but their bridge source issues and revokes their moderator capability. Peered rooms
remain with their remote source and do not appear. A live native room exposes a stable, non-bearer
management identity that lets the operator recover the exact manager without learning or accepting a display label as
authority. Two recoveries of the same manager at once join one operation and receive its one result; the second never
re-enters the Host to mint a rival. The operator also lists moderator inventory, gives an unissued moderator or recovers the current one, and
revokes exact room-link, manager, or moderator generations. It cannot enter or kick by implication: the recovered
room-scoped capabilities remain the authorities that perform those acts.

Revocation rotates the durable generation. Every old sturdyref and every reference already enlivened from one refuses
immediately; a later issue mints a different sturdyref. The Operator pane at `/ops/operator` keeps this in its own Room
moderator authority section, exposes the current capability for copying, and puts the full invalidation warning in a
second confirmation step before Revoke. The operator swiss is therefore strong deployment authority: keep it with the
people or automation entrusted to recover and revoke every local room's stewardship.

The same page inventories room links, exact nickname claims, peer sessions, room-shaped owners, application-retained
reference occurrences, and the bounded trouble journal. A nickname row names the session holding it, and the sessions
list includes the connection this operator view itself reads the directory through, marked "yours", so a claim held by
the asking session resolves to a visible row instead of reading like a leak. That own row offers no disconnect, and the
server refuses one asked another way. Every destructive row names its scope before acting. A revoked
room link prevents new entry through copied or already-enlivened references. A membership already subscribed through
that reference remains live until it leaves and can use its held manager to create a replacement. Reissue advances the
durable generation and returns an unrelated sturdyref; moderator authority minted with it advances with the room and
cannot revive an old copy. A reference release updates only this server's owning aggregate and cannot revoke a remote
copy. Runtime and factory reset acknowledge existing trouble first, so a cleanup failure caused by the reset remains
visible. Operator watches are admitted only after their first revision callback is delivered; a failed callback cannot
occupy the bounded watcher table.

## Operations capabilities

Swiss numbers persist under `GLOWCAP_ROOMS_STATE`, one file per capability, and
`zig build rooms-server -- --capabilities=<state-directory>` prints the token lines for whatever that directory
holds, the same lines the boot block prints and readable any time after startup.

The same state directory contains `operations.json`. It records listener options, retained IRC network configurations,
and their channel leases. Startup restores network authority before replaying its channels. Taking a listener down,
parting a channel, or closing a network commits the durable change before retiring its live resource. Controlled
shutdown closes enacted resources without deleting the intent the next process restores.

Start the web UI with `--diagnostics` (or `-Ddiagnostics` on the zig step) and the room server publishes a second Host
object under an unguessable swiss number — the same kind of bootstrap name as `directory`, not a page flag. The process
prints that swiss number. `--admin-listeners` (or `-Dadmin-listeners`) publishes a listener-admin object the same way,
and its swiss number prints beside the first.

`--peering` (or `-Dpeering`) publishes the authority to list durable rooms from another directory. `ROOMS-PEERING`
prints its swiss number. A successful `publishDurableRoom` returns a lease whose `ready` answer marks the foreign
listing live and whose `revoke` removes that exact generation from discovery. The listing belongs to the publisher's
destination session: disconnecting that session removes every listing it owns. Merely releasing a lease leaves its
listing until that disconnect, while capabilities already handed to readers survive either kind of discovery removal.

`--operator` (or `-Doperator`) publishes the stewardship recovery and revocation authority described above.
`ROOMS-OPERATOR` prints its swiss number; its Operator pane inventories every local room-moderation capability and never
performs moderation directly.

The visualizer capability: `--viz` (or `-Dviz`) serves the timeline endpoint and mints the capability described above,
the same enabling shape as the others.

Under Holdings in Settings, each operations capability has its own toggle, and the toggle is the capability: flipping one on opens
a form asking for its swiss number, and only a successful take lands the toggle on — dismissing the form leaves it off.
Listeners, diagnostics, IRC, operator, and peering accept the bare swiss printed by the directory and fetch it on that
live directory session. They reject a sturdyref rather than stripping its locator and silently retargeting its swiss
onto the current Host. The visualizer swiss is presented to the timeline endpoint, whose admission answer is the take.
The form can also remember the swiss number on that device, opt-in and per home (the directory for session capabilities,
the endpoint URL for the visualizer), so a reload takes the capability again unasked; turning the toggle off, or a
failed re-take, erases what was remembered. While any capability is held, an Operations control leads the switches on
the Settings title line and stands the reader on the Operations page: one address per pane under `/ops`, behind
responsive navigation once two or more are held, with the rooms rail and Settings still in reach and possession gating
an address arrived at cold. Inspect and operator fill one pane, the directory, because they are two authorities over one
subject: a tab holding only inspect reads what the directory holds, and taking operator turns the same address into the
inventories that can retire each of those rows. The older `/ops/diagnostics` and `/ops/operator` addresses still answer,
landing on that pane.

Inspect lists the names this directory currently holds (rooms, occupants, registrations, durable links), but says only
that a durable link publication is active: its swiss is bearer authority and is not observation. The directory pane
shows two trouble journals: the server's own bounded ring of failures that had no caller left to reach, served as
`trouble` rows on the same snapshot, and the page's ring of its console-only failures, drawn in a This-page well under
it. The operator's own inventories name how many rows each holds, and its retained references stand grouped by kind —
memberships, direct lines, uploads, peered rooms, registrations, inboxes, signaling — so a kind with nothing in it takes
no room on the page.

One search sits above those inventories and narrows all of them at once. The directory does the matching, so the counts
beside each section are what it holds rather than what this tab has read: a page is thirty-two rows whether the
directory holds thirty or three hundred thousand. Every word of the search has to appear somewhere in a row, in any
field and in any order, so `alice plans` finds Alice's rows about the plans room without knowing which column either
sits in. While a search matches, each inventory that can retire a row one at a time also offers to retire every row
matching it. That act asks first, naming the count and what retiring costs, then runs in batches: the directory takes a
bounded number per call and answers how many still match, so the number falls where the operator can watch it and
**Stop** ends the sweep between batches rather than cancelling something already gone. The listeners pane draws one
switch per transport the server itself lists, each described in the owning provider package's words: on brings that
listener up, off takes it down, and a row that is up carries its copyable locator. A row that is down draws one field
per knob its `up` accepts — the tcp family's bind host, port, and advertised host, the relay family's relay (prefilled
with this page's own) — and a blank field means the default the server's own hint names. The listener serving this very
page is marked and its switch is disabled, a seat the server already knows cannot come up stands disabled with its
reason, and a flip the server cannot honor answers with its reason in words, in the row that asked. The peering pane
publishes a room this tab has joined on another directory into this one, durably: pick the room, name it, and it lists
beside the local rooms until revoked. The rows under the form are this tab's own publications, each with the one
revocation its lease carries; a tab holding no other directory is told to join one first. The visualizer pane names the
endpoint this session publishes to, whether the socket is up, and the endpoint's own sentence when that swiss is dead,
and holds the endpoint override (blank publishes to this page's own `/viz`; saving reloads the window). A local tab is
the producer; a shared session publishes from the session process. The peering form says the room stays at its source and
the listing lasts until explicit revoke or this directory connection ends. Help, from the icon in the Settings header,
says what a swiss number is. Turning a toggle off drops that capability, and a reconnect drops the session-fetched
capabilities the same way; the visualizer capability lives on the endpoint socket and survives a directory reconnect. A
respawn of the same `GLOWCAP_ROOMS_STATE` republishes the same swiss numbers, so the printed names keep answering.

```sh
zig build rooms-web -Ddiagnostics
zig build rooms-web-iroh -Ddiagnostics -Dadmin-listeners -Doperator -Dviz
zig build rooms-web-tcp -Dadmin-listeners
```

Without a swiss number, fetch fails the way any unknown bootstrap name fails. The directory itself grows neither an
inspect nor a listeners method.

Attach mode is the one caveat: if an orphaned room server already holds the room port, the web server attaches to it
instead of spawning its own child, and tracing follows however that orphan was started. `--diagnostics` in that case
does not print a swiss number from this supervisor's empty state directory — it would name a capability nothing on the
attached server answers. Kill stray servers first when the `ROOMS-VIZ-LISTENING` line doesn't appear.

`GLOWCAP_ROOMS_VIZ_PORT=0` takes whatever port is free, and the announce line names the one it bound. A browser tab
cannot find an endpoint chosen that way, because the port is picked inside the room server and the page is served by
another process. Keep a fixed port when you want members' direct messages on the timeline, or open the page with
`?viz=ws://127.0.0.1:<port>/` (the same override the Visualizer pane holds once the capability is taken) — and in every
case a local tab publishes only while its "Protocol visualizer" toggle holds the viz swiss, while a shared session
publishes from the session process.
