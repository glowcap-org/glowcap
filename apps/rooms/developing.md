# Developing and operating Rooms

This guide collects the details needed to test, extend, or deploy Rooms. Start with the
[Rooms overview](README.md) if you only want to run the application.

## Demo controls

`zig build demo-rooms` chooses an available port and starts its own server. Pin the port when
another process needs to find it:

```sh
zig build demo-rooms -Dport=9099
```

Attach mode runs the demo clients against an existing server and leaves that server running:

```sh
zig build demo-rooms -Dport=9099 -Dattach=true
```

## Watching the room live

The room server can broadcast its own protocol activity as a timeline the [ocapnviz](../ocapnviz/)
viewer draws. Set `ROOMS_VIZ_PORT` when starting the server, switch the viewer to
**Live**, and point the Source sturdyref field at the printed
`ROOMS-VIZ-LISTENING` capability:

```sh
ROOMS_VIZ_PORT=9300 deno run --allow-ffi --allow-net --allow-read --allow-env \
  apps/rooms/server/main.ts 9099
```

Entering Live connects to the feed. Press **Record** to capture: every session
the room accepts, every message in either direction, and every close draws on
the stage from that moment. **Stop** hands the capture to Play, where it replays
like any other recording. The stream is the same versioned timeline schema
`pancake griddle run` prints.

Direct messages never go through the room, so each member also publishes its
own trace to the same viz endpoint. A browser tab asks its server for the
endpoint and sends records on a socket that carries nothing back. The
conversation stays private; the timeline only merges the telemetry, and when
both ends of one conversation report it, the endpoint draws it once.

The same works with the browser UI. The web server supervises the room server as a child that
inherits the environment, so setting the port on `rooms-web-iroh` or `rooms-web-tcp` traces the
room and every tab's sessions with it:

```sh
ROOMS_VIZ_PORT=9300 zig build rooms-web-iroh
ROOMS_VIZ_PORT=9300 zig build rooms-web-tcp
```

The supervisor keeps one room identity across child crashes. A child that had been serving and
then died comes straight back; one that exits the moment it starts, which is what a taken port or
an unreachable state directory looks like, is restarted more slowly each time up to half a minute,
so the line it printed about why stays readable instead of scrolling past under copies of itself.

Its development default is a private temporary `ROOMS_STATE` directory that lives as long as
`serve.ts`; set `ROOMS_STATE` yourself when the identity and issued room links must also survive
restarting the web supervisor. The container deployment does this with its `rooms-state` volume.

Cargo must be on `PATH` for the iroh transport sidecar; Deno is required for the UI either way. The
TCP form drops the Cargo requirement and the encryption with it. Either command prints a
`ROOMS-VIZ-LISTENING` line once the room server is up. Open [ocapnviz](../ocapnviz/)
(`cd apps/ocapnviz && bash dev.sh`), switch the top bar to **Live**, and give
the Source field that sturdyref.

Attach mode is the one caveat: if an orphaned room server already holds the room port, the web
server attaches to it instead of spawning its own child, and tracing follows however that orphan was
started. Kill stray servers first when the `ROOMS-VIZ-LISTENING` line doesn't appear.

`ROOMS_VIZ_PORT=0` takes whatever port is free, and the announce line names the one it bound. A
browser tab cannot find an endpoint chosen that way, because the port is picked inside the room
server and the page is served by another process. Pick a fixed port when you want members' direct
messages on the timeline, or open the page with `?viz=ws://127.0.0.1:<port>/`
(or set that URL in Settings).

## Bringing a Spritely Goblins vat into the room

