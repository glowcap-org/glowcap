# Developing and operating Rooms

This guide collects the details needed to test, extend, or deploy Rooms. Start
with the [Rooms overview](README.md) if you only want to run the application.

## Demo controls

`zig build demo-rooms` chooses an available port and starts its own server. Pin
the port when another process needs to find it:

```sh
zig build demo-rooms -Dport=9099
```

Attach mode runs the demo clients against an existing server and leaves that
server running:

```sh
zig build demo-rooms -Dport=9099 -Dattach=true
```

The room may already contain people. Each demo client checks broadcasts against
the demo's own roster, so other members may appear in the transcript without
affecting the result.

The main scenarios are:

| Command | What it checks | Extra requirements |
| --- | --- | --- |
| `zig build demo-rooms` | Five binding clients share one TCP room. | Deno; optional language runtimes join when present. |
| `zig build demo-rooms-iroh` | The same room over encrypted iroh QUIC. | Deno and Cargo. |
| `zig build demo-rooms-dm` | A room introduces two TCP members, which then message off-room. | Deno. |
| `zig build demo-rooms-dm-iroh` | The same handoff across three iroh endpoints with explicit hints. | Deno and Cargo. |
| `zig build demo-rooms-dm-iroh-discovery` | Handoff using a node id resolved through public n0 discovery. | Deno, Cargo, and internet access. |
| `zig build rooms-web` | Browser peer and local TCP room. | Deno. |
| `zig build rooms-web-relay-peer` | A wasm peer drives the directory through the relay, no browser. | Deno. |
| `zig build rooms-web-browser-peer` | A real browser runs the wasm peer through the relay. | Deno and Playwright Chromium. |
| `zig build rooms-web-page` | The whole page as a peer: join, round-trip a line, and hold both layouts. | Deno and Playwright Chromium. |
| `zig build rooms-web-reconnect` | The page survives losing its room server and re-enters on its own. | Deno and Playwright Chromium. |
| `zig build rooms-web-iroh` | Browser peer and iroh room. | Deno and Cargo. |
| `zig build rooms-web-dm` | Browser-to-native direct messaging. | Deno and Playwright Chromium. |
| `zig build rooms-web-dm-tabs` | Two tabs cold-dial through one relay and message off-room. | Deno and Playwright Chromium. |
| `zig build rooms-web-dm-native` | A native peer cold-dials a browser member through the relay rendezvous. | Deno and Playwright Chromium. |
| `zig build rooms-web-dm-webrtc` | Two members direct-message over a WebRTC DataChannel the room only signaled. | Deno and Playwright Chromium. |
| `zig build rooms-web-dm-retarget` | A direct conversation does not follow a reused nickname. | Deno and Playwright Chromium. |

The browser and demo commands are separate from `zig build check` because they
depend on external runtimes or a real browser.

`rooms-web` and `rooms-web-iroh` accept `-Dport=9099` when the HTTP port must be
fixed.

## Interactive clients

Start a TCP server on a known port:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/server/main.ts 9099
```

It prints `ROOMS-SERVER-LISTENING 9099`. Join it with the interactive Deno
client:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/clients/deno/chat.ts 127.0.0.1:9099 general alice
```

Chat lines are sent on Enter. Room notices begin with `*`; Ctrl-D leaves.
Commands begin with `/`:

- `/list` shows populated rooms.
- `/open <name>` creates a room and enters it.
- `/enter <name>` enters an existing room.
- `/leave` leaves the current room.

The one-shot clients accept a locator, room, nickname, message, and expected
roster. Passing only the sender as the roster means “post and exit,” which is
handy when adding another language to a live room:

```sh
python3 apps/rooms/clients/python/client.py \
  127.0.0.1:9099 general grace "hi from python" grace
racket apps/rooms/clients/racket/client.rkt \
  127.0.0.1:9099 general alan "hi from racket" alan
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/clients/deno/client.ts \
  127.0.0.1:9099 general ada "hi from deno" ada
cargo run --manifest-path apps/rooms/clients/rust/Cargo.toml -- \
  127.0.0.1:9099 general hopper "hi from rust" hopper
zig build rooms-client -- \
  127.0.0.1:9099 general turing "hi from zig" turing
```

Each client also accepts the `ocapn://…` locator printed by an iroh server.

## Browser peer and relay

The page loads the WebAssembly `@pancake/web` Host. It is an OCapN peer: it
dials the directory, holds room capabilities, hosts inbox objects, and redeems
introductions itself.

A browser cannot open raw TCP or iroh sockets, so `web/serve.ts` exposes a
WebSocket byte relay:

```text
browser peer ──WebSocket /relay──▶ serve.ts ──TCP or iroh──▶ peer
```

The relay does not parse CapTP or hold application capabilities. The keyed
session passes through it end to end. Local development uses `ws://`; HTTPS
deployments use `wss://`.

The TCP relay is pinned to its Rooms server. The iroh demo relay accepts any
key-verified iroh node so that a browser can redeem introductions. That makes it
a possible bandwidth amplifier; a production deployment should restrict the
allowed destinations.

The relay also refuses a dial whose `Origin` names a host other than the one it
was asked on. A page served from somewhere else would otherwise be able to use a
reader's local relay to reach whatever the rules above still allow, simply
because their browser can. The shipped page is served by `serve.ts` and dials the
relay on the host it came from, so it is unaffected; a test or a probe that
fabricates its own page has to serve it from that same origin. A request with no
`Origin` at all, which is every non-browser client, passes.

