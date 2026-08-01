# Rooms

Rooms is a small chat application built on pancake. Open a room, invite a few
people, and exchange messages in a browser or terminal. The same room can hold
clients written in Zig, Rust, Python, Racket, and TypeScript.

The browser is the quickest way in:

```sh
zig build rooms-web
```

Open `http://localhost:8000`, choose a room and nickname, then open another tab.
Entering a room that does not exist creates it. The page also supports direct
messages, live room and member lists, light Markdown, mentions, notifications,
and mobile layouts. Rooms and messages are held in memory: an empty room is
removed, and restarting the server loses its history.

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
room. Two browser tabs on the same relay can also establish a new direct line
through relay rendezvous. Native-to-browser and cross-relay cold dialing are
not implemented.

## Other ways to run it

Use iroh instead of local TCP for encrypted QUIC and peer discovery:

```sh
zig build rooms-web-iroh
zig build demo-rooms-iroh
```

These commands need `cargo` for the iroh transport sidecar. The ordinary iroh
demo uses explicit address hints and does not contact public discovery
services.

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
