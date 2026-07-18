# rooms: a capability-secure chat, in five languages at once

This is a small, real application built on pancake actors. A server hosts a _directory_ of chat
rooms; people open a new room or enter an existing one, post lines, and see each other's in real
time. What makes it worth reading is _how_ the chat works, and that one room holds members written
in Zig, Rust, Python, Racket, and Deno at once, none aware of the others' languages.

A room is itself a capability: the directory's `open` and `enter` each hand back a live reference to
the room, and you talk to that reference. The directory also `list`s the rooms that have people in
them and lets a client `watch` for rooms opening, filling, and closing. A room exists only while
someone is in it; when its last member leaves, the room is removed and its name frees up.

A member is a capability too. The directory can `introduce` one member to another so the two message
each other **directly**, with the room out of the message path. That is the three-party handoff at
the heart of OCapN, and the [browser UI](#chat-in-it-from-your-browser) turns it into a click. So
the app has two halves: public rooms that broadcast, and direct messages that leave the server once
the introduction is made.

Run the whole thing with one command:

```sh
zig build demo-rooms
```

That starts a Deno-hosted server and joins one client per language into a single room over TCP; the
first client opens the room, the rest enter it. Each posts a line and waits to receive every
member's line back. When they all succeed you see a transcript per language and a final line
confirming every member saw every message.

The demo needs only `deno`, which hosts the room and runs the orchestrator, plus the Zig client that
`zig build` always builds. Python, Racket, and Rust each join only when their runtime (`python3`,
`racket`, `cargo`) is on PATH; the demo builds the Rust client itself when `cargo` is present, and
reports any skipped language rather than failing. It is a sibling of `zig build check`, not part of
the self-contained build check.

The demo binds an ephemeral port by default. To pin one, use `zig build
demo-rooms -Dport=9099`. To
point its clients at a room you already started (the fixed-port server below, or the web UI's room),
add attach mode: `zig build
demo-rooms -Dport=9099 -Dattach=true` joins your server instead of
spawning its own, and leaves it running when the demo ends. The room need not be empty: each client
asserts the all-to-all broadcast against the demo's own roster, so anyone already chatting shows up
in the transcripts but is never counted.

### Over an encrypted transport

The same cross-language room runs over [iroh](https://www.iroh.computer/)'s encrypted QUIC instead
of cleartext TCP:

```sh
zig build demo-rooms-iroh
```

The wire, behavior, and all-to-all proof are identical; only addressing differs. Instead of a
`host:port`, the server announces an `ocapn://<nodeid>.iroh?direct-addresses=…` URI (its
self-authenticating endpoint id plus dialable address hints), and every client dials that. Each
language reaches iroh through the optional `libpancake_net_transport_iroh` C ABI companion library
(the Rust sidecar behind [ADR-0055](../../../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)),
so this step needs `cargo` as well as `deno`. It too is a sibling of `zig build
check`. Discovery is
relay-less with explicit hints, a loopback/LAN story, not public-internet dialing.

### Direct messages by introduction

A room can introduce two members who then talk directly:

```sh
zig build demo-rooms-dm
```

Each member is a full peer: it listens on its own endpoint, publishes a small `dm` object on the
same CapTP session it uses to join, then `register`s its dialable locator with the directory. The
directory `fetch`es that `dm`, stamps the locator as the gift exporter location, and returns the
reference when another member sends `introduce(nick)`. The binding turns it into a signed
`desc:handoff-give`: the caller redeems by dialing the member directly and sends DMs over that
fresh connection, never through the room. The demo asserts all three: the introduction yields a
live capability, the target accepts a brand-new inbound connection (register does not dial the
member), and the room never carries the message. It runs over loopback TCP and needs only `deno`.

The same introduction runs over iroh's encrypted QUIC, cross-endpoint:

```sh
zig build demo-rooms-dm-iroh
```

Here the gift names the member's iroh node id **and its `direct-addresses`** (carried as signed
hints in the give's exporter location), so the caller redeems by dialing the member's endpoint
directly, the relay-less `Direct` posture, no discovery service. Three separate iroh endpoints
(room, member, caller) in one process prove the same three assertions; it needs `cargo` (the iroh
sidecar) and `deno`.

A variant names the member by **node id alone**, with no `direct-addresses`, and resolves the id
through n0 discovery (relays + DNS/pkarr):

```sh
zig build demo-rooms-dm-iroh-discovery
```

It reaches the real internet, so it is opt-in and never part of `zig build
check`; it needs `cargo`,
`deno`, and network access.

## Chat in it from your browser

The whole application runs in a browser too, the most complete way to watch it work. One command
serves it:

```sh
zig build rooms-web
```

That serves a page at `http://localhost:8000`. Open it, pick a room and a name, and you are
chatting; entering a room that does not exist yet opens it. Every tab joins as its own member, so
open a few, or chat from a tab while a terminal client or another language sits in the same room by
pointing them all at the same room name. To run the same page with its OCapN connections over iroh's
encrypted QUIC instead of TCP, use `zig build rooms-web-iroh`, which needs `cargo` for the iroh
sidecar. Both pin the HTTP port with `-Dport`.

To put the page on the public internet, [`deno/deploy/`](deno/deploy/README.md) serves it over iroh
from a small container that carries no build toolchain: just Deno, with the TypeScript source and
the prebuilt shared libraries mounted in at run time. It is built to sit behind an existing
Cloudflare tunnel on a shared Docker network.

### Direct messages, by introduction

The browser does what a broadcast room cannot: it messages one person privately and directly. Hover
a member in the roster and choose _Message_, or use the `+` beside _Direct messages_. Your tab asks
the room to introduce you, gets back a three-party handoff give, and redeems it by dialing that
person directly; from then on your messages travel straight to them, and the conversation's header
says so with a lock and the transport it runs over. This is the same capability that makes
`zig build demo-rooms-dm` pass, now something you can watch.

A handed capability does not depend on the room that handed it over, so the direct line outlives the
room: leave for another room, or watch the other person leave, and it keeps working. When the person
you are messaging disconnects, the conversation marks them offline and dims their dot; when they
return, your next message opens a fresh line. Each tab is itself a full, dialable member, so two
browsers can message each other this way, and a browser can message a terminal member that
registered itself the same way.

### What else the page does

The layout is a sidebar of rooms and direct messages, a conversation header, a left/right
chat-bubble stream (others on the left, you on the right), and a member pane. The sidebar's live
list of populated rooms is the directory's `watch` feed; click a room to join it, switching rooms in
the same tab without reconnecting. Messages carry light markdown (`**bold**`, `*italic*`,
`` `code` ``), clickable links, `:emoji:` shortcodes with a picker, `@mentions` that highlight and
can raise an opt-in desktop notification, and `/me` actions. On a keyboard, the composer sends on
Enter and adds a line on Shift+Enter; on a touch screen there is no Shift, so Return inserts a
newline and Send submits. The join form prefills your last nick and room so returning is one click,
it does not auto-rejoin. On a phone, use the menu (☰) or **Browse live rooms** before you join to
see the directory's live list. Day and "new messages" dividers mark each stream, a light or "syrup"
dark theme toggles and is remembered. The stream sticks to the newest message only while you are at
the bottom, and the tab title badges unread messages in the background. The member pane shows every
member the room knows, in any language, as online or recently offline. Names are unique while live,
ignoring case: the room grants one membership per nickname and frees the claim when the member
leaves.

### How a browser speaks OCapN

A browser cannot open a raw TCP or iroh connection, so `web.ts` sits in the middle. It serves the
page, and for each tab it holds two pancake identities at once: a connection to the room directory,
and a small listening member of the tab's own that others are introduced to. The browser only ever
talks WebSocket to `web.ts`; every capability exchange happens on the Deno side, exactly as for
every other client.

That WebSocket is a plaintext control channel between the browser and its bridge, not the OCapN
wire. So the page's "encrypted iroh QUIC" is about the bridge-to-peer hop, not the browser's hop to
`web.ts`, which stays on loopback in development and rides `wss://` when the page is served over
HTTPS.

```text
browser ──WebSocket──▶ web.ts ──OCapN──▶ rooms directory
                         └─────OCapN─────▶ another member, directly (after an introduction)
```

The command prints the room's locator, so you can join the same room from a terminal with `chat.ts`
(below). Underneath, `zig build rooms-web` runs
`deno run
--allow-ffi --allow-read --allow-net --allow-run
examples/apps/rooms/deno/web.ts`; run
that directly to pass your own arguments.

## Chat in it yourself, interactively

The demo's clients are one-shot: each posts a single line and exits, which is what an automated
check wants. To sit in the room and talk, run the server and the interactive client by hand, one
terminal per person.

First, in one terminal, start the server on a fixed port:

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/server.ts 9099
```

It prints `ROOMS-SERVER-LISTENING 9099`. Then open a terminal for each person and join a room with a
nickname. The first argument is the locator the server announced (`127.0.0.1:9099` for the TCP
server above, or the `ocapn://…` URI an `ROOMS_TRANSPORT=iroh` server prints), the second is the
room name (entering one that does not exist opens it):

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 general alice
```

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 general bob
```

Type a line and press enter to post it; lines from everyone else appear as they arrive, and room
announcements are prefixed with `*`. Press Ctrl-D to leave.

Lines that start with `/` are commands, not chat: `/list` shows the populated rooms, `/open <name>`
opens a new room and moves you into it, `/enter <name>` moves into an existing one, and `/leave`
leaves the current room. Switching happens on the same connection, so one terminal can wander
between rooms.

You can mix languages in the same room. The one-shot clients each take a room, a nickname, and a
single line to post, so you can drop one into a running room to say hello from another language. For
example, while `alice` and `bob` chat in `general`, each of the five languages can wave from its own
terminal:

```sh
python3 examples/apps/rooms/python/client.py 127.0.0.1:9099 general grace "hi from python" grace
racket examples/apps/rooms/racket/client.rkt 127.0.0.1:9099 general alan "hi from racket" alan
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/client.ts 127.0.0.1:9099 general ada "hi from deno" ada
cargo run --manifest-path examples/apps/rooms/rust/Cargo.toml -- \
  127.0.0.1:9099 general hopper "hi from rust" hopper
zig build rooms-client -- 127.0.0.1:9099 general turing "hi from zig" turing
```

The Rust client is its own small crate, so `cargo run` builds it on demand; `zig
build rooms-client`
builds the same native binary the demo uses and forwards everything after `--` to it.

Each one-shot client takes the same transport-neutral locator as its first argument, so one command
line joins a TCP or an iroh room; pass the URI the iroh server announced instead of `host:port`. The
trailing argument is the roster each client waits to hear from; passing just its own nickname means
"post and go," so it does not block on a full room.

## The idea: you call me, I call you back

A traditional chat client polls a server: "anything new? anything new?" This one never does. When a
client subscribes, it hands the room a _capability_, a live reference to its own `inbox` object. The
room keeps that capability, and whenever anyone posts, the room calls each member's inbox back
directly. The push is the room invoking an object it was handed, not a message on a queue someone
has to drain.

That one move is the whole object-capability story made concrete:

- **A room is a capability the directory returns.** The server publishes one bootstrap object, the
  `directory`. Sending it `open(name)` or `enter(name)` returns a live reference to a room, not a
  URL or a room id you look up again, but the room object itself. Holding that reference _is_ your
  access to the room. The directory's `list` and `watch` let a client _discover_ which rooms have
  people in them, but they return names and counts, not authority: you still `enter` to get the room
  capability before you can speak.
- **Authority travels as a reference.** The client publishes an `inbox` actor and passes a reference
  to it as an argument of `subscribe`. On the wire that is an ordinary OCapN reference argument; on
  the room's side it arrives as a far reference the room can eventual-send to. No URL, no auth
  token, no registry.
- **The capability is the identity.** The room's `post` method takes only the text. It does not take
  a "from" field, because the connection the post arrives on already tells the room which member is
  speaking. You cannot post as someone else, because you only hold your own capability.
- **A name is a room-granted claim.** `subscribe(nick, inbox)` is where the room decides whether the
  nickname is available. If it grants the claim, later `post(text)` calls speak as that member until
  the connection leaves or closes.
- **The room cannot tell the languages apart.** A Rust member and a Python member are the same shape
  on the wire. Interop is not a feature here; it is the absence of anything language-specific.

## Layout

```
examples/apps/rooms/
├── deno/                 the reference server, the browser bridge, the Deno client, and the shared library
│   ├── server.ts         the server (directory of rooms, multi-connection, capability callbacks, watchers, member introductions)
│   ├── web.ts            the browser UI bridge: public rooms and direct messages by introduction, over a per-tab WebSocket bridge (zig build rooms-web)
│   ├── chat.ts           the interactive terminal client (/open /enter /leave /list)
│   ├── client.ts         the one-shot demo client in Deno (lists rooms, then enters)
│   ├── lib/              the shared modules the entries and the other-language orchestrators import
│   │   ├── protocol.ts   the wire contract: directory verbs (open/enter/list/watch + register/introduce) + room verbs (subscribe/post/leave) + the member dm verb
│   │   ├── room_client.ts the Room client (the OCapN layer) in Deno, strict directory open/enter/list/watch
│   │   ├── enter_room.ts the CLI's friendly enter-or-open, composed from those strict verbs
│   │   ├── errors.ts     the room failure taxonomy: typed codes carried at the front of a break reason
│   │   ├── wire.ts       the browser-to-bridge WebSocket protocol as zod schemas (incl. the room-line presence shape)
│   │   └── locator.ts    the transport-neutral rooms locator
│   ├── ui/               the browser client: page.html + page.css + TypeScript modules (entered through main.ts, bundled to /page.js)
│   └── deploy/           serve the browser UI behind a Cloudflare tunnel from a small container (compose + Dockerfile)
├── python/room_client.py + client.py    the same, in Python
├── racket/room-client.rkt + client.rkt  the same, in Racket
├── rust/room.rs + client.rs             the same, in Rust (its own crate)
├── zig/client.zig        the same in native Zig, over the real TCP netlayer
├── demo.ts               the orchestrator `zig build demo-rooms` runs
├── dm_demo.ts            the direct-message-by-introduction orchestrator `zig build demo-rooms-dm` runs
├── dm_demo_iroh.ts       the same introduction over iroh, cross-endpoint, that `zig build demo-rooms-dm-iroh` runs
└── dm_demo_iroh_discovery.ts  the node-id-only variant `zig build demo-rooms-dm-iroh-discovery` runs
```

Each language has a `Room` client, the small layer that knows about OCapN (publish an inbox, hand
the room a capability to it, drive the vat), and a thin app on top of it. The app reads the same in
every language because each `Room` exposes its own runtime's native async-sequence shape: the room's
lines arrive as a stream you iterate, and a send is a value you await.

| Language | Receive the room's lines | Send |
| -------- | ----------------------------------------- | ---------------------- |
| Deno | `for await (const msg of room.messages)` | `await room.say(line)` |
| Python | `async for msg in room` | `await room.say(line)` |
| Rust | `while let Some(msg) = room.recv().await` | `room.say(line).await` |
| Racket | `(for ([msg (in-room room)]) …)` | `(room-say room line)` |

## The surface underneath

Each `Room` is built on the binding's application surface (`connect`, `fetch`, `spawn`, `send`,
`serve`), and that is the whole of the OCapN it touches:

```typescript
const session = await connect(tcpLocator(host, port));
session.serve().catch(() => {});
const directory = await session.fetch("directory");      // the directory, by name
const room = await session.send(directory, "enter", [name]); // a room capability back
const inbox = session.spawn((verb, args) => { … });      // our callback, a capability
await session.send(room, "subscribe", [nick, inbox]);    // hand it over
```

No export-position numbers, no manual flush, no hand-rolled receive loop; the `Room` wrapper is a
few dozen lines because the surface does the rest. The Zig client uses the same surface as
`driver.BlockingSession`, explicit about allocation and I/O.

## Where the rooms could go next

The directory's `register` and `introduce` handoff, shown above over TCP and iroh and in the browser
UI, already lets one member reach another directly. The next step is introducing whole rooms that
live on another server.

Nor does the server yet attenuate (a read-only room handle) or persist history. Attenuation and
revocation are shown end-to-end in the sibling [`tools`](../tools/) showcase, on the same capability
model: a read-only view is an actor that forwards only the safe verbs, and a revocable handle is a
forwarder you can sever. Wiring them into a room is a few lines and a good next exercise.