Browser peers also register a rendezvous identity with the relay. Another peer
on the same relay — a browser tab, or a native process whose host is configured
with the relay's rendezvous mapping — can use that identity to bridge a fresh
connection to the held WebSocket. The bridge makes cold dial possible without
putting the room in the message path. It does not yet cover browsers on
different relays.

A page opened with `?dm=webrtc` advertises a `webrtc` identity instead: direct
messages then cross a WebRTC DataChannel between the two tabs, and the room
directory carries only the offer, answer, and candidate exchange as ordinary
capability messages (`offerSignaling` and the `signal*` verbs in
`lib/protocol.ts`).

## Application contract

The directory owns room discovery and introductions:

- `open(name)` and `enter(name)` return a room capability.
- `list()` reports populated rooms; `watch(inbox)` pushes directory changes.
- `register(...)` records a member's dialable identity.
- `introduce(nick)` returns the inbox that member minted for this caller.

A room grants a nickname when `subscribe(nick, inbox)` succeeds. Later
`post(text)` calls need no sender field: the room already knows which membership
capability received the call. Leaving or disconnecting releases the nickname.

Direct inboxes follow the same rule. `dm(text)` carries no claimed sender
because each inbox was minted for one introduced peer. A direct conversation is
keyed by that introduction, not by the room nickname.

The application wrappers use only the public binding surface: connect, fetch,
spawn, send, and serve. Protocol tables, export positions, and frame movement
remain below them.

## The browser interface

The page is a React application, entered through `web/ui/main.tsx` and bundled to
`page.js` by `serve.ts` at startup. It is worth knowing three things about how it
is put together before changing it.

The state lives in one place. `store.ts` holds every fact the page shows, and
every verb that changes one. Nothing is kept in the DOM: no code asks an element
whether it carries a class in order to decide what a button should announce, and
no handler re-applies a set of classes when the window crosses the layout
breakpoint. The components are a function of the store, so those answers are
derived on each render instead. What `get()` returns is read-only all the way
down, so writing through it is a thing the compiler refuses rather than a rule to
remember.

What the store holds is what more than one part of the page depends on. State
that is genuinely one control's own — a half-typed room name in the rail's "+"
field, whether the emoji tray is open, whether the composer has the caret — stays
in that component, because nothing else reads it and putting it in the store
would only widen what a keystroke there invalidates. What it must never do is
stay in the DOM: an element's own value outlives the control being closed and the
conversation being switched, so it comes back later carrying an intention from
some earlier moment.

States that could not mean anything are not spellable. A conversation's standing
with its reader is one value rather than a count beside a nullable line id, so
"unread lines but no rule to draw" cannot be built. A direct line is
`introducing`, `live`, or `closed` rather than two booleans, so "closed and live"
cannot be built either, and closed stays closed — the room has the nick back, and
a later holder is a different person.

The peer is not part of the tree. `net.ts` owns the CapTP session at module
scope and imports no component; it reads and writes the store and nothing else.
That is what lets the interface remount, or an error boundary catch a render,
without disturbing a live conversation, and it is why `StrictMode` is safe here.

Memoisation is written by hand, and it is worth knowing why. React's compiler
would insert it, but it runs as a Babel plugin and `deno bundle` has no place to
put one, so the few components that must not redraw on every keystroke say so
themselves. Each of those says why in a comment above it.

The two layouts keep separate state. On a wide screen the rail and the roster are
columns you collapse and keep collapsed; on a phone they are a screen and a sheet
that any navigation dismisses. Those are two facts with two lifetimes, so the
store holds four fields rather than two, and each layout reads and writes only
its own. Which layout is in force is a store field too, so `showRail(shown)` is
one verb that a control can ask for without knowing what it means here.

Three of these are held by `zig build meta-check` rather than by this page.
`tools/check/meta_check/rooms_ui.zig` keeps a table of the ids and classes the
browser proofs select on, and fails if a component stops emitting one or a proof
stops using it — a renamed class would otherwise surface as a proof timing out
for a reason that has nothing to do with what it tests. It also refuses the
document to `net.ts`, `store.ts`, and their pure neighbours, and refuses a third
spelling of the layout breakpoint. Comments are stripped before any of it runs,
so prose may still explain the rule it describes.

## Source map

| Path | Role |
| --- | --- |
| `server/main.ts` | Directory and room host. |
| `lib/protocol.ts` | Directory, room, and direct-message verbs. |
| `lib/room_client.ts` | Shared application wrapper used by Deno and the browser. |
| `lib/dm_*.ts` | Direct inboxes, replies, and handoff choreography. |
| `lib/locator.ts` | TCP and iroh dialing for Deno clients. |
| `clients/` | Deno, Python, Racket, Rust, and Zig clients. |
| `web/serve.ts` | Page server, room supervisor, and relay endpoint. |
| `web/relay.ts` | Byte relay and browser rendezvous bridge. |
| `web/ui/` | Browser peer and interface. |
| `web/ui/net.ts` | The peer itself: sessions, rooms, and direct messages. |
| `web/ui/store.ts` | Every fact the interface shows, and the verbs that change them. |
| `web/ui/*.tsx` | The React components that draw from that store. |
| `demos/` | Command-line scenario orchestrators. |
| `test/` | Server, relay, browser, and direct-message checks. |
