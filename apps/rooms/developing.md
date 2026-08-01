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
| `zig build rooms-web-iroh` | Browser peer and iroh room. | Deno and Cargo. |
| `zig build rooms-web-dm` | Browser-to-native direct messaging. | Deno and Playwright Chromium. |
| `zig build rooms-web-dm-tabs` | Two tabs cold-dial through one relay and message off-room. | Deno and Playwright Chromium. |
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

Browser peers also register a rendezvous identity with the relay. Another
browser on the same relay can use that identity to bridge a fresh connection to
the held WebSocket. The bridge makes browser-to-browser cold dial possible
without putting the room in the message path. It does not yet cover a native
peer dialing a browser or browsers on different relays.

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
| `demos/` | Command-line scenario orchestrators. |
| `test/` | Server, relay, browser, and direct-message checks. |
