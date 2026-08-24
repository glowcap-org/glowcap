# Developing and operating Rooms

This guide collects the details needed to test, extend, or deploy Rooms. Start with the [Rooms overview](README.md) if
you only want to run the application.

## Demo controls

`zig build demo-rooms` chooses an available port and starts its own server. Pin the port when another process needs to
find it:

```sh
zig build demo-rooms -Dport=9099
```

Attach mode runs the demo clients against an existing server and leaves that server running:

```sh
zig build demo-rooms -Dport=9099 -Dattach=true
```

## Serving on a LAN

The TCP room binds loopback by default. Two knobs open it to a local network, as flags on the web supervisor or as env
vars on the room server (`PANCAKE_ROOMS_BIND` and `PANCAKE_ROOMS_ANNOUNCE_HOST`; a flag is forwarded to the server as
its env var, and setting the env vars directly keeps working):

```sh
zig build rooms-web-tcp -- --bind=0.0.0.0 --announce-host=192.168.1.20
```

`--bind` is the host the room server listens on, and `--announce-host` is the dialable hostname it prints and
advertises, which is also the address the page's relay will open for tabs served from other machines. Open
`http://192.168.1.20:8000` from any machine on that network. Remember what the transport is: `tcp` is cleartext and
proves nothing about who is on the other end, so a room exposed this way is readable by everyone on that network. For
anything beyond a trusted LAN, serve over iroh (`zig build rooms-web`) instead.

## Hosting the room as an onion service

