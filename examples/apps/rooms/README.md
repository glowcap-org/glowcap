# rooms — a capability-secure chat, in five languages at once

This is a small, real application built on pancake actors. A chat room runs as a
server; people join it, post lines, and see each other's lines in real time. What
makes it worth reading is not the chat — it is *how* the chat works, and that the
same room holds members written in Zig, Rust, Python, Racket, and Deno at the same
time, none of them aware of the others' languages.

Run the whole thing with one command:

```sh
zig build demo-rooms
```

That starts a Deno-hosted room and joins one client per language to it over TCP.
Each client posts a line and waits to receive every member's line back. When they
all succeed you will see a transcript per language and a final line saying every
member saw every message.

The only runtime the demo requires is `deno`, which hosts the room and runs the
orchestrator, plus the Zig client, which `zig build` always builds. Python,
Racket, and Rust each join only when their runtime (`python3`, `racket`, `cargo`)
is on PATH; the demo builds the Rust client itself when `cargo` is present, and it
reports any language it skipped rather than failing. So `zig build demo-rooms` runs on
whatever machine you have, with as many languages as you have installed. It is a
sibling of `zig build check`, not part of the hermetic gate.

By default the demo binds an ephemeral port. To put the room on a port you
chose — one your container forwards, say — pin it with
`zig build demo-rooms -Dport=9099`. To point the demo's clients at a room you
already started yourself (the fixed-port server below, or the web UI's room),
add attach mode: `zig build demo-rooms -Dport=9099 -Dattach=true` joins your
server instead of spawning its own, and leaves it running when the demo ends.
The room does not need to be empty or quiet: each client asserts the
all-to-all broadcast against the demo's own member roster, so anyone already
chatting in the room shows up in the transcripts but is never counted.

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
`libpancake_iroh` C ABI superset (the Rust sidecar behind
[ADR-0055](../../../docs/decisions/adr/ADR-0055-iroh-netlayer-sidecar.md)), so
this step needs `cargo` as well as `deno`; a language still joins only when its
runtime is present. It is a sibling of `zig build check`, never part of the
hermetic gate. Discovery is relay-less with explicit hints — a loopback/LAN
story, not public-internet dialing.

## Chat in it from your browser

The friendliest way in is a web UI:

```sh
deno run --allow-ffi --allow-read --allow-net --allow-run \
  examples/apps/rooms/deno/web.ts
```

That starts the room for you and serves a page at `http://localhost:8000`. Open it,
pick a name, and chat. Each browser tab joins as its own member, so open a few — or
chat from a tab while a terminal client or another language is in the same room.
The page shows the room roster too: every member the room knows about, including
Zig, Rust, Python, Racket, Deno, and browser members, appears as online or
recently offline. Names are unique while they are live, ignoring case: the room
grants one membership per nickname and releases that claim when the member
leaves.

A browser cannot speak raw TCP/OCapN, so `web.ts` sits in the middle: it serves the
page, and for each tab it opens its own pancake membership in the room and bridges
the two over a WebSocket. The browser only ever talks WebSocket to `web.ts`; the
OCapN capability exchange — handing the room your inbox so it calls you back —
happens on the Deno side, exactly as it does for every other client.

```text
browser ──WebSocket──▶ web.ts (a pancake member) ──TCP/OCapN──▶ rooms server
```

It also prints the room's port, so you can join the same room from a terminal at
the same time with `chat.ts` (below). It serves on port 8000 by default; pass a
different one as the first argument.

## Chat in it yourself, interactively

The clients the demo runs are one-shot: each posts a single line and exits, which
is what an automated check wants. To actually sit in the room and talk, run the
server and the interactive client by hand, one terminal per person.

First, in one terminal, start the server on a fixed port:

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/server.ts 9099
```

It prints `ROOMS-SERVER-LISTENING 9099`. Then open a terminal for each person and
join with a nickname — the first argument is the locator the server announced
(`127.0.0.1:9099` for the TCP server above, or the `ocapn://…` URI an
`ROOMS_TRANSPORT=iroh` server prints):

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 alice
```

```sh
deno run --allow-ffi --allow-read --allow-net \
  examples/apps/rooms/deno/chat.ts 127.0.0.1:9099 bob