Every peer described so far is a pancake peer, and a room of pancake peers uses pancake's own wire
profile. A [Spritely Goblins](https://spritely.institute/goblins/) vat speaks the OCapN v1.0
baseline instead, and it can join the same room: each connection settles its own profile from what
the two ends offer, so the Goblins member arrives on the baseline while the pancake members keep
talking to each other on the native one.

Watching that happen takes three terminals and a browser.

Start the browser UI with the live timeline switched on. The Goblins vat speaks cleartext TCP and
nothing else, so this walkthrough is one of the few that wants the TCP server. The room server it
supervises listens on port 9099:

```sh
ROOMS_VIZ_PORT=9300 zig build rooms-web-tcp
```

Open `http://localhost:8000`, enter the room `general`, and pick a nickname. That is your pancake
member.

In a second terminal, start the viewer, switch the top bar to **Live**, and give
the Source field the `ROOMS-VIZ-LISTENING` sturdyref:

```sh
cd apps/ocapnviz && bash dev.sh
```

In a third terminal, join the same room as a real Goblins vat and start typing:

```sh
racket -y conformance/goblins-peer/racket/rooms-chat.rkt \
  127.0.0.1:9099 general goblins-carol 9200
```

This is a chat terminal like `clients/deno/chat.ts`, except that the peer on the other end of it is
a Goblins vat rather than a pancake one. It takes the same commands — `/list`, `/open <name>`,
`/enter <name>`, `/leave`, `/help` — and Ctrl-D quits. Anything else you type is a line in the room.
The trailing `9200` is the port the vat's own netlayer binds, which is where other members reach it
privately.

What you type appears in the browser, what the browser types appears here, and on the viewer's stage
the new session is labeled `goblins-carol` and drawn on `syrup/v1_0` while yours stays on
`capnp/next`: one room, two implementations, each connection on the profile its own two ends could
agree on.

`zig build goblins-rooms` runs the same meeting without the browser and checks it: a scripted
Goblins vat and a pancake client exchange lines in one room, and the server's own trace has to show
the two profiles. The scripted member is `conformance/goblins-peer/racket/rooms-member.rkt`, next
door to the interactive one.

### Direct-messaging the vat

Click the vat's name in the member pane and type. The room introduces you and then carries none of
it: the line runs between your browser and the vat, and the viewer draws it as a session of its own
that disappears when you close the thread. The vat prints it as `(dm) <you>`, and anything it types
back with `/dm` comes home over the connection your message arrived on.

Over cleartext TCP this needs one thing from the server. The browser reaches everything through the
relay, and the relay will not open a cleartext socket to an address a page named, so start the
server with the vat's own address listed:

```sh
PANCAKE_RELAY_TCP_PEERS=127.0.0.1:9200 zig build rooms-web-tcp
```

Over iroh there is nothing to list: an iroh destination has to be a peer holding the key it is
named by, and the relay dials any of them. `zig build goblins-rooms-dm` and
`zig build goblins-rooms-dm-iroh` run the whole conversation, one arm each, and check that it
reaches the timeline and leaves it again.

The room may already contain people. Each demo client checks broadcasts against the demo's own
roster, so other members may appear in the transcript without affecting the result.

The main scenarios are:

| Command                                  | What it checks                                                                     | Extra requirements                                  |
| ---------------------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------- |
| `zig build demo-rooms`                   | Five binding clients share one TCP room.                                           | Deno; optional language runtimes join when present. |
| `zig build demo-rooms-iroh`              | The same room over encrypted iroh QUIC.                                            | Deno and Cargo.                                     |
| `zig build demo-rooms-dm`                | A room introduces two TCP members, which then message off-room.                    | Deno.                                               |
| `zig build demo-rooms-dm-iroh`           | The same handoff across three iroh endpoints with explicit hints.                  | Deno and Cargo.                                     |
| `zig build demo-rooms-dm-iroh-discovery` | Handoff using a node id resolved through public n0 discovery.                      | Deno, Cargo, and internet access.                   |
| `zig build goblins-rooms`                | A real Goblins vat and a pancake client hold one room, on different wire profiles. | Deno, Racket, and the `goblins` collection.         |
| `zig build goblins-rooms-dm`             | A browser and a real Goblins vat hold a direct message off-room over TCP, and the vat starts one of its own with a native pancake member. | Deno, Racket, `goblins`, and Playwright Chromium.   |
| `zig build goblins-rooms-dm-iroh`        | The browser's direction over encrypted iroh QUIC; the vat's own is TCP-only.                                    | Cargo, Deno, Racket, `goblins`, Playwright Chromium. |
| `zig build rooms-web-iroh`               | Browser peer and iroh room, the ordinary way to run the UI.                        | Deno and Cargo.                                     |
| `zig build rooms-web-tcp`                | The same UI over cleartext TCP, for a peer that speaks nothing else.               | Deno.                                               |
| `zig build rooms-web-relay-peer`         | A wasm peer drives the directory through the relay, no browser.                    | Deno.                                               |
| `zig build rooms-web-browser-peer`       | A real browser runs the wasm peer through the relay.                               | Deno and Playwright Chromium.                       |
| `zig build rooms-web-page`               | The whole page as a peer: join, round-trip a line, and hold both layouts.          | Deno and Playwright Chromium.                       |
| `zig build rooms-web-reconnect`          | The page survives losing its room server and re-enters on its own.                 | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm`                 | Browser-to-native direct messaging.                                                | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm-tabs`            | Two tabs cold-dial through one relay and message off-room.                         | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm-native`          | A native peer cold-dials a browser member through the relay rendezvous.            | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm-webrtc`          | Two members direct-message over a WebRTC DataChannel the room only signaled.       | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm-retarget`        | A direct conversation does not follow a reused nickname.                           | Deno and Playwright Chromium.                       |
| `zig build rooms-web-dm-reopen`          | Reopening a closed conversation opens a second connection, and that one carries.   | Deno and Playwright Chromium.                       |

The browser and demo commands are separate from `zig build check` because they depend on external
runtimes or a real browser. The devcontainer image carries the Playwright Chromium these rows want,
so there is nothing to install first; elsewhere, `tools/check/playwright-preflight.sh` names the
pinned version and how to get it.

`rooms-web-iroh` and `rooms-web-tcp` accept `-Dport=9099` when the HTTP port must be fixed.

## Interactive clients

Start a TCP server on a known port:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/server/main.ts 9099
```

It prints `ROOMS-SERVER-LISTENING 9099`. Join it with the interactive Deno client:

```sh
deno run --allow-ffi --allow-read --allow-net \
  apps/rooms/clients/deno/chat.ts 127.0.0.1:9099 general alice
```

Chat lines are sent on Enter. Room notices begin with `*`; Ctrl-D leaves. Commands begin with `/`:

- `/list` shows populated rooms.
- `/open <name>` creates a room and enters it.
- `/enter <name>` enters an existing room.
- `/leave` leaves the current room.

The one-shot clients accept a locator, room, nickname, message, and expected roster. Passing only
the sender as the roster means “post and exit,” which is handy when adding another language to a
live room:

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

The page loads the WebAssembly `@pancake/web` Host. It is an OCapN peer: it dials the directory,
holds room capabilities, hosts inbox objects, and redeems introductions itself.

A browser cannot open raw TCP or iroh sockets, so `web/serve.ts` exposes a WebSocket byte relay:

```text
browser peer ──WebSocket /relay──▶ serve.ts ──TCP or iroh──▶ peer
```

The relay does not parse CapTP or hold application capabilities. The keyed session passes through it
end to end. Local development uses `ws://`; HTTPS deployments use `wss://`.

The TCP relay is pinned to its Rooms server. The iroh demo relay accepts any key-verified iroh node
so that a browser can redeem introductions. That makes it a possible bandwidth amplifier; a
production deployment should restrict the allowed destinations.

The relay also refuses a dial whose `Origin` names a host other than the one it was asked on.
Otherwise a page from elsewhere could use a reader's local relay to reach whatever the rules above
still allow. The shipped page is served by `serve.ts` and dials the relay on the host it came from,
so it is unaffected. A test or probe that fabricates its own page has to serve it from that same
origin. A request with no `Origin` at all (every non-browser client) passes.

Browser peers also register a rendezvous identity with the relay. Another peer on the same relay — a
browser tab, or a native process whose host is configured with the relay's rendezvous mapping — can
use that identity to bridge a fresh connection to the held WebSocket. The bridge makes cold dial
possible without putting the room in the message path. It does not yet cover browsers on different
relays.

A page opened with `?dm=webrtc` advertises a `webrtc` identity instead: direct messages then cross a
WebRTC DataChannel between the two tabs, and the room directory carries only the offer, answer, and
candidate exchange as ordinary capability messages (`offerSignaling` and the `signal*` verbs in
`lib/protocol.ts`). The same choice is in Settings; a URL that names `dm` or `viz` still wins over
whatever this browser last saved.

## Application contract

The directory owns room discovery and introductions:

- `open(name)` and `enter(name)` return a room capability.
- `list()` reports populated rooms; `watch(inbox)` pushes directory changes.
- `register(...)` records a member's dialable identity.
- `introduce(nick)` returns the inbox that member minted for this caller.

A room grants a nickname when `subscribe(nick, inbox)` succeeds. Later `post(text)` calls need no
sender field: the room already knows which membership capability received the call. Leaving or
disconnecting releases the nickname.

`subscribe` answers with a reference carrying `setTopic(text)`, and holding it is the authority to say
what the room is about. Every member is answered with one, because the room has no ranks to hand
out, and because it is a reference rather than a rank a member can pass it to somebody who is not
even here. The room states its topic to each arrival and broadcasts every change with the `topic`
tag, so a client that has never heard of topics still shows the line saying it moved.

`away(reason)` says this membership has stepped away and `away("")` says it is back. Nothing is
handed over for it: a member's own standing is theirs to state, and the room writes it against the
membership that called rather than against a name anybody could type. The room tells each arrival who
is already away, on the same line every later change arrives on.

`post` answers with a reference to the line it made, and holding that reference is the authority to
`edit(text)` or `withdraw()` that one line. The room asks nobody whether the line is theirs, because
a member who does not hold the reference cannot form the request. That also makes the authority
passable: a member can hand it to somebody else, and a room could keep a copy of its own to give
whoever it wants moderating, without either side learning what a moderator is. A room that answers a
post with nothing is an older room, and a client meeting one simply has no line to change.

Direct inboxes follow the same rule. `dm(text)` carries no claimed sender because each inbox was
minted for one introduced peer. A direct conversation is keyed by that introduction, not by the room
nickname.

The application wrappers use only the public binding surface: connect, fetch, spawn, send, and
serve. Protocol tables, export positions, and frame movement remain below them.

## The browser interface

The page is a React application under `web/ui/`, entered through `main.tsx` and bundled to `page.js`
by `serve.ts`. Shared UI state lives in `store.ts`: every fact the page shows, and every verb that
changes one. State that belongs to one control stays in that component: a half-typed room name, an
open emoji tray, the composer caret. UI state must not live in the DOM. An element's own value outlives
closing the control or switching conversations, and comes back carrying an earlier intention.

`net.ts` owns the CapTP session outside the React tree and reads and writes only the store. The
opening screen in `page.html` stays until `boot.ts` has the peer's first answer.
`zig build source-check` (`tools/check/source_check/rooms_ui.zig`) holds the ids and classes the browser
proofs select on, and keeps `net.ts` and `store.ts` off the document.

## Where the interface is heading

Present boundaries with a decided direction, so a session picking one up
starts from the decision rather than re-opening it.

- **Media in messages.** Built, and the shape is worth knowing before you
  change it. The composer holds selected files locally. Send asks the room for
  one upload capability per file, publishes their records as one message, then
  fills those capabilities concurrently in bounded chunks. Every member can
  start reading the room-hosted blob immediately; a read at the moving edge
  parks on that file and wakes when its next bytes arrive. Holding an upload
  capability is the whole authority to fill that file, so `write` never names
  who is uploading.

  The room hosts the bytes rather than relaying a reference to the sender's
  own blob, and that was the decision. Sender-hosted media reads as the
  purer capability story until you follow it: the recipient must dial the
  sender, which a browser tab cannot answer without per-viewer WebRTC
  signaling, and the picture dies when the tab closes. Room-hosted media
  works for every client and outlives the poster, which is what a chat
  application means by posting a picture. The cost is that the server has
  ceilings to keep, and they are the interesting part of the design.

  `MAX_SERVER_ATTACHMENT_BYTES` bounds held media across every room, evicting
  the oldest file anywhere; the per-room `MAX_ROOM_ATTACHMENT_BYTES` and
  `MAX_ROOM_ATTACHMENTS` sit under it so no single room takes the lot. A
  dropped file's reference stays valid and breaks `blob-expired`, because
  answering an empty file is indistinguishable from a real one. Bytes still in
  flight are the opposite case: their message may already be visible and their
  parked readers must receive an answer, so they are refused rather than
  evicted, against the size an upload declares at `attach` and under the
  server-wide `MAX_SERVER_PENDING_BYTES`.
  That reservation is what `UPLOAD_IDLE_MS` exists for. Without it, declaring
  the largest file a room takes and then writing nothing would hold a share of
  the server's budget for as long as the connection lasted.

  How a file is met is decided in one place, `web/ui/media.ts`, and there are
  four answers. A picture draws in the line and opens full-screen. A video
  plays where it was posted and opens full-screen too. Sound gets a player and
  no viewer, because a player is the whole of what a listener wants.
  Everything else is a row whose one control fetches the bytes and hands them
  to the browser to save, in a single press: asking twice, once to fetch and
  once to save, is a seam from the implementation showing through.

  Two things make the log settle rather than jump. A sender measures a
  picture before posting it and the record carries that shape, so a reader
  reserves the right box before the bytes arrive. And that box shimmers while
  they are on the way, so a rectangle about to become a picture says so with
  the space it is already holding.

  The viewer is an overlay over the whole interface, beside Settings in
  `App.tsx` rather than inside a message, dismissed by its backdrop and by the
  one Escape chain that dismisses every overlay. It carries none of Settings'
  chrome: that is a panel because it is a form with fields and a title, while
  a picture is the content and a frame around it would only take space from
  it.

  Relaying a capability the *sender* hosts is still not something pancake can
  express: the draft says a reference imported from another session rides as a
  `desc:handoff-give` inline in the argument, and the receiver builds a local
  promise for it and redeems. pancake refuses such an argument today
  (`ForeignArgument`), and the reply path's transparent gifter is the only
  handoff arm it implements. That gap is `docs/boundaries.md`'s to record, not
  this feature's to work around.
- **Emoji breadth.** `web/ui/emoji.ts` is a curated table and the one
  authority the tray, `:code:` substitution, and completion derive from. The
  widening path is a generator that fills the same entry shape from a pinned
  CLDR-backed dataset at generation time, keeping the runtime dependency-free.
- **Filterable lists, and where `cmdk` fits.** The split is who owns focus.
  Inline completion happens inside the composer's textarea, which keeps focus
  and the caret while the list shows, and the query is a substring of the
  draft rather than an input's value. `web/ui/complete.ts` is written for
  exactly that, and the two parts that make it work — which sigil the caret is
  in, and how accepting splices back into the draft — are ours whatever draws
  the list.

  Every other filterable list in this interface would own its own input: a
  command palette, the sidebar's room and direct-line filter, a searchable
  emoji picker over the same table the tray reads, settings search. Those are
  where [`cmdk`](https://github.com/pacocoursey/cmdk) fits, and it is the one
  pre-approved dependency candidate for them. It is a combobox primitive
  rather than a palette widget: it renders inline, works without its own
  input, takes a custom ranking function or none at all, and brings keyboard
  navigation, groups, and tested ARIA. The price is that it brings four Radix
  packages with it, one of which is their dialog, into a page whose whole
  runtime dependency today is React. Worth paying once those surfaces exist
  together; not worth it for one listbox.
- **IRC is a front, not a netlayer.** An IRC server endpoint beside the web
  page — rooms as channels, nick claims as nicks — would let any IRC client
  join, the way the terminal clients already do. Carrying CapTP itself over
  IRC is refused: a 512-byte line protocol with a server that may inject
  cannot keep an OCapN session insertable only by its participants, which is
  the netlayer contract. The complete design (room links, directory peering,
  a channel bridge, and this front) is
  [the room links and IRC plan](../../docs/planning/rooms-locators-and-irc.md).

## Source map

| Path                 | Role                                                             |
| -------------------- | ---------------------------------------------------------------- |
| `server/main.ts`     | Directory and room host.                                         |
| `lib/protocol.ts`    | Directory, room, and direct-message verbs.                       |
| `lib/room_client.ts` | Shared application wrapper used by Deno and the browser.         |
| `lib/dm_*.ts`        | Direct inboxes, replies, and handoff choreography.               |
| `lib/locator.ts`     | TCP and iroh dialing for Deno clients.                           |
| `clients/`           | Deno, Python, Racket, Rust, and Zig clients.                     |
| `web/serve.ts`       | Page server, room supervisor, and relay endpoint.                |
| `web/relay.ts`       | Byte relay and browser rendezvous bridge.                        |
| `web/ui/`            | Browser peer and interface.                                      |
| `web/ui/net.ts`      | The peer itself: sessions, rooms, and direct messages.           |
| `web/ui/store.ts`    | Every fact the interface shows, and the verbs that change them.  |
| `web/ui/boot.ts`     | Hands the page from the opening screen to the React app.         |
| `web/ui/*.tsx`       | The React components that draw from that store.                  |
| `demos/`             | Command-line scenario orchestrators.                             |
| `test/`              | Server, relay, browser, and direct-message checks.               |