`zig build rooms-web-onion` publishes the room directory as a Tor onion service (`--transport=onion` on `serve.ts`)
while the page itself is still served over HTTP as usual. The supervisor starts a private Tor under a temporary
directory and stops it with the process; set `PANCAKE_ONION_SOCKS` and `PANCAKE_ONION_CONTROL` to use a Tor you already
run (it needs an open control endpoint, which a distribution's Tor does not ship by default).

Three things are worth knowing before reaching for it:

- The onion address is the service key, and the room server keeps that key as `onion-key` in `PANCAKE_ROOMS_STATE`. The
  development default is a temporary state directory, so the address lives as long as the supervisor; set
  `PANCAKE_ROOMS_STATE` when the address must survive restarting it.
- Tor returns the address before publishing its descriptor, so a peer outside may need retries for some seconds after
  the `ROOMS-SERVER-LISTENING` line. This page's own tabs are unaffected: the relay carries an admitted onion target to
  the service's local forward endpoint (the room port on loopback), the same bytes a circuit would deliver there. The
  relay opens no circuits itself, so it reaches no onion service other than the supervised room's own.
- A terminal client needs an onion-capable runtime to dial through Tor; `apps/rooms/demos/onion_demo.ts` is the working
  example. The plain `chat.ts` command the TCP and iroh runs print does not apply here.

## Watching the room live

The room server can broadcast its own protocol activity as a timeline the [ocapnviz](../ocapnviz/) viewer draws. Start
the server with `--viz` (or `PANCAKE_ROOMS_VIZ=1`), switch the viewer to **Live**, and point the Source sturdyref field
at the printed `ROOMS-VIZ-LISTENING` capability. The endpoint serves on port 9300; `PANCAKE_ROOMS_VIZ_PORT` changes that
default and enables nothing on its own. Enabling also mints the viz capability: one swiss number, persisted under
`PANCAKE_ROOMS_STATE` and printed as a `ROOMS-VIZ` token line, which the endpoint requires of every socket — reading the
timeline and writing traces into it alike. The sturdyref carries that swiss as its swissnum, so the viewer needs nothing
beyond the announcement:

```sh
deno run --allow-ffi --allow-net --allow-read --allow-env \
  apps/rooms/server/main.ts 9099 --viz
```

Entering Live connects to the feed. Press **Record** to capture: every session the room accepts, every message in either
direction, and every close draws on the stage from that moment. **Stop** hands the capture to Play, where it replays
like any other recording. The stream is the same versioned timeline schema `pancake griddle run` prints.

Direct messages never go through the room, so each member also publishes its own trace to the same viz endpoint. A
browser tab reaches it through its own page origin: `/viz` and `/publish` on the web server carry the socket to the
endpoint, so the endpoint's own port never has to be published to the browser's host (in the devcontainer it is not),
and an HTTPS page keeps working where a bare `ws://` port could not. Reaching it is still not the authority to publish:
the tab's sending arms only while it holds the viz swiss, taken through the "Protocol visualizer" toggle in Settings
under Capabilities (the same take-and-remember flow as the other operations capabilities, presented to the endpoint rather
than fetched on the directory session). What it sends travels on a socket that carries nothing back but the endpoint's
admission mark. The conversation stays private; the timeline only merges the telemetry, and when both ends of one
conversation report it, the endpoint draws it once. What a tab sends is who it talked to, when, which verb, and how many
bytes, never the bytes themselves: the other end of a direct message never agreed to appear on a shared timeline. The
room server publishes its own frames in full, so a room line still shows its bytes on the timeline and a direct message
never does.

The same works with the browser UI. The web supervisor forwards the flag to the room server it spawns, so `-Dviz` on
`rooms-web` or `rooms-web-tcp` traces the room and every tab's sessions with it:

```sh
zig build rooms-web -Dviz
zig build rooms-web-tcp -Dviz
```

The supervisor keeps one room identity across child crashes. A child that had been serving and then died comes straight
back; one that exits the moment it starts, which is what a taken port or an unreachable state directory looks like, is
restarted more slowly each time up to half a minute, so the line it printed about why stays readable instead of
scrolling past under copies of itself.

Its development default is a private temporary `PANCAKE_ROOMS_STATE` directory that lives as long as `serve.ts`; set
`PANCAKE_ROOMS_STATE` yourself when the identity and issued room links must also survive restarting the web supervisor.
The container deployment does this with its `rooms-state` volume.

Cargo must be on `PATH` for the iroh transport sidecar; Deno is required for the UI either way. The TCP form drops the
Cargo requirement and the encryption with it. Either command prints a `ROOMS-VIZ-LISTENING` line once the room server is
up. Open [ocapnviz](../ocapnviz/) (`cd apps/ocapnviz && bash dev.sh`), switch the top bar to **Live**, and give the
Source field that sturdyref.

## The IRC gateway

`--irc` (or `PANCAKE_ROOMS_IRC=1`) mints a fifth operator capability, printed as `ROOMS-IRC`: holding it bridges IRC
channels into this directory. `joinIrc(network, channel, host, port, tls, nick)` stands the channel beside the native
rooms — entered, listed, and watched like any of them, IRC members appearing as `irc/<nick>` — and `partIrc` takes it
down. One shared IRC connection per bridged channel is the read feed, the standalone bridge's machinery made dynamic.
Members are IRC citizens through per-reader connections: subscribing seats them on the channel under their own nick
(projected when it does not fit IRC's alphabet), a post reaches IRC as them before the room echoes it or fails closed
with the network's reason, and leaving takes their nick off the channel. The shared feed can log into a
registered account: the pane's optional account and password fields ride the join once (TLS required), the server
holds them in memory beside the connection they authenticate — never in a snapshot, never in the journal, gone with
the bridge — and a restart means re-bridging with them again. A member logs into their own
registered account with `/irclogin account password` in the bridged room: the credentials ride the room verb once,
live only in the seat beside the connections they authenticate, and go with the seat; the next message opens their
authenticated connection. A cleartext bridge refuses them, the same custody rule as the feed's. Sitting in a bridged room is joining the channel: the seat opens at
subscribe, `/me` crosses as the CTCP ACTION it is in both directions, stepping away tells the channel through a live
seat, and IRC topic changes land as the room's own topic line. A seated member is one person everywhere:
the feed suppresses their own channel echo (their join, their lines, their roster entry) so they never appear twice,
a services force-rename follows them (the room tells them their new outward nick), and a dropped seat is said in the
room, not only the journal. In the interface every bridged identity wears the one IRC color and an IRC mark beside
its bare nick. The gateway's `snapshot` lists each bridged channel with
its connection state.

## Room history

`--history` (or `PANCAKE_ROOMS_HISTORY=1`) has the room server keep each listed room's last lines and answer them to
any member who asks; the browser asks on entering a room whose log is empty and stands the answer under a divider that
names the room as the keeper. A policy flag rather than a capability: there is no swiss number, only a stated
retention. With `PANCAKE_ROOMS_STATE` set the kept lines live in JSONL files under `<state>/history/` and survive the
server restarting; without it they live for the life of the process. Private rooms never record: a private room is
reference-only, and keeping its lines is a retention decision its holders never made. A server without the flag
refuses the verb, which clients read as an empty answer. Direct messages are separate on purpose: their plaintext is
end-to-end encrypted and is kept only in the reader's own browser, under the Advanced switch.

## Operations capabilities

Swiss numbers persist under `PANCAKE_ROOMS_STATE`, one file per capability, and
`deno run --allow-read --allow-env apps/rooms/server/capabilities.ts` prints the
token lines for whatever that directory holds — the same lines the boot block
prints, readable any time after startup.

Start the web UI with `--diagnostics` (or `-Ddiagnostics` on the zig step) and the room server publishes a second Host
object under an unguessable swiss number — the same kind of bootstrap name as `directory`, not a page flag. The process
prints that swiss number. `--admin-listeners` (or `-Dadmin-listeners`) publishes a listener-admin object the same way,
and its swiss number prints beside the first.

`--peering` (or `-Dpeering`) publishes the authority to add durable rooms from another directory. `ROOMS-PEERING` prints
its swiss number. A successful `publishDurableRoom` returns a lease whose `ready` answer marks the publication live and
whose `revoke` removes that exact generation from discovery.

The visualizer capability: `--viz` (or `-Dviz`) serves the timeline endpoint and mints the
capability described above, the same enabling shape as the others.

In Settings → Capabilities, each capability has its own toggle, and the toggle is the capability: flipping one on opens a
form asking for its swiss number, and only a successful take lands the toggle on — dismissing the form leaves it off.
Diagnostics and listeners are fetched on the live directory session; the visualizer swiss is presented to the timeline
endpoint, whose admission answer is the take. The form can also remember the swiss number on that device, opt-in and per
home (the directory for the first two, the endpoint URL for the visualizer), so a reload takes the capability again
unasked; turning the toggle off, or a failed re-take, erases what was remembered. While any capability is held, an
Operations control sits at the left of the Settings header's toggle row and stands the reader on the Operations page:
one address per held capability under `/ops`, behind a tab bar once two or more are held, with the rooms rail and
Settings still in reach and possession gating an address arrived at cold. The diagnostics pane lists the names this directory
currently holds (rooms, occupants, registrations, durable links), then two trouble journals: the server's own
bounded ring of failures that had no caller left to reach, served as `trouble` rows on the same snapshot, and the
page's ring of its console-only failures, drawn in a This-page well beside it. The listeners pane draws one switch per transport the
server itself lists, each described in the owning provider package's words: on brings that listener up, off takes it
down, and a row that is up carries its copyable locator. A row that is down draws one field per knob its `up` accepts —
the tcp family's bind host, port, and advertised host, the relay family's relay (prefilled with this page's own) — and a
blank field means the default the server's own hint names. The listener serving this very page is marked and its switch
is disabled, a seat the server already knows cannot come up stands disabled with its reason, and a flip the server
cannot honor answers with its reason in words, in the row that asked. The peering pane publishes a room this tab has
joined on another directory into this one, durably: pick the room, name it, and it lists beside the local rooms until
revoked. The rows under the form are this tab's own publications, each with the one revocation its lease carries; a tab
holding no other directory is told to join one first. The visualizer pane names the endpoint this tab publishes to,
whether the socket is up, and holds the endpoint override (blank publishes to this page's own `/viz`; saving reloads the
window). Help, from the icon in the Settings header, says what a swiss number is. Turning a toggle off drops that
capability, and a reconnect drops the two session-fetched ones the same way; the visualizer capability lives on the
endpoint socket and survives a directory reconnect. A respawn of the same `PANCAKE_ROOMS_STATE` republishes the same
swiss numbers, so the printed names keep answering.

```sh
zig build rooms-web -Ddiagnostics
zig build rooms-web-iroh -Ddiagnostics -Dadmin-listeners -Dviz
zig build rooms-web-tcp -Dadmin-listeners
```

Without a swiss number, fetch fails the way any unknown bootstrap name fails. The directory itself grows neither an
inspect nor a listeners method.

Attach mode is the one caveat: if an orphaned room server already holds the room port, the web server attaches to it
instead of spawning its own child, and tracing follows however that orphan was started. `--diagnostics` in that case
does not print a swiss number from this supervisor's empty state directory — it would name a capability nothing on the
attached server answers. Kill stray servers first when the `ROOMS-VIZ-LISTENING` line doesn't appear.

`PANCAKE_ROOMS_VIZ_PORT=0` takes whatever port is free, and the announce line names the one it bound. A browser tab
cannot find an endpoint chosen that way, because the port is picked inside the room server and the page is served by
another process. Keep a fixed port when you want members' direct messages on the timeline, or open the page with
`?viz=ws://127.0.0.1:<port>/` (the same override the Visualizer pane holds once the capability is taken) — and in every
case the tab still publishes only while its "Protocol visualizer" toggle holds the viz swiss.

## Bringing a Spritely Goblins vat into the room

Every peer described so far is a pancake peer, and a room of pancake peers uses pancake's own wire profile. A
[Spritely Goblins](https://spritely.institute/goblins/) vat speaks the OCapN v1.0 baseline instead, and it can join the
same room: each connection settles its own profile from what the two ends offer, so the Goblins member arrives on the
baseline while the pancake members keep talking to each other on the native one.

Watching that happen takes three terminals and a browser.

Start the browser UI with the live timeline switched on. The shortest walkthrough uses the cleartext TCP testing adapter
and needs no transport sidecar. The repository also supplies the iroh netlayer used by the automated encrypted scenario;
it is an adapter for Goblins rather than a transport shipped by Goblins itself. The TCP room server listens on port
9099:

```sh
zig build rooms-web-tcp -Dviz
```

Open `http://localhost:8000`, enter the room `general`, and pick a nickname. That is your pancake member.

In a second terminal, start the viewer, switch the top bar to **Live**, and give the Source field the
`ROOMS-VIZ-LISTENING` sturdyref:

```sh
cd apps/ocapnviz && bash dev.sh
```

In a third terminal, join the same room as a real Goblins vat and start typing:

```sh
racket -y conformance/goblins-peer/racket/rooms-chat.rkt \
  127.0.0.1:9099 general goblins-carol 9200
```

This is a chat terminal like `clients/deno/chat.ts`, except that the peer on the other end of it is a Goblins vat rather
than a pancake one. It takes the same commands — `/list`, `/open <name>`, `/enter <name>`, `/leave`, `/help` — and
Ctrl-D quits. Anything else you type is a line in the room. The trailing `9200` is the port the vat's own netlayer
binds, which is where other members reach it privately.

What you type appears in the browser, what the browser types appears here, and on the viewer's stage the new session is
labeled `goblins-carol` and drawn on `syrup/v1_0` while yours stays on `capnp/next`: one room, two implementations, each
connection on the profile its own two ends could agree on.

`zig build goblins-rooms` runs the same meeting without the browser and checks it: a scripted Goblins vat and a pancake
client exchange lines in one room, and the server's own trace has to show the two profiles. The scripted member is
`conformance/goblins-peer/racket/rooms-member.rkt`, next door to the interactive one.

### Direct-messaging the vat

Click the vat's name in the member pane and type. The room introduces you and then carries none of it: the line runs
between your browser and the vat, and the viewer draws it as a session of its own that disappears when you close the
thread. The vat prints it as `(dm) <you>`, and anything it types back with `/dm` comes home over the connection your
message arrived on.

Over cleartext TCP this needs one thing from the server. The browser reaches everything through the relay, and the relay
will not open a cleartext socket to an address a page named, so start the server with the vat's own address listed:

```sh
PANCAKE_RELAY_TCP_PEERS=127.0.0.1:9200 zig build rooms-web-tcp
```

Over iroh there is nothing to list: an iroh destination has to be a peer holding the key it is named by, and the relay
dials any of them. `zig build goblins-rooms-dm` and `zig build goblins-rooms-dm-iroh` run the whole conversation, one
arm each, and check that it reaches the timeline and leaves it again.

The room may already contain people. Each demo client checks broadcasts against the demo's own roster, so other members
may appear in the transcript without affecting the result.

The main scenarios are:

| Command                                  | What it checks                                                                                                                            | Extra requirements                                   |
| ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------- |
| `zig build demo-rooms`                   | Five binding clients share one TCP room.                                                                                                  | Deno; optional language runtimes join when present.  |
| `zig build demo-rooms-iroh`              | The same room over encrypted iroh QUIC.                                                                                                   | Deno and Cargo.                                      |
| `zig build demo-rooms-dm`                | A room introduces two TCP members, which then message off-room.                                                                           | Deno.                                                |
| `zig build demo-rooms-dm-iroh`           | The same handoff across three iroh endpoints with explicit hints.                                                                         | Deno and Cargo.                                      |
| `zig build demo-rooms-dm-iroh-discovery` | Handoff using a node id resolved through public n0 discovery.                                                                             | Deno, Cargo, and internet access.                    |
| `zig build goblins-rooms`                | A real Goblins vat and a pancake client hold one room, on different wire profiles.                                                        | Deno, Racket, and the `goblins` collection.          |
| `zig build goblins-rooms-dm`             | A browser and a real Goblins vat hold a direct message off-room over TCP, and the vat starts one of its own with a native pancake member. | Deno, Racket, `goblins`, and Playwright Chromium.    |
| `zig build goblins-rooms-dm-iroh`        | Both Goblins-facing DM directions over encrypted iroh QUIC: the vat exports to the browser, then redeems a native member's introduction.  | Cargo, Deno, Racket, `goblins`, Playwright Chromium. |
| `zig build rooms-web`                    | Browser peer and iroh room, the ordinary way to run the UI.                                                                               | Deno and Cargo.                                      |
| `zig build rooms-web-iroh`               | The same UI, named by transport.                                                                                                          | Deno and Cargo.                                      |
| `zig build rooms-web-tcp`                | The same UI over cleartext TCP, for a peer that speaks nothing else.                                                                      | Deno.                                                |
| `zig build rooms-web-onion`              | The same UI with the room directory published as a Tor onion service.                                                                     | Deno and Tor.                                        |
| `zig build rooms-web-relay-peer`         | A wasm peer drives the directory through the relay, no browser.                                                                           | Deno.                                                |
| `zig build rooms-web-browser-peer`       | A real browser runs the wasm peer through the relay.                                                                                      | Deno and Playwright Chromium.                        |
| `zig build rooms-web-page`               | The whole page as a peer: join, round-trip a line, and hold both layouts.                                                                 | Deno and Playwright Chromium.                        |
| `zig build rooms-web-routes`             | The page address is shareable: a cold link arrives named, back and forward walk it, and following one never moves the rail.               | Deno and Playwright Chromium.                        |
| `zig build rooms-web-reconnect`          | The page survives losing its room server and re-enters on its own.                                                                        | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm`                 | Browser-to-native direct messaging.                                                                                                       | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm-tabs`            | Two tabs cold-dial through one relay and message off-room.                                                                                | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm-native`          | A native peer cold-dials a browser member through the relay rendezvous.                                                                   | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm-webrtc`          | Two members DM over a DataChannel the room only signaled; the live timeline must name `webrtc`, never relay substitution.                 | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm-retarget`        | A direct conversation does not follow a reused nickname.                                                                                  | Deno and Playwright Chromium.                        |
| `zig build rooms-web-dm-reopen`          | Reopening a closed conversation opens a second connection, and that one carries.                                                          | Deno and Playwright Chromium.                        |

The browser and demo commands are separate from `zig build check` because they depend on external runtimes or a real
browser. The devcontainer image carries the Playwright Chromium these rows want, so there is nothing to install first;
elsewhere, `tools/check/playwright-preflight.sh` names the pinned version and how to get it.

`rooms-web`, `rooms-web-iroh`, `rooms-web-tcp`, and `rooms-web-onion` accept `-Dport=9099` when the HTTP port must be
fixed, `-Ddiagnostics` to mint an inspect capability, `-Dadmin-listeners` to mint the listener-admin capability, and
`-Dviz` to serve the live timeline endpoint with its capability.

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

The one-shot clients accept a locator, room, nickname, message, and expected roster. Passing only the sender as the
roster means “post and exit,” which is handy when adding another language to a live room:

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

The page loads the WebAssembly `@pancake/web` Host. It is an OCapN peer: it dials the directory, holds room
capabilities, hosts inbox objects, and redeems introductions itself.

A browser cannot open raw TCP or iroh sockets, so `web/serve.ts` exposes a WebSocket byte relay:

```text
browser peer ──WebSocket /relay──▶ serve.ts ──TCP or iroh──▶ peer
```

The relay does not parse CapTP or hold application capabilities. The keyed session passes through it end to end. Local
development uses `ws://`; HTTPS deployments use `wss://`.

The TCP relay is pinned to its Rooms server. The iroh demo relay accepts any key-verified iroh node so that a browser
can redeem introductions. That makes it a possible bandwidth amplifier; a production deployment should restrict the
allowed destinations. An onion target is pinned harder still: only the supervised room's own service is admitted, and it
is carried to that service's local forward endpoint rather than through a circuit.

The relay also refuses a dial whose `Origin` names a host other than the one it was asked on. Otherwise a page from
elsewhere could use a reader's local relay to reach whatever the rules above still allow. The shipped page is served by
`serve.ts` and dials the relay on the host it came from, so it is unaffected. A test or probe that fabricates its own
page has to serve it from that same origin. A request with no `Origin` at all (every non-browser client) passes.

Browser peers also register a rendezvous identity with the relay. Another peer on the same relay — a browser tab, or a
native process whose host is configured with the relay's rendezvous mapping — can use that identity to bridge a fresh
connection to the held WebSocket. The bridge makes cold dial possible without putting the room in the message path. It
does not yet cover browsers on different relays.

A page opened with `?dm=webrtc` advertises a `webrtc` identity instead: direct messages then cross a WebRTC DataChannel
between the two tabs, and the room directory carries only the offer, answer, and candidate exchange as ordinary
capability messages (`offerSignaling` and the `signal*` verbs in `lib/protocol.ts`). The same choice is in Settings; a
URL that names `dm` or `viz` still wins over whatever this browser last saved.

## Application contract

The directory owns room discovery and introductions:

- `open(name)` and `enter(name)` return a room capability.
- `list()` reports populated rooms; `watch(inbox)` pushes directory changes.
- `register(...)` records a member's dialable identity.
- `introduce(nick)` returns the inbox that member minted for this caller.

A room grants a nickname when `subscribe(nick, inbox)` succeeds. Later `post(text)` calls need no sender field: the room
already knows which membership capability received the call. Leaving or disconnecting releases the nickname.

`subscribe` answers with a reference carrying `setTopic(text)`, and holding it is the authority to say what the room is
about. Every member is answered with one, because the room has no ranks to hand out, and because it is a reference
rather than a rank a member can pass it to somebody who is not even here. The room states its topic to each arrival and
broadcasts every change with the `topic` tag, so a client that has never heard of topics still shows the line saying it
moved.

`away(reason)` says this membership has stepped away and `away("")` says it is back. Nothing is handed over for it: a
member's own standing is theirs to state, and the room writes it against the membership that called rather than against
a name anybody could type. The room tells each arrival who is already away, on the same line every later change arrives
on.

`post` answers with a reference to the line it made, and holding that reference is the authority to `edit(text)` or
`withdraw()` that one line. The room asks nobody whether the line is theirs, because a member who does not hold the
reference cannot form the request. That also makes the authority passable: a member can hand it to somebody else, and a
room could keep a copy of its own to give whoever it wants moderating, without either side learning what a moderator is.
A room that answers a post with nothing is an older room, and a client meeting one simply has no line to change.

`postFiles` answers the same reference, so a file line is a line like any other. `edit(text)` changes its caption and
leaves its files alone; `refile(caption, ...keep)` changes the files, keeping the ones whose indices it names and adding
the connection's freshly-staged uploads after them; and `withdraw()` takes the whole line back, its files with it.
Refiling a line down to no files and no caption withdraws it, because an empty line is nothing.

Direct inboxes follow the same rule. `dm(text)` carries no claimed sender because each inbox was minted for one
introduced peer. A direct conversation is keyed by that introduction, not by the room nickname. `dm` answers a line
handle too, the direct sibling of the reference `post` answers, but minted by the receiver — a direct line has no room
to hold it, and the receiver is the durable owner of what a direct message shows. Holding it lets the sender `edit`,
`refile`, or `withdraw` the message afterwards; a direct `refile` carries its new files inline rather than staging them,
because there is no store to stage on, and names the receiver's own kept files by index. The handle lives on the direct
connection, so it dies with it: a line whose connection has gone cannot be changed, the same way a room line's reference
dies with its session.

The application wrappers use only the public binding surface: connect, fetch, spawn, send, and serve. Protocol tables,
export positions, and frame movement remain below them.

## The browser interface

The page is a conversation. A rail lists rooms and direct lines. The workarea is the column for the one you have open: a
topbar, a log of messages, and a composer that floats over the bottom of that column. The log owns the messages and the
fade at their lower edge. The composer holds the controls that sit on that edge. Pressing the room or direct-message
name in the topbar opens what this tab already knows about that conversation — the directory that carries it, the
session, the path a direct line takes — and `/details` (also `/info`) opens the same card. The locator on that card is
the directory's, labeled as such, unless this tab already holds a room link from `/link` or from `/join` of one — then
it copies that sturdyref, labeled as a room link, and does not mint one by looking. `/link` with no argument is this
room; `/link lobby` mints a listed room's link. `/join` is a destination — a name or a locator — never the conversation
it was typed in. `/join` of a locator seats from what subscribe says about that occupancy — listed or unlisted — not
from a method asked first, and not from the label a private room may share with a public one. The directory named on it
opens that directory's card. A room's card is also where you say where you are in it, and where you leave it; a direct
line's card closes the conversation. A long refusal stays two lines where it appeared; Show opens the rest on its own
card. The topbar stripe and the welcome card take their color from the rail row that opened the conversation, room or
direct line. On the join screen the topbar keeps a stripe from rail selection, which is not the join card's aim. The
rail's teal-to-orange header fade stays static. Orange controls stay orange.

It is a React application under `web/ui/`, entered through `main.tsx` and bundled to `page.js` by `serve.ts`. Styles
live in `page.css` plus the sheets it imports, split along those sections. Shared UI state lives in `store.ts`: every
fact the page shows, and every verb that changes one. State that belongs to one control stays in that component: a
half-typed room name, an open emoji tray, the composer caret. UI state must not live in the DOM. An element's own value
outlives closing the control or switching conversations, and comes back carrying an earlier intention.

`net.ts` owns the CapTP session outside the React tree and reads and writes only the store. The opening screen in
`page.html` stays until `boot.ts` has the peer's first answer. `zig build source-check`
(`tools/check/source_check/rooms_ui.zig`) holds the ids and classes the browser proofs select on, and keeps `net.ts` and
`store.ts` off the document.

### Form answers

A field a reader did not fill is not state to be kept. It is an answer, and an answer only makes sense beside the
question that was asked. Following a link to a room asks a different question from pressing "add a room" in the rail,
and both differ from opening the page cold, so a form that keeps one set of values for all three will get two of them
wrong.

`intent.ts` is where that is decided. Every surface that can put the reader in front of a question files an **act**
saying where it came from and what it names, and presentation resolves each field from the strongest evidence available:

| Evidence  | Means                                                                              |
| --------- | ---------------------------------------------------------------------------------- |
| `edited`  | The reader typed it here, under this act.                                          |
| `named`   | The act said it outright. A link to `/room/general` names that room.               |
| `implied` | The act did not say it, but standing where it stood has only one reading.          |
| `recent`  | Not in this act at all: what this browser used last, written when a join succeeds. |
| `default` | Nobody has an answer, so the application offers its own.                           |

An act carries three sources, and each is a reader doing something: `press` for a control on this page, `link` for an
address followed or typed, `restore` for this browser reopening what it had. A presentation the application causes by
itself files no act, which is the whole answer to "what happens when there is no intent". Filing one would put words in
the reader's mouth; filing none leaves the last real answer standing and leaves anything half-typed where the reader
left it.

Two consequences are worth stating because they are easy to get wrong. An act naming an _empty_ value still beats a
remembered one, since a link to a room in this page's directory says "here" by saying nothing about where; that silence
is an answer. And an override the reader types belongs to the act they typed it under, so going somewhere else drops it
without anybody having to clear anything.

The join card is the surface this runs today, in `joining.ts`. It says what it is answering once, in its opening line,
rather than annotating each field it filled: a card reached by following an address is answering that address, and a
card opened from the rail is answering nothing in particular, so that is the one sentence that differs between them. A
room link pasted into the locator field is the same idea from the other direction: the swissnum path is what makes it a
way in rather than a directory address, so the card retitles that field and redeems the link instead of asking to enter
a name on a peer.
While that card is the workarea, the rail's room panel is a second view of it: one room name, one lock, and one
destination, all read from the card's own answers and all changed from either side. Picking a directory on the panel's
line writes the card's locator exactly as typing in the panel's field writes the card's room name, so the panel's line,
the card's field and the card's stripe move together because all three read that one answer. Those picks are edits and
file no act, which is what lets them leave every other answer standing; an act would supersede the one the reader is
answering and take what they had typed under it away. The last row of that menu is the way to an address this tab does
not hold, and both surfaces offer the same one: on the card it puts the caret in the field the menu hangs from, and from
the panel, which has nowhere to type an address, it hands that same field over.

The two halves stay on screen together, because working in one is not leaving the other. A caret or a press landing on
the card leaves the panel standing, and what puts the panel away is a conversation opening, which is the moment there
stops being a card for it to be a view of. With a room open there is no card to be a second view of, so the panel names
the directory of the room being read — standing in a room has one reading of where the next one goes — and stepping out
to another directory is then an ordinary press that files an act, leaving the panel where it is, since that press has
just given it its other half. That press ends where the menu's last row ends, in the card's locator field: a reader who
asked to change directory is about to name one, and arriving in front of a card with the caret nowhere asks them to go
and find the field the press was about.

The rooms list holds one panel however many directories this tab is on. Where a room lands is something the panel states
and offers to change, rather than something the place the panel sits in decides, so a second directory adds no second
field: the destination line names the directory the room is going to, and the menu under it picks another one the tab
already holds or steps out to an address it does not. `intent_test.ts` drives the precedence itself and
`web_routes_test.ts` drives which act each route files. Other forms in the page hold values that belong to one control
and are cleared when it closes, so they have no act to answer; a form that starts keeping a value across screens needs
one.

### Failures and pending work

A failure lands on the thing that failed, with the retry attached to that thing, and it interrupts nothing else. In
order of preference: the act's own widget keeps its control and gains the reason, the way a bubble tints "Not sent" with
retry on it and a refused form answer lands beside the field that asked; the conversation the act belongs to carries a
system line when the act has no widget of its own, with the way forward in the same sentence; a condition that stays
true lives on the surface that owns the claim, the way the directory card says while nobody can reach you for direct
messages; a toast is for a failure whose home is already gone; and a modal asks only when nothing can proceed until the
reader answers, which today means the join card and a capability take. Logging a reader-facing failure to the console
instead of one of these is swallowing it.

Work in flight follows the same rule without blocking anything: the pending state shows on the act, sized to what it can
usefully say. A shape that will be filled shimmers, the way an attachment does on its way in. A control that was pressed
goes busy where it stands (`Button`'s `busy`, a listener switch mid-flip). An act worth narrating keeps saying what it
is doing and offers the way to stop it (`WorkingAction`, the join's stop mark). Tab-wide work is a sentence in the
rail's foot ("entering #x…", the reconnect narration). The word beside a spinner names the act actually running: a
peering row still publishing says "publishing…" rather than lending its busy state to the Revoke control beside it,
because a spinner on the wrong verb reports an act nobody filed.

## Media

The composer holds selected files locally. Send asks the room for one upload capability per file, publishes their
records as one message, then fills those capabilities concurrently in bounded chunks. Every member can start reading the
room-hosted blob immediately; a read at the moving edge parks on that file and wakes when its next bytes arrive. Holding
an upload capability is the whole authority to fill that file, so `write` never names who is uploading.

The room hosts the bytes rather than relaying a reference to the sender's own blob. Sender-hosted media reads as the
purer capability story until you follow it: the recipient must dial the sender, which a browser tab cannot answer
without per-viewer WebRTC signaling, and the picture dies when the tab closes. Room-hosted media works for every client
and outlives the poster, which is what a chat application means by posting a picture. The cost is that the server has
ceilings to keep.

`MAX_SERVER_ATTACHMENT_BYTES` bounds held media across every room, evicting the oldest file anywhere; the per-room
`MAX_ROOM_ATTACHMENT_BYTES` and `MAX_ROOM_ATTACHMENTS` sit under it so no single room takes the lot. A dropped file's
reference stays valid and breaks `blob-expired`, because answering an empty file is indistinguishable from a real one.
Bytes still in flight are the opposite case: their message may already be visible and their parked readers must receive
an answer, so they are refused rather than evicted, against the size an upload declares at `attach` and under the
server-wide `MAX_SERVER_PENDING_BYTES`. That reservation is what `UPLOAD_IDLE_MS` exists for. Without it, declaring the
largest file a room takes and then writing nothing would hold a share of the server's budget for as long as the
connection lasted.

How a file is met is decided in one place, `web/ui/media.ts`, and there are four answers. A picture draws in the line
and opens full-screen, fitted to the stage. When the file is larger than the window, a click or the bar's zoom control
shows it at actual size and the stage scrolls. A video plays where it was posted and opens full-screen too. Sound gets a
player and no viewer, because a player is the whole of what a listener wants. Everything else is a row whose one control
fetches the bytes and hands them to the browser to save, in a single press: asking twice, once to fetch and once to
save, is a seam from the implementation showing through.

Two things make the log settle rather than jump. A sender measures a picture before posting it and the record carries
that shape, so a reader reserves the right box before the bytes arrive. And that box shimmers while they are on the way,
so a rectangle about to become a picture says so with the space it is already holding.

The viewer is an overlay over the whole interface, beside Settings in `App.tsx` rather than inside a message, dismissed
by its backdrop and by the one Escape chain that dismisses every overlay. It carries none of Settings' chrome: that is a
panel because it is a form with fields and a title, while a picture is the content and a frame around it would only take
space from it.

## Present boundaries

These are decided directions, so a session picking one up starts from the decision rather than re-opening it.

- **Emoji breadth.** `web/ui/emoji.ts` is a curated table and the one authority the tray, `:code:` substitution, and
  completion derive from. The widening path is a generator that fills the same entry shape from a pinned CLDR-backed
  dataset at generation time, keeping the runtime dependency-free.
- **Filterable lists.** The split is who owns focus. Inline completion happens inside the composer's textarea, which
  keeps focus and the caret while the list shows, and the query is a substring of the draft rather than an input's
  value. `web/ui/complete.ts` is written for exactly that, and the two parts that make it work — which sigil the caret
  is in, and how accepting splices back into the draft — are ours whatever draws the list.

  Every other filterable list in this interface owns its own input. The rail's filter already does, and it is
  deliberately small: one question per property of a room, drawn from `web/ui/sidebar/filter.ts`, with no ranking and no
  reordering to speak of. The ones still to come are larger: a command palette, a searchable emoji picker over the same
  table the tray reads, settings search. Those are where [`cmdk`](https://github.com/pacocoursey/cmdk) fits, and it is
  the one pre-approved dependency candidate for them. It is a combobox primitive rather than a palette widget: it
  renders inline, works without its own input, takes a custom ranking function or none at all, and brings keyboard
  navigation, groups, and tested ARIA. The price is that it brings four Radix packages with it, one of which is their
  dialog, into a page whose whole runtime dependency today is React. Worth paying once those surfaces exist together;
  not worth it for one listbox.
- **IRC stays at the application edge.** `zig build rooms-irc-bridge` presents one channel as a Rooms directory. It is
  read-only by default; its two-way mode authenticates a registered nick with SASL and relays bounded, throttled posts.
  `zig build rooms-irc-front` is the inverse edge: ordinary IRC clients hold native Directory, Room, and introduced
  direct-message capabilities through a bounded listener. Its external IRC socket requires TLS; its direct endpoint is
  Noise-sealed by default, with explicit authenticated iroh and loopback-only Goblins TCP postures. Carrying CapTP
  itself over IRC is refused: a 512-byte line protocol with a server that may inject cannot keep an OCapN session
  insertable only by its participants. The complete direction is in
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
| `irc/`               | Bounded IRC grammar, channel bridge, and native Rooms front.     |
| `web/serve.ts`       | Page server, room supervisor, and relay endpoint.                |
| `web/relay.ts`       | Byte relay and browser rendezvous bridge.                        |
| `web/ui/`            | Browser peer and interface.                                      |
| `web/ui/net.ts`      | The peer itself: sessions, rooms, and direct messages.           |
| `web/ui/store.ts`    | Every fact the interface shows, and the verbs that change them.  |
| `web/ui/intent.ts`   | What the reader meant, and how firmly, for forms to answer from. |
| `web/ui/boot.ts`     | Hands the page from the opening screen to the React app.         |
| `web/ui/*.tsx`       | The React components that draw from that store.                  |
| `demos/`             | Command-line scenario orchestrators.                             |
| `test/`              | Server, relay, browser, and direct-message checks.               |
