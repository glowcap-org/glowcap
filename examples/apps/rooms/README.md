# rooms — a capability-secure chat, in five languages at once

This is a small, real application built on pancake actors. A server hosts a
_directory_ of chat rooms; people open a new room or enter an existing one, post
lines, and see each other's lines in real time. What makes it worth reading is
not the chat. It is _how_ the chat works, and that one room holds members
written in Zig, Rust, Python, Racket, and Deno at the same time, none of them
aware of the others' languages.

A room is itself a capability: the directory's `open` and `enter` each hand back
a live reference to the room, and you talk to that reference. The directory also
`list`s the rooms that have people in them and lets a client `watch` for rooms
opening, filling, and closing. A room exists only while someone is in it, when
its last member leaves, the room is removed and its name frees up.

Run the whole thing with one command:

```sh
zig build demo-rooms
```

That starts a Deno-hosted server and joins one client per language into a single
room over TCP, the first client to arrive opens the room, the rest enter it.
Each client posts a line and waits to receive every member's line back. When
they all succeed you will see a transcript per language and a final line saying
every member saw every message.

The only runtime the demo requires is `deno`, which hosts the room and runs the
orchestrator, plus the Zig client, which `zig build` always builds. Python,
Racket, and Rust each join only when their runtime (`python3`, `racket`,
`cargo`) is on PATH; the demo builds the Rust client itself when `cargo` is
present, and it reports any language it skipped rather than failing. So
`zig build demo-rooms` runs on whatever machine you have, with as many languages
as you have installed. It is a sibling of `zig build check`, not part of the
hermetic gate.