```

Type a line and press enter to post it; lines from everyone else appear as they
arrive, and room announcements are prefixed with `*`. Press Ctrl-D to leave.

You can mix languages in the same room. The one-shot clients each take a nickname
and a single line to post, so you can drop one into a running room to say hello
from another language — for example, while `alice` and `bob` are chatting in Deno:

```sh
python3 examples/apps/rooms/python/client.py 127.0.0.1:9099 grace "hi from python" grace
racket examples/apps/rooms/racket/client.rkt 127.0.0.1:9099 alan "hi from racket" alan
```

Each one-shot client takes the same transport-neutral locator as its first
argument, so the same command line joins a TCP or an iroh room — pass the URI the
iroh server announced instead of `host:port`. The trailing argument is the roster
each one-shot client waits to hear from.
Passing just its own nickname means "post and go," so it does not block on a full
room.

## The idea: you call me, I call you back

A traditional chat client polls a server: "anything new? anything new?" This one
never does. When a client subscribes, it hands the room a *capability* — a live
reference to its own `inbox` object. The room keeps that capability, and whenever
anyone posts, the room calls each member's inbox back directly. The push is the
room invoking an object it was handed, not a message on a queue someone has to
drain.

That one move is the whole object-capability story made concrete:

- **Authority travels as a reference.** The client publishes an `inbox` actor and
  passes a reference to it as an argument of `subscribe`. On the wire that is an
  ordinary OCapN reference argument; on the room's side it arrives as a far
  reference the room can eventual-send to. No URL, no auth token, no registry.
- **The capability is the identity.** The room's `post` method takes only the
  text. It does not take a "from" field, because the connection the post arrives
  on already tells the room which member is speaking. You cannot post as someone
  else, because you only hold your own capability.
- **A name is a room-granted claim.** `subscribe(nick, inbox)` is where the room
  decides whether the nickname is available. If it grants the claim, later
  `post(text)` calls speak as that member until the connection leaves or closes.
- **The room cannot tell the languages apart.** A Rust member and a Python member
  are the same shape on the wire. Interop is not a feature here; it is the absence
  of anything language-specific.

## Layout

```
examples/apps/rooms/
├── deno/protocol.ts      the shared wire contract: a capability name and three verbs
├── deno/server.ts        the room server (multi-connection, capability callbacks)
├── deno/room_client.ts   the Room client (the OCapN layer) in Deno
├── deno/client.ts        the one-shot demo client in Deno
├── deno/chat.ts          the interactive terminal client
├── deno/web.ts           the browser UI (a WebSocket bridge to a Room membership)
├── python/room_client.py + client.py    the same, in Python
├── racket/room-client.rkt + client.rkt  the same, in Racket
├── rust/room.rs + client.rs             the same, in Rust (its own crate)
├── zig/client.zig        the same in native Zig, over the real TCP netlayer
└── demo.ts               the orchestrator `zig build demo-rooms` runs
```

Each language has a `Room` client — the small layer that knows about OCapN
(publish an inbox, hand the room a capability to it, drive the vat) — and a thin
app on top of it. The app reads the same in every language because each `Room`
exposes its own runtime's native async-sequence shape: the lines the room sends
arrive as a stream you iterate, and a send is a value you await.

| Language | Receive the room's lines | Send |
| --- | --- | --- |
| Deno | `for await (const msg of room.messages)` | `await room.say(line)` |
| Python | `async for msg in room` | `await room.say(line)` |
| Rust | `while let Some(msg) = room.recv().await` | `room.say(line).await` |
| Racket | `(for ([msg (in-room room)]) …)` | `(room-say room line)` |

Reading any two side by side shows how little the actor model changes from
language to language.

## The surface underneath

Each `Room` is built on the binding's application surface — `connect`, `fetch`,
`spawn`, `send`, `serve` — and that is the whole of the OCapN it touches:

```typescript
const conn = await connect(host, port);
conn.serve().catch(() => {});
const room = await conn.fetch("room");          // the room, by name
const inbox = conn.spawn((verb, args) => { … }); // our callback, a capability
await conn.send(room, "subscribe", [nick, inbox]); // hand it over
```

No export-position numbers, no manual flush, no hand-rolled receive loop — the
`Room` wrapper is a few dozen lines because the surface does the rest. The Zig
client uses the same surface as `driver.ConnectedVat`, explicit about allocation
and I/O. Reading any two `Room` clients side by side shows how little the model
changes from language to language.

## Where the room could go next

The server keeps one capability per member and drops a member when its socket
dies. It does not yet attenuate (a read-only room handle) or persist history.
Attenuation and revocation are shown end-to-end in the sibling
[`tools`](../tools/) showcase, on the same capability model: a read-only view is
an actor that forwards only the safe verbs, and a revocable handle is a forwarder
you can sever. Wiring them into the room is a few lines and a good next exercise.
