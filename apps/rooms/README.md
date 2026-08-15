# Rooms

Rooms is a small chat application built on pancake. Open a room, invite a few
people, and exchange messages in a browser or terminal. The same room can hold
clients written in Zig, Rust, Python, Racket, and TypeScript.

The browser is the quickest way in:

```sh
zig build rooms-web-iroh
```

That serves the UI and carries the rooms over [iroh](https://www.iroh.computer/)'s
encrypted QUIC, so it needs `cargo` for the transport sidecar alongside Deno.
There is a cleartext `zig build rooms-web-tcp` that needs only Deno; it proves
nothing about who is on the other end, so keep it for a peer that speaks nothing
else.

Open `http://localhost:8000`, choose a room and nickname, then open another tab.
The join card also accepts another directory's OCapN locator, so the page can hold
rooms on several directories at once and join a room owned by any iroh peer its
relay can reach. Once it holds more than one, every room in the rail says which
directory it is on, and that line opens what is known about that directory. Cleartext TCP remains pinned to the page's own directory unless the relay
operator explicitly allow-lists another peer.
Entering a room that does not exist creates it. The page also supports direct
messages, live room and member lists, light Markdown with fenced code blocks,
`/me` actions, changing or taking back a message you posted, a room topic anyone in the room can set,
stepping away with a reason, quiet notices that never ping, mentions,
notifications, inline completion (`@` members, `#`
rooms, `:` emoji, `/` commands), file and image posting,
and mobile layouts. Attach a file with the paperclip, by dropping it on the
conversation, or by pasting one; pictures appear in the line and everything
else arrives as a row you can download from. Files work in rooms and direct
messages. Several files sent together stay together in one message bubble,
while each file keeps its own transfer and download state. Settings holds this
directory's address and the name it granted you, this browser's own locator,
light or syrup appearance, mention notifications, direct-message transport, and
the ocapnviz endpoint. Appearance and notifications apply at once; the others save by
reloading the tab. The same transport and
endpoint still work as `?dm=` /
`?viz=` on the address for tests and shared links. Rooms and messages are held in
memory: an empty room is removed, and restarting the server loses its history.
A posted file is held by the room, so it outlives the tab that posted it, and
the room drops its oldest file to stay under a fixed ceiling. A direct file
comes from its sender over the direct session instead, with no room in its path.

For the automated cross-language tour, run:

```sh
zig build demo-rooms
```

The demo starts a server, joins every available language client to one room, and
checks that each member receives every message. Deno and the Zig client are
required. Python, Racket, and Rust join when `python3`, `racket`, or `cargo` is
on `PATH`; missing optional runtimes are reported and skipped.

## Why it is a capability application

The server publishes one starting object: a directory. Asking the directory to
open or enter a room returns the room itself as a live reference. Holding that
reference is what lets a client use the room.

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

Nicknames are claims granted by a room, not durable identities. A claim lasts
until that member leaves. Direct conversations therefore follow the
introduction that created them, never a nickname that another person might use
later.

The directory can also introduce two members. They redeem that introduction
into a direct connection, so later messages do not pass through the room:

```text
Alice ──asks room for Bob──▶ room
Alice ◀──introduction────── room
Alice ═════ direct ═══════▶ Bob
```

This three-party handoff is a central OCapN feature. The browser turns it into a
click: select a member, then keep chatting even after either person leaves the
room. A browser tab or native process can also open a new direct line through
relay rendezvous. The published locator carries its relay route, so the dialer
need not use the same deployment fallback. In the browser, pick **Through the room relay** in Settings (or open with `?dm=relay`) so a native rooms-peer can
introduce you.

## Other ways to run it

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

When `cargo` is out of reach, the same UI and the same demo run over cleartext
TCP:

```sh
zig build rooms-web-tcp
zig build demo-rooms
```

Nothing on that path proves who the peer is or hides what you say, so it is for
local development and for reaching a peer that speaks nothing else.

To watch the iroh room and its direct messages on the live timeline, set a fixed
viz port when you start the browser UI. The supervised room server inherits that
environment and prints a `ROOMS-VIZ-LISTENING` sturdyref. Give that capability
to the [ocapnviz](../ocapnviz/) viewer in Live mode:

```sh
ROOMS_VIZ_PORT=9300 zig build rooms-web-iroh
```

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
needs internet access and is intentionally opt-in.

For a terminal conversation, start the server:

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

A room is not limited to pancake peers. A
[Spritely Goblins](https://spritely.institute/goblins/) vat can sit in the same
room and chat, on its own wire profile:

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
they publish. `goblins-rooms-dm` covers a native pancake member; the iroh run
currently covers the browser-to-vat direction.

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
