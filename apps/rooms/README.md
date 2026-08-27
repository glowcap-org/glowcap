# Rooms

Rooms is a small chat application built on pancake. Open a room, invite a few
people, and exchange messages in a browser or terminal. The same room can hold
clients written in Zig, Rust, Python, Racket, and TypeScript.

The browser is the quickest way in:

```sh
zig build rooms-web
```

That serves the UI and carries the rooms over [iroh](https://www.iroh.computer/)'s
encrypted QUIC, so it needs `cargo` for the transport sidecar alongside Deno.
There is a cleartext `zig build rooms-web-tcp` that needs only Deno; it proves
nothing about who is on the other end, so keep it for a peer that speaks nothing
else.

Open `http://localhost:8000`, pick a room and a nickname, then open another tab.
When the process runs on another machine or in a remote workspace, forward that
port and keep the browser URL on `localhost`; a shared browser origin needs
HTTPS. The [development guide](developing.md#serving-on-a-lan) gives both paths.
The join card also accepts another directory's OCapN locator, so one page can
hold rooms on several directories. A room's Capabilities card can create its
durable bearer link. Paste that sturdyref into the join card or `/join` to open
the exact room it names. The server authors the whole link from its durable
room authority and the routes it advertises to this connection, so a link can
follow the same server across a restart and changed network hints. Anyone who
has it can enter and pass it on. `/link` remains the terminal form: with no
argument it links the current room, while `/link lobby` links a listed room.
Entering a room that does not exist creates it. You can post messages, direct
messages, and files. Without `--history`, rooms and messages live in memory and
restarting the server drops them; the retention section below covers keeping
them.

[Developing and operating Rooms](developing.md) covers the rail, Settings,
operator capabilities (`--diagnostics`, `--admin-listeners`, `--viz`,
`--operator`, `--peering`, `--irc`), and the rest of the UI.

For the automated cross-language tour, run:

```sh
zig build demo-rooms
```

The demo starts a server, joins every available language client to one room, and
checks that each member receives every message. Deno and the Zig client are
required. Python, Racket, and Rust join when `python3`, `racket`, or `cargo` is
on `PATH`; missing optional runtimes are reported and skipped.

## Durable workspaces

A local browser owns one reconstructible workspace. For the same workspace and
network identity in several browsers, run a durable session peer:

```sh
zig build rooms-session -- --state=.local/rooms-session --transport=iroh
```

The command prints one session-administration sturdyref. Attach it from the
Data tab in Settings. On the first attachment to a newly created session,
the admin capability transfers that browser's complete workspace once. The
session records that transition explicitly; an intentionally empty or imported
checkpoint is still established and will not later be replaced merely because
it looks new. The durable peer then owns the intended workspace.
That state includes joined directories and rooms, requested nickname claims,
direct conversations, drafts, selection, room links, moderation authority,
peering intent, history policy, and explicitly retained operations and archive
capabilities. Each
browser remains a view of that authority, so refreshing or opening another
profile reconstructs the same workspace without repeating network effects in
every tab.

Session administration can issue separate observe, interact, and admin
sturdyrefs. Observe is read-only. Interact can use ordinary room and workspace
actions without seeing or replacing retained administration bearers. Admin can
manage those bearers, import or reset the checkpoint, and issue or revoke other
session grants. The sturdyref is the authority; Rooms does not consult an
ambient account role. Revocation stops live references and survives a session
peer restart.

The browser reconnects to the same durable peer after transport loss. Initial
attachment requires a complete session snapshot from a still-live connection,
and callbacks from a retired connection cannot overwrite its replacement. The
session checkpoint remains intended state while bounded live views and issue
rows report what has reconnected or been refused. See
[ADR-0134](../../docs/decisions/adr/ADR-0134-shared-rooms-session-capability.md)
and [ADR-0137](../../docs/decisions/adr/ADR-0137-durable-rooms-session-grants.md)
for the capability and persistence contracts.

## Why it is a capability application

The server publishes one starting object: a directory. Asking the directory to
open or enter a room returns the room itself as a live reference. Holding that
reference is what lets a client use the room. An operator can also start the
server with `--diagnostics`, which publishes a second Host object under an
unguessable swiss number. Fetching that swiss number is the inspect capability.
The directory itself does not grow an inspect method. `--admin-listeners`
publishes a third object the same way. Holding its swiss number is the
authority to list the server's live listeners, bring one up on a transport this
process can realize, and take one down. The listener whose locator the server
announced carries the web relay and refuses with words. No flag, no object:
neither capability exists unless the process was started with it.

Messages flow in the other direction the same way. A member gives the room a
reference to its inbox. When someone posts, the room calls each inbox; clients
do not poll a queue.

```text
directory ──open/enter──▶ room
room ──message──▶ member inbox
```

Posting files works the same way, one more object down. The composer keeps its
selected files local. Send asks the room for one upload reference per file,
publishes their single ordered message, then drives those references in
parallel. Holding one upload is the authority to fill that file, so nothing
has to name or re-authenticate the uploader. The room hands each member a blob
reference immediately; a read waits only when it reaches bytes still in flight.

```text
room ──upload/file──▶ member     (one independent pair per attached file)
room ──file reference──▶ member inbox
member ──read(offset)──▶ file
```

A direct message carries the same file reference after its text and optional
reply reference. The sender hosts that blob on the direct connection, and the
recipient pulls the same bounded chunks whether the connection uses WebRTC,
iroh, a relay, or TCP. The sender keeps a bounded set of unfetched direct files
and expires the oldest when that limit fills. Room uploads for one message run
in parallel after the room publishes it. Direct files are separate capabilities,
so the recipient can fetch them independently and concurrently without sending
them through a storage service first.

Nicknames are live directory claims, not durable identities. The directory
issues an opaque registration ID and requires it again for inbox
offers and introductions. Direct conversations retain that registration ID,
so a later holder of the same nickname cannot inherit the thread or its
history. The direct capability remains the authority; the registration ID only
prevents data keyed by a nickname from changing hands.

The connection that opens a room can claim its moderator capability from the
room's details card or with `/moderator`. Claiming publishes one durable capability, so
it happens only when asked. The card separates capabilities from operations: it
shows possession, accepts a shared moderator sturdyref, warns that the string is
bearer authority, and reveals the room's member-removal controls only while the
tab holds it. Give that string only to somebody you want to moderate the room;
`/moderator <sturdyref>` and the card take the same authority, while `/kick` and
the card's confirmed removal act use it. The client verifies that a shared
moderator capability belongs to the room in front of it before keeping it. A
server restart does not give the first member back moderation authority by accident: the existing
sturdyref is the way back. Removing a member asks them to leave but does not ban
them, because a nickname is not a durable identity.

A deployment that needs recovery and revocation can start with `--operator`.
That mints a separate server capability beside diagnostics and listener
administration. Holding it does not moderate a room; it lists, gives, and
revokes the room-scoped steward capabilities the server owns. Revoking rotates
the durable authority, so copied sturdyrefs and references already in use stop
governing together. Its inventories stand on the directory pane at
`/ops/directory`, where a Room moderator authority section asks for
confirmation before invalidating every old holder. One search over that pane
narrows every inventory at once, counted by the directory rather than by the
page, and each inventory can retire everything a search matches in bounded
batches the operator watches and can stop.
Peered and IRC-bridged rooms remain under their source's moderation.

The directory can also introduce two members. They redeem that introduction
into a direct connection, so later messages do not pass through the room:

```text
Alice ──asks room for Bob──▶ room
Alice ◀──introduction────── room
Alice ═════ direct ═══════▶ Bob
```

A server started with `--history` keeps each listed room's last lines and
answers them to members who join later, under a divider naming the room as
the keeper. Each room keeps at most 500 lines; the server keeps at most 4,096
lines across 256 rooms, dropping the least recently active whole-room tail at
that edge. Retention is that stated policy and nothing more: private rooms
never record; a file line keeps its caption but never its file bytes; and direct
messages go only to the member archive their reader selected, which is their
browser by default.
Where kept lines persist is `--storage`'s one destination — the state
directory's files by default, a managed database when the destination names
one. The browser store implements the separate member-owned archive capability:
bounded `put`, paged `read`, and monotonic `narrow` on one ordinary OCapN object, with an opaque
recorder source and live-conversation generation on every line. A separately
run archive peer hosts that same object behind a durable sturdyref. The
archive-peer card the Data tab in Settings opens lets the reader select that
peer for new history and optionally remember its bearer in this browser.
A peer that cannot be reached is
shown as unavailable and receives no silent browser-store fallback. A direct
conversation's details can hand its other member a read-only facet for exactly
that line. The recipient chooses whether to read it once or give it back, and
shared records stay under the sender's archive attribution.

A server started with `--peering` publishes a separate capability that can list
a durable room from another directory. Each foreign listing belongs to the
publisher's live destination session and has its own revocation lease: explicit
revocation or that session ending removes it from discovery, without revoking
room references already handed out. Releasing the lease alone gives up the
exact revocation authority and leaves the listing until the session ends. When
the source has several listeners, its durable room link uses
one identity route: key-proving iroh and Noise paths are preferred, with onion
or baseline sockets retained only as handoff fallbacks. Servers without the
flag publish no peering authority. The browser makes the capability a pane:
take it from the Capabilities toggles in Settings, and the Operations page at
`/ops` gains a Peering pane that publishes a room this tab has joined on
another directory and revokes what this tab published. The pane says that
dropping its capability without revoking leaves those listings until the
directory connection ends.

This three-party handoff is a central OCapN feature. The browser turns it into a
click: select a member, then keep chatting even after either person leaves the
room. A browser tab or native process can also open a new direct line through
relay rendezvous. The published locator carries its relay route, so the dialer
need not use the same deployment fallback. Browser-to-browser WebRTC uses
Cloudflare's public STUN service by default so peers on different ordinary NATs
can discover a direct path. `PANCAKE_ROOMS_ICE_SERVERS=""` disables outside ICE
infrastructure, and a comma-separated STUN list selects another discovery
service. A deployment may also configure a server-side TURN credential issuer;
Rooms gives each new WebRTC connection short-lived relay credentials without
publishing the issuer token. STUN sees only the address it discovers. TURN sees
timing and volume when ICE cannot find a direct pair, but WebRTC's DTLS channel
keeps the DM bytes encrypted. **Through the room relay** in Settings (or
`?dm=relay`) is a distinct `noise-relay` transport. The room relay makes the
browser server-reachable while Noise keeps the DM encrypted end to end,
including when a native rooms-peer introduces the browser.

## Other ways to run it

An IRC channel can be read as an ordinary Rooms room, and an ordinary IRC
client can enter rooms that already exist on a native directory:

```sh
zig build rooms-irc-bridge                                 # libera/#ocapn as a room
zig build rooms-irc-front -- --directory=127.0.0.1:9099    # IRC clients on :6667
```

IRC members appear as `irc/<nick>` on every front. The bridge stays read-only
until a registered nick opts into two-way mode, and each front connection
holds exactly the capabilities it acquired. The [IRC README](irc/README.md)
carries the full flag surface, the deployment postures, the bounds, and the
evidence, including the live Goblins compositions behind
`zig build goblins-rooms-irc`.

The cross-language tour has an iroh form too, and it needs `cargo` for the same
transport sidecar:

```sh
zig build demo-rooms-iroh
```

The standardized OCapN transport has its own live application proof. It starts
an explicit test Tor, hosts the real Rooms directory as an onion service, and
joins two independently driven peers:

```sh
zig build demo-rooms-onion
```

It needs `tor`, Deno, and outbound network access. pancake itself still starts
no daemon; the demo harness owns the Tor process and passes its endpoints into
the onion provider package.

It uses explicit address hints and does not contact public discovery services.

The browser UI can host its room the same way, as a Tor onion service:

```sh
zig build rooms-web-onion
```

It needs `tor` and Deno. The web supervisor starts a private Tor of its own, or
uses a running one when `PANCAKE_ONION_SOCKS` and `PANCAKE_ONION_CONTROL` name
its endpoints. The page prints an `ocapn://….onion` locator; give Tor some
seconds to publish it before a peer outside dials it, while this page's own
tabs reach the room at once. Set `PANCAKE_ROOMS_STATE` to keep the onion
address across restarts, since the service key lives in that directory.
[Developing and operating Rooms](developing.md) has the operating detail.

When `cargo` is out of reach, the same UI and the same demo run over cleartext
TCP:

```sh
zig build rooms-web-tcp
zig build demo-rooms
```

Nothing on that path proves who the peer is or hides what you say, so it is for
local development and for reaching a peer that speaks nothing else. That is
also true when you put the TCP room on your local network, which
[Developing and operating Rooms](developing.md) shows with the `--bind` and
`--announce-host` knobs: everyone on that network can read the conversation.

To watch the iroh room and its direct messages on the live timeline, turn the
visualizer on when you start the browser UI. The supervised room server serves
the timeline endpoint on port 9300 (`PANCAKE_ROOMS_VIZ_PORT` picks a different
one), mints the viz capability, and prints a `ROOMS-VIZ-LISTENING` sturdyref.
Give that capability to the [ocapnviz](../ocapnviz/) viewer in Live mode:

```sh
zig build rooms-web -Dviz
```

The endpoint refuses any socket that does not present that capability, reader
and writer alike; the sturdyref carries it, and the same swiss number prints as
a `ROOMS-VIZ` line beside the other operator capabilities. A browser tab
publishes its own sessions only while it holds that swiss, from the Protocol
visualizer toggle in Settings under Advanced.

Start the viewer with `cd apps/ocapnviz && bash dev.sh`. More detail is in
[Developing and operating Rooms](developing.md).

To watch the handoff without the UI:

```sh
zig build demo-rooms-dm
zig build demo-rooms-dm-iroh
```

The first uses loopback TCP and needs Deno. The second uses three iroh endpoints
and also needs Cargo. A separate
`zig build demo-rooms-dm-iroh-discovery` run exercises public n0 discovery; it
needs the public internet, so it is opt-in.

For a terminal conversation over iroh, the same encrypted path as the browser:

```sh
pancake app rooms-peer
```

[`docs/cli.md`](../../docs/cli.md) has the flags. The Deno client over loopback
TCP is the cleartext sibling of `rooms-web-tcp`:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/server/main.ts 9099
```

Then join from another terminal:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/clients/deno/chat.ts 127.0.0.1:9099 general alice
```

The interactive client supports `/list`, `/open`, `/enter`, and `/leave`.

A [Spritely Goblins](https://spritely.institute/goblins/) vat can sit in the
same room and chat, on its own wire profile:

```sh
racket -y conformance/goblins-peer/racket/rooms-chat.rkt \
  127.0.0.1:9099 general goblins-carol
```

Direct messages reach it too, and they are the same three-party handoff as
between two pancake members: the room introduces you, and the line then runs
between your browser and the vat with the room carrying none of it. Nothing in
Goblins was changed to allow that. Over iroh it needs no setup; over cleartext
TCP the browser's relay will not open a socket to an address a page named, so
name the vat to it when you start the server:

```sh
PANCAKE_RELAY_TCP_PEERS=127.0.0.1:9200 zig build rooms-web-tcp
racket -y conformance/goblins-peer/racket/rooms-chat.rkt \
  127.0.0.1:9099 general goblins-carol 9200
```

The trailing `9200` is the port the vat's own netlayer binds, which is the
address the browser dials to reach it.

The vat can answer anybody who messages it, and it can start a conversation of
its own with `/dm`. Which members that reaches depends on the locator snapshot
they publish. Both `goblins-rooms-dm` and `goblins-rooms-dm-iroh` cover the two
Goblins-facing directions: a browser redeems the vat's introduction, then the
vat redeems a native pancake member's introduction.

[Developing and operating Rooms](developing.md) walks through watching that
happen alongside the browser UI.

## Find your way around

- [`server/`](server/) hosts the directory and rooms.
- [`lib/`](lib/) contains the TypeScript protocol and shared client logic.
- [`clients/`](clients/) contains one terminal client per language.
- [`web/`](web/) contains the browser peer, byte relay, and deployment files.
- [`demos/`](demos/) and [`test/`](test/) drive the automated scenarios.

See [Developing and operating Rooms](developing.md) for attach mode, the main
test commands, browser relay boundaries, and one-shot client commands. See the
[deployment guide](web/deploy/README.md) to serve the browser UI behind a
reverse proxy.