By default the demo binds an ephemeral port. To put the room on a port you chose
— one your container forwards, say — pin it with
`zig build demo-rooms -Dport=9099`. To point the demo's clients at a room you
already started yourself (the fixed-port server below, or the web UI's room),
add attach mode: `zig build demo-rooms -Dport=9099 -Dattach=true` joins your
server instead of spawning its own, and leaves it running when the demo ends.
The room does not need to be empty or quiet: each client asserts the all-to-all
broadcast against the demo's own member roster, so anyone already chatting in
the room shows up in the transcripts but is never counted.

### Over an encrypted transport

The same cross-language room runs over [iroh](https://www.iroh.computer/)'s
encrypted QUIC instead of cleartext TCP:

```sh
zig build demo-rooms-iroh
```

Nothing about the chat changes — the room's wire and behavior are identical, and
the all-to-all proof is the same. Only addressing differs: instead of a
`host:port`, the server announces an `ocapn://<nodeid>.iroh?direct-addresses=…`
URI (its self-authenticating endpoint id plus dialable address hints), and every
client dials that. Each language reaches iroh through the optional
`libpancake_net_transport_iroh` C ABI companion library (the Rust sidecar behind
[ADR-0055](../../../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), so
this step needs `cargo` as well as `deno`; a language still joins only when its
runtime is present. It is a sibling of `zig build check`, never part of the
hermetic gate. Discovery is relay-less with explicit hints — a loopback/LAN
story, not public-internet dialing.

### Direct messages by introduction

A room can do more than broadcast: it can _introduce_ two members who then talk
**directly**, with the room out of the message path. That is a three-party
handoff — the gifter side — dressed in the rooms protocol:

```sh
zig build demo-rooms-dm
```

Each member is a full peer: it listens on its own endpoint and exports a small
`dm` object, then `register`s its dialable locator with the directory. The
directory dials the member back, holds its `dm`, and — when another member sends
`introduce(nick)` — returns that reference. Because the reference lives on the
directory↔member connection, the binding **transparently** turns it into a
signed `desc:handoff-give`: the caller redeems it by dialing the member directly
and sends its DMs over that fresh connection, never through the room. The demo
asserts all three: the introduction yields a live capability, the target accepts
a brand-new inbound connection for the DM (distinct from the directory's
dial-back), and the room never carries the message. It runs over loopback TCP
and needs only `deno`.

The same introduction runs **over iroh's encrypted QUIC**, cross-endpoint:

```sh
zig build demo-rooms-dm-iroh
```

The gift the directory mints names the member's iroh node id **and its
`direct-addresses`** (carried as signed hints in the give's exporter location),
so the introduced caller redeems by dialing the member's endpoint directly, the
relay-less `Direct` posture, no discovery service. Three separate iroh endpoints
(room, member, caller) in one process prove the same three assertions; it needs
`cargo` (the iroh sidecar) and `deno`.

The same introduction, but with the gift naming the member by **node id alone**
(no `direct-addresses`), runs as an opt-in step that resolves the id through n0
discovery (relays + DNS/pkarr):

```sh
zig build demo-rooms-dm-iroh-discovery
```

It reaches the real internet, so it is opt-in and never part of `zig build check`;
it needs `cargo`, `deno`, and network access.

## Chat in it from your browser

The friendliest way in is a web UI:

```sh
deno run --allow-ffi --allow-read --allow-net --allow-run \
  examples/apps/rooms/deno/web.ts
```

That starts the server for you and serves a page at `http://localhost:8000`.
Open it, pick a room name and a nickname, and chat — entering a room that does
not exist yet opens it. Each browser tab joins as its own member, so open a few
— or chat from a tab while a terminal client or another language is in the same
room (point them all at the same room name). The page wears pancake's own
palette — cream paper, cocoa ink, an amber accent, a teal flourish: a room
sidebar on the left, a room header, a left/right chat-bubble stream (others
on the left with an avatar and name, you on the right, author-grouped with
timestamps), and a member pane on the right. A live list of the rooms with
people in them fills the sidebar, updating as they open and close (the
directory's `watch` feed): click one to fill the join field before you join,
or — once you are in — to hop into it, switching rooms in the same tab without
reconnecting; the `+` beside _Rooms_ opens or creates one by name. Messages
carry light markdown (`**bold**`, `*italic*`, `` `code` ``), clickable links,
`:emoji:` shortcodes and an emoji picker, `@mentions` (highlighted, with
opt-in desktop notifications when you are named), and `/me` actions; the
composer is a multi-line box (Enter sends, Shift+Enter adds a line). Day and
"new messages" dividers mark the stream, a light/"syrup" dark theme toggles and
is remembered, and your name and last room are restored on return. The stream
sticks to the newest message only while you are already at the bottom (otherwise
a "jump to latest" button appears), and the tab title carries an unread badge
while it is in the background. The page shows the room roster too: every member
the room knows about, including Zig, Rust, Python, Racket, Deno, and browser
members, appears as online or recently offline. Names are unique while they are
live, ignoring case: the room grants one membership per nickname and releases
that claim when the member leaves.

A browser cannot speak raw TCP/OCapN, so `web.ts` sits in the middle: it serves
the page, and for each tab it opens its own pancake membership in the room and
bridges the two over a WebSocket. The browser only ever talks WebSocket to
`web.ts`; the OCapN capability exchange — handing the room your inbox so it
calls you back — happens on the Deno side, exactly as it does for every other
client.

```text
browser ──WebSocket──▶ web.ts (a pancake member) ──TCP/OCapN──▶ rooms server
```

It also prints the server's port, so you can join the same room from a terminal
at the same time with `chat.ts` (below), pass the same room name. It serves on
port 8000 by default; pass a different one as the first argument.

## Chat in it yourself, interactively

The clients the demo runs are one-shot: each posts a single line and exits,
which is what an automated check wants. To actually sit in the room and talk,
run the server and the interactive client by hand, one terminal per person.

First, in one terminal, start the server on a fixed port:

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/server.ts 9099
```

It prints `ROOMS-SERVER-LISTENING 9099`. Then open a terminal for each person
and join a room with a nickname, the first argument is the locator the server
announced (`127.0.0.1:9099` for the TCP server above, or the `ocapn://…` URI an
`ROOMS_TRANSPORT=iroh` server prints), the second is the room name (entering one
that does not exist opens it):

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 general alice
```

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 general bob
```

Type a line and press enter to post it; lines from everyone else appear as they
arrive, and room announcements are prefixed with `*`. Press Ctrl-D to leave.

Lines that start with `/` are commands, not chat: `/list` shows the rooms with
people in them (kept live by the directory's `watch`), `/open <name>` opens a
new room and moves you into it, `/enter <name>` moves into an existing one, and
`/leave` leaves the current room. Switching happens on the same connection, so
one terminal can wander between rooms.

You can mix languages in the same room. The one-shot clients each take a room, a
nickname, and a single line to post, so you can drop one into a running room to
say hello from another language, for example, while `alice` and `bob` are
chatting in `general`, each of the five languages can wave from its own
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

The Rust client is its own small crate, so `cargo run` builds it on demand; the
Zig client runs through `zig build rooms-client`, which builds the same native
binary the demo uses and forwards everything after `--` to it.

Each one-shot client takes the same transport-neutral locator as its first
argument, so the same command line joins a TCP or an iroh room, pass the URI
the iroh server announced instead of `host:port`. The trailing argument is the
roster each one-shot client waits to hear from. Passing just its own nickname
means "post and go," so it does not block on a full room.

## The idea: you call me, I call you back

A traditional chat client polls a server: "anything new? anything new?" This one
never does. When a client subscribes, it hands the room a _capability_, a live
reference to its own `inbox` object. The room keeps that capability, and
whenever anyone posts, the room calls each member's inbox back directly. The
push is the room invoking an object it was handed, not a message on a queue
someone has to drain.

That one move is the whole object-capability story made concrete:

- **A room is a capability the directory returns.** The server publishes one
  bootstrap object, the `directory`. Sending it `open(name)` or `enter(name)`
  returns a live reference to a room, not a URL or a room id you look up again,
  but the room object itself. Holding that reference _is_ your access to the
  room. The directory's `list` and `watch` let a client _discover_ which rooms
  have people in them, but they return names and counts, not authority: you
  still `enter` to get the room capability before you can speak.
- **Authority travels as a reference.** The client publishes an `inbox` actor
  and passes a reference to it as an argument of `subscribe`. On the wire that
  is an ordinary OCapN reference argument; on the room's side it arrives as a
  far reference the room can eventual-send to. No URL, no auth token, no
  registry.
- **The capability is the identity.** The room's `post` method takes only the
  text. It does not take a "from" field, because the connection the post arrives
  on already tells the room which member is speaking. You cannot post as someone
  else, because you only hold your own capability.
- **A name is a room-granted claim.** `subscribe(nick, inbox)` is where the room
  decides whether the nickname is available. If it grants the claim, later
  `post(text)` calls speak as that member until the connection leaves or closes.
- **The room cannot tell the languages apart.** A Rust member and a Python
  member are the same shape on the wire. Interop is not a feature here; it is
  the absence of anything language-specific.

## Layout

```
examples/apps/rooms/
├── deno/protocol.ts      the shared wire contract: directory verbs (open/enter/list/watch + register/introduce) + room verbs (subscribe/post/leave) + the member dm verb
├── deno/server.ts        the server (directory of rooms, multi-connection, capability callbacks, watchers, member introductions)
├── deno/room_client.ts   the Room client (the OCapN layer) in Deno, strict directory open/enter/list/watch
├── deno/enter_room.ts    the CLI's friendly enter-or-open, composed from those strict verbs
├── deno/client.ts        the one-shot demo client in Deno (lists rooms, then enters)
├── deno/chat.ts          the interactive terminal client (/open /enter /leave /list)
├── deno/web.ts           the browser UI (live room list + in-tab switching over a WebSocket bridge)
├── python/room_client.py + client.py    the same, in Python
├── racket/room-client.rkt + client.rkt  the same, in Racket
├── rust/room.rs + client.rs             the same, in Rust (its own crate)
├── zig/client.zig        the same in native Zig, over the real TCP netlayer
├── demo.ts               the orchestrator `zig build demo-rooms` runs
├── dm_demo.ts            the direct-message-by-introduction orchestrator `zig build demo-rooms-dm` runs
├── dm_demo_iroh.ts       the same introduction over iroh, cross-endpoint, that `zig build demo-rooms-dm-iroh` runs
└── dm_demo_iroh_discovery.ts  the node-id-only variant `zig build demo-rooms-dm-iroh-discovery` runs
```

Each language has a `Room` client — the small layer that knows about OCapN
(publish an inbox, hand the room a capability to it, drive the vat) — and a thin
app on top of it. The app reads the same in every language because each `Room`
exposes its own runtime's native async-sequence shape: the lines the room sends
arrive as a stream you iterate, and a send is a value you await.

| Language | Receive the room's lines                  | Send                   |
| -------- | ----------------------------------------- | ---------------------- |
| Deno     | `for await (const msg of room.messages)`  | `await room.say(line)` |
| Python   | `async for msg in room`                   | `await room.say(line)` |
| Rust     | `while let Some(msg) = room.recv().await` | `room.say(line).await` |
| Racket   | `(for ([msg (in-room room)]) …)`          | `(room-say room line)` |

Reading any two side by side shows how little the actor model changes from
language to language.

## The surface underneath

Each `Room` is built on the binding's application surface — `connect`, `fetch`,
`spawn`, `send`, `serve` — and that is the whole of the OCapN it touches:

```typescript
const conn = await connect(tcpLocator(host, port));
conn.serve().catch(() => {});
const directory = await conn.fetch("directory");      // the directory, by name
const room = await conn.send(directory, "enter", [name]); // a room capability back
const inbox = conn.spawn((verb, args) => { … });      // our callback, a capability
await conn.send(room, "subscribe", [nick, inbox]);    // hand it over
```

No export-position numbers, no manual flush, no hand-rolled receive loop, the
`Room` wrapper is a few dozen lines because the surface does the rest. The Zig
client uses the same surface as `driver.ConnectedVat`, explicit about allocation
and I/O. Reading any two `Room` clients side by side shows how little the model
changes from language to language.

## Where the rooms could go next

The directory grants rooms by name, reclaims them when empty, and now lets a
client `list` and `watch` the live rooms — discovery the web UI and the
interactive CLI both surface, with switching between rooms on one connection.
Because a room is just a capability, the directory already goes further: with
`register`/`introduce` it hands a client a _member's_ capability that lives on
that member's own endpoint and lets the two talk directly — a three-party
handoff, the gifter side, with the room out of the path, over loopback TCP
(`zig build demo-rooms-dm`) **and over iroh's encrypted QUIC**
(`zig build demo-rooms-dm-iroh`), where the gift names the member's
`direct-addresses` so the caller dials it directly. The next step is introducing
whole rooms that live on another server.

Nor does the server yet attenuate (a read-only room handle) or persist history.
Attenuation and revocation are shown end-to-end in the sibling
[`tools`](../tools/) showcase, on the same capability model: a read-only view is
an actor that forwards only the safe verbs, and a revocable handle is a
forwarder you can sever. Wiring them into a room is a few lines and a good next
exercise.
