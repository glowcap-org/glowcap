# Developing Rooms

This guide is for changing Rooms: how it is built and checked, how to run the
pieces by hand, what the objects on the wire are, and where the code lives.
The [Rooms overview](README.md) runs the application, [Operating Rooms](operating.md)
covers the server's grants and services, and the
[browser page's design contract](web/ui/README.md) covers the interface.

## Build steps

Every Rooms command is a `zig build` step. The ones a developer reaches for:

| Command | Does | Needs |
| --- | --- | --- |
| `zig build rooms-web` | Builds the services and the page, serves the page. `-Dtransport=tcp` or `onion`, `-Dport=`, server flags after `--` | Cargo, Deno. Tor for `onion` |
| `zig build rooms-dev` | React Fast Refresh by default. `-Dhot-reload=false` serves compiled generations directly. Both mint every operator capability, keep directory state under `.local/.state/rooms`, and print workspace and management links for a shared session under `.local/.state/rooms-session` | Cargo, Deno |
| `zig build rooms-server-test` | The installed server, production bundle, Vite configuration, and development lifecycle contracts (part of `runtime-check`) | Cargo, Deno |
| `zig build rooms-rust-test` | The Rust application contracts (part of `runtime-check`) | Cargo |
| `zig build rooms-peers-test` | The archive, session, and room server as installed processes: identity, restart, and signals (part of `runtime-check`) | Cargo |
| `zig build rooms-terminal-client-test` | The Zig, Rust, Python, and Racket client contracts | Cargo, Python, Racket |
| `zig build demo-rooms` | Five language clients share one TCP room. `-Dport=` pins the port, `-Dattach=true` joins a running server | Deno. Other runtimes join when present |
| `zig build demo-rooms-iroh`, `demo-rooms-onion` | The same tour over encrypted QUIC and over Tor | Cargo, Deno. Tor |
| `zig build demo-rooms-dm`, `demo-rooms-dm-iroh` | A room introduces two members who then message directly | Deno. Cargo |
| `zig build goblins-rooms`, `goblins-rooms-dm`, `goblins-rooms-iroh` | A real Goblins vat in the room, and direct messages with it | Racket with Goblins, Deno |
| `zig build rooms-web-page`, `rooms-web-dm`, `rooms-web-reconnect`, … | The browser proofs, each driving a real Chromium through the shipped page | Cargo, Deno, Playwright Chromium |

[`docs/build-steps.md`](../../docs/build-steps.md) documents every step,
including which ride `zig build check`, `runtime-check`, or `check-external`.
The devcontainer image carries the Chromium the browser proofs use.

Component edits use React Fast Refresh. Changes that reach page startup reload
the document: its Host, session and React root each belong to one document
lifetime. Refreshing startup in place would leave controls attached to an
earlier session. The development process tests check both update boundaries.

The browser proofs run concurrently, so name every proof you need in one
`zig build` invocation, or run the whole family with `rooms-web-proofs`. The
build prepares the browser assets once. Each proof starts `rooms-web` with
that immutable generation for its entire journey. Source compilation and
development refresh have separate process contracts. A change to a Rust crate
the browser module links needs `zig build rooms-browser-build` first.

### Browser gesture ownership

Room admission acquires a conversation without selecting it. The browser's
[opening owner](web/ui/session/managed/openings.ts) holds cancellation and
cleanup for each attempt. Before admission, cancellation releases preparation.
After dispatch, the original receipt remains held. If that cancelled attempt
later acquires membership, its owner releases that membership through an exact
departure command. Reconnecting a saved direct conversation closes its new
route while preserving saved messages and drafts.

Cancellation already supplies the decision for an uncertain admission. The
retained receipt owner continues it once automatically and releases acquired
membership. Command result adoption and departure cleanup settle separately,
so a lost departure reply resumes that departure without repeating admission.
A failed automatic continuation retains its diagnostic for explicit recovery.
Projection uses the receipt owner's cancelled result identity to exclude the
new room while departure is pending or refused. Cancellation also invalidates
projection without a workspace revision, so a late snapshot cannot present
that room as joined. Existing conversations remain independently owned.

The opening hands off to [navigation](web/ui/session/managed/navigation.ts)
before changing selection. Navigation saves the visible choice independently,
so hiding a successful form cannot cancel its receipt. A form observes its own
attempt, and a sidebar row observes the opening's target. The session tests and
browser departure and responsiveness scenes exercise these lifetime boundaries.
An explicit local choice leaves the directory view immediately. Background
selection saves preserve that view and its draft.

### Browser compiler boundary

`web/compiler.json` selects the production Deno invocation. Its `args` are
passed directly to Deno from `web/`, with `{outdir}` replaced by the publisher's
empty temporary directory. Its `inputs` list additional files that affect
compilation, including any helpers imported by the compiler configuration.
The recipe, those files, `deno.json`, and the lockfile participate in source
identity alongside the application sources and assets.

The compiler must emit `page.js` and its minified ESM chunks as sibling files.
Static and literal dynamic imports must resolve within that output. Browser
journeys exercise runtime-computed imports that inspection cannot resolve.
The publisher adds the page, CSS, fonts, Wasm, and revision metadata, then publishes the complete
generation atomically. It also owns compiler cancellation and the build
deadline. A bundler change therefore leaves serving and deployment intact.

The shared source entry `ui/page.js` gives both Vite and Deno the required
output name. To try `deno bundle`, replace the recipe with:

```json
{
  "args": ["bundle", "--config", "deno.json", "--platform", "browser", "--minify", "--code-splitting", "--outdir", "{outdir}", "ui/page.js"],
  "inputs": []
}
```

`zig build rooms-server-test` applies the same publication and payload checks
to the selected compiler and an isolated Deno build with Vite's dependencies
removed. `zig build rooms-web-page` exercises the selected output in Chromium.

Development can also serve compiled generations:

```sh
zig build rooms-dev -Dhot-reload=false
```

That path keeps the same state, operator grants, transport, and build
dependencies. It recompiles changed sources on requests and uses page reloads
instead of React Fast Refresh. Production compiler selection stays in the
recipe, independently of which development server serves the page.

Removing Vite entirely means retaining this generation launch in
`tools/build/rooms/browser_front.zig`, deleting the Vite launch and `web/dev.ts`
supervisor with their tests, and removing `web/vite.config.ts` and the Vite
imports from `web/deno.json`. Update the app's check task and regenerate its
lockfile after removing those imports. Publication, deployment, and the
compiler-independent payload tests remain in place.

## Running the pieces by hand

Start a cleartext server on a known port and join it from a terminal:

```sh
zig build rooms-server -- --transport=tcp --port=9099
zig build rooms-chat -- 127.0.0.1:9099 general alice
```

The server prints `ROOMS-SERVER-LISTENING 9099`. In the client, lines are
sent on Enter, room notices begin with `*`, and Ctrl-D leaves. `/list`
shows populated rooms, `/open <name>` creates and enters one, `/enter <name>`
enters an existing one, `/leave` leaves.

The one-shot clients take a locator, room, nickname, message, and expected
roster. Naming only the sender as the roster means "post and exit":

```sh
python3 apps/rooms/clients/python/client.py 127.0.0.1:9099 general grace "hi from python" grace
racket apps/rooms/clients/racket/client.rkt 127.0.0.1:9099 general alan "hi from racket" alan
deno run --allow-ffi --allow-read --allow-net apps/rooms/clients/deno/client.ts 127.0.0.1:9099 general ada "hi from deno" ada
cargo run --manifest-path apps/rooms/clients/rust/Cargo.toml -- 127.0.0.1:9099 general hopper "hi from rust" hopper
zig build rooms-client -- 127.0.0.1:9099 general turing "hi from zig" turing
```

Each client also accepts the `ocapn://…` locator an iroh server prints.

### On a LAN

The TCP room binds loopback. Two flags open it to a local network, on the
web launcher or as `GLOWCAP_ROOMS_BIND` and `GLOWCAP_ROOMS_ANNOUNCE_HOST` on
the server:

```sh
zig build rooms-web -Dtransport=tcp -- --bind=0.0.0.0 --announce-host=192.168.1.20
```

`--bind` is where the server listens. `--announce-host` is the name it
prints and advertises. TCP is cleartext, so a room exposed this way is
readable by everyone on that network. Keep the page itself on a trustworthy
origin: from another machine, forward the web port
(`ssh -N -L 8080:127.0.0.1:8080 development-host`) and open
`http://localhost:8080`. A page served over bare network HTTP could be
replaced before it becomes a peer, and browsers withhold APIs Rooms needs
there, so the page refuses that origin and says so. On a Tailscale host,
`tailscale serve --bg 8080` gives the page an HTTPS name inside the tailnet.
Beyond a trusted LAN, use iroh.

The Vite dev server behind `zig build rooms-dev` answers to a tailnet name
too. It checks the Host header and, on its own, allows an address or
`localhost`. Any other name has to be listed. Names under `ts.net` are listed
by default, so a MagicDNS name and `tailscale serve` both reach it.
`GLOWCAP_ROOMS_DEV_ALLOWED_HOSTS` replaces that list with a comma-separated
one of your own, and `GLOWCAP_ROOMS_DEV_HOST` is where it listens, which the
devcontainer already sets to `0.0.0.0`.

### As an onion service

`zig build rooms-web -Dtransport=onion` publishes the directory as a Tor
onion service, while the page itself is still served over HTTP.

- The launcher starts a private Tor and stops it when the process ends. To use
  a Tor you already run instead, set `GLOWCAP_ONION_SOCKS` and
  `GLOWCAP_ONION_CONTROL`.
- The onion address comes from the service key, stored as `onion-key` in the
  state directory. Set `GLOWCAP_ROOMS_STATE` when the address must survive a
  restart.
- Tor reports the address before it publishes the service descriptor. An
  outside peer may need a few seconds of retries after the
  `ROOMS-SERVER-LISTENING` line, but this page's own tabs reach the room at
  once through the relay's local forward.
- A terminal client needs an onion-capable runtime to dial through Tor.
  `demos/onion_demo.ts` is a working example.

### With a Goblins vat

A Spritely Goblins vat speaks the OCapN v1.0 baseline and joins the same
room as the glowcap members, each connection on the profile its two ends
agree on. [Bringing a Goblins vat into the room](goblins-vat.md) is the
walkthrough.

## The browser peer and the relay

The page loads the Rooms application as WebAssembly, linked with glowcap's
Host. It is an OCapN peer: it dials the directory, holds room references,
hosts inbox objects, and redeems introductions itself. A browser cannot open
raw TCP or iroh sockets, so `rooms-web` exposes a WebSocket byte relay:

```text
browser peer ──WebSocket /relay──▶ rooms-web ──TCP, iroh, or onion──▶ peer
```

The relay does not parse CapTP and holds no application references, but the
browser has to trust it. The browser leg is cleartext, so the relay could read
every frame. On an iroh route, the relay's QUIC connection checks the far
node's key, and the browser takes its word for it. It admits only destinations the
deployment allows: the supervised directory, an operator-listed TCP peer
(`GLOWCAP_RELAY_TCP_PEERS`), any key-verified iroh node, the supervised
onion service's own local endpoint, or a peer registered for rendezvous. It
refuses a dial whose `Origin` names a host other than the one it was asked
on, so a page from elsewhere cannot use a reader's relay. A request with no
`Origin` (every non-browser client) passes.

Browser peers also register a rendezvous identity with the relay, so another
browser tab or another process can open a fresh connection to the held
WebSocket. That makes a cold dial possible without putting the room in the
message path. A page opened with `?dm=webrtc`, or with that choice made in
Settings, advertises a WebRTC identity instead: direct messages then cross a
DataChannel between the two tabs, and the directory carries only the offer,
answer, and candidates as ordinary capability messages.

## Validation boundaries

The page parses JSON at three boundaries, and each boundary has its own proof
strength. Peer wire payloads are fully validated at ingress: the zod schemas
in `lib/` (the `zod/mini` idioms of `lib/schema.ts`) prove shape and content
limits together, and the TypeScript type derives from the schema. Rust-to-
TypeScript projections come from the same build, so their schemas prove the
envelope the runtime fabricates: kind tags, strings, booleans, enums,
numbers and coordinates. Payloads Rust already holds as typed values ride
through as `z.custom<T>` with their owning lib schema named in a comment.
Re-checking a payload's peer-wire content limits at that boundary could only
drop a notice Rust already accepted. Values the page itself produced and
reads back later, such as retained commands and flat string receipts,
use plain type guards. A receipt whose Rust producer is a tagged enum
(`results::Direct` is the one today) has a field set per variant: prove the
tag first, then prove only the variant's own fields. A pending receipt
carries nothing but its tag. At every boundary a malformed answer names a
defect in the shared build: it throws, or a live-stream notice degrades to
no effect, and it is never cast into place. Mocks in `apps/rooms/test/`
mirror the producer's canonical serialization. The retained
command tuple's base revision is a JSON number, as
`application/src/session/command.rs` writes it. Match the producer's exact
field names and nullable `Option` values too. The activity reader supplies
`history: null` for unrecorded messages, and discovery snapshots carry an
`omitted` count. A page interface is not the serialization authority.

`ActivityDelivery` validates each notice once before readiness and presentation
share it. Its carrier and transient handles retain their identities across
the custody transfer. Result completion prepares the original request and
receipt once per completion attempt. Workspace conflicts recompose the delta
around that input. They do not decode another request or redispatch the effect.

Compose schemas without annotating them: `z.ZodMiniType<T>` erases the
internals `z.discriminatedUnion` needs at composition time. Let the use site
hold a schema's output to its hand-written type instead.

## The objects

The directory owns discovery and introductions. `open(name)` and
`enter(name)` answer a room entrance reference. `list()` reports populated
rooms and `watch(inbox)` pushes directory changes. `register(...)` records a
member's dialable identity. `introduce(nick)` answers the inbox that member
minted for this caller.

An entrance grants a nickname when `subscribe(nick, inbox)` succeeds, and
answers four things: the membership seat, which kind of seat it is
(`participant` or `observer`), the topic authority, and the files facet. Every
later membership verb (`post`, `leave`, `away`, `typing`) goes to the seat, so a
post needs no sender field: the seat is the membership. Leaving or
disconnecting releases the nickname.

The topic authority carries `setTopic(text)`. Every participant is answered
with one, and because it is a reference rather than a rank, a member can
pass it to somebody who is not even in the room. The files facet is the same
idea for files: `attach` and `postFiles` go to it, a room hands it out when
it can hold bytes and answers null when it cannot, which is how a room
bridged to IRC says so. The page draws the attach control from whether the
membership holds that facet. Two parts of a message are description rather
than authority, and the room states them at arrival on the `carries` tag:
whether it keeps the link previews a line names, and whether it relays the
typing signal.

`post` answers a reference to the line it made, and holding that reference
is the authority to `edit(text)` or `withdraw()` that one line. `postFiles`
answers the same kind of reference. `refile(caption, ...keep)` changes the
files, keeping the ones whose indices it names and adding the connection's
freshly staged uploads. Refiling down to no files and no caption withdraws
the line. Line references restart with a room generation and never enter
durable history, so a new room cannot govern a row restored from an earlier
one.

Direct inboxes follow the same rule. `dm(text)` carries no claimed sender
because each inbox was minted for one introduced peer, and a conversation is
keyed by that introduction rather than by the nickname. `dm` answers a line
handle minted by the receiver, and the handle lives on the direct connection,
so a line whose connection has gone cannot be changed. Either side can send
messages, typing, room invitations, or archive shares across the connection,
whichever side opened it.

A member-owned archive is one more ordinary object, defined in
`lib/archive/protocol.ts`. `put(record)` inserts or replaces one line or
standing, keyed by its recorder source, conversation generation, and record id.
`read(filter, afterRevision, limit)` returns a bounded page.
`narrow(filter, access)` returns a facet whose scope can only shrink and whose
write authority can only be removed. The browser store, the archive service, and the session
service all implement it.

The site's [protocol page](https://jimisaacs.github.io/glowcap/rooms/protocol/)
walks through each object with its lifetime. `lib/protocol.ts` is the
specification a person reads. `tools/gen/rooms_protocol.zig` declares the
wire grammar once and `zig build gen-rooms-protocol` writes the application
and client projections, so a new notification kind is one edit.

## Media

The composer keeps selected files local. Send asks the room for one upload
reference per file, publishes their records as one message, then fills those
references concurrently in 64 KiB chunks. Every member can start reading the
room-hosted blob at once. A read at the moving edge parks and wakes when the
next bytes arrive. Holding an upload reference is the authority to fill
that file, so `write` never names who is uploading.

The room hosts the bytes itself instead of relaying a blob the sender hosts.
Sender-hosted files would mean every recipient dials the sender, which a
browser tab cannot answer without signaling per viewer, and the picture
would disappear when the sender's tab closed. Room-hosted files work for
every client and outlive the person who posted them.

The cost is that the server has limits to enforce:

- `FileLimits` in `rust/application/src/files.rs` bounds pending bytes, held
  bytes, and file counts, both server-wide and per room.
- `UPLOAD_IDLE_MS` reclaims an upload that declared a size and then wrote
  nothing.
- A dropped file's reference stays valid and answers `blob-expired`.
- Bytes still being uploaded are refused rather than evicted, because their
  message may already be visible.
- A file too large for the page to keep at all is refused before the composer
  clears.

## Present boundaries

- The session chooser shows a third option, "Sign in", marked "Coming soon"
  and with no action. Server-kept sessions that any device can reach with an
  account are not built yet.
- `web/ui/emoji.ts` is a curated table and the one authority the tray,
  `:code:` substitution, and completion derive from. The widening path is a
  generator over a pinned CLDR-backed dataset, keeping the runtime
  dependency-free.
- Every filterable list in the page owns its own input except the composer's
  inline completion, which keeps focus in the textarea. A command palette, a
  searchable emoji picker, and settings search are where a combobox
  primitive would earn its place. None exists, and the page's only
  runtime dependency is React.
- IRC stays at the application edge. Carrying CapTP itself over IRC is
  refused: a 512-byte line protocol with a server that may inject cannot keep
  an OCapN session insertable only by its participants.
  [ADR-0128](../../docs/decisions/adr/ADR-0128-room-links-peering-and-irc-edges.md)
  records the edges.
- Peering is one handed authority, not a server link. A room's sturdyref is
  enlivened once on the source, and the destination keeps one foreign row
  until its lease revokes it or the publisher's session ends.

## Source map

| Path | Owns |
| --- | --- |
| `rust/application/` | Portable policy: documents, grants, the room protocol, files, the archive, the session, the server |
| `rust/glowcap/` | The Rooms protocol clients over the Rust binding |
| `rust/runtime/` | Shared execution and its typed failure boundary: session commands, directory supervision, rooms, direct messages, archives |
| `rust/platform/` | Tokio, entropy, leased storage, listeners, TLS, WebSocket channels |
| `rust/services/` | The room server, session peer, archive peer, IRC edges, web server, and interactive client |
| `rust/browser/` | The Wasm application: session controllers, storage, signaling, transport |
| `rust/proofs/` | The application contracts replayed from fixtures, in a process and in Wasm |
| `web/ui/` | The browser page: React components, the store, the session projection |
| `web/compiler.json` | The production compiler invocation and additional source-identity inputs |
| `web/deno.json`, `web/vite.config.ts` | The pinned browser toolchain and Vite configuration |
| `web/dev.ts` | The internal process owner called by `zig build rooms-dev` |
| `web/deploy/` | The Compose deployment |
| `lib/` | The Rooms protocol as TypeScript, for the Deno client, the demos, and the tests |
| `lib/text/` | Every sentence the page shows a reader |
| `clients/` | One terminal client per language beside its generated protocol table |
| `irc/` | The IRC bridge and gateway, and the TypeScript test consumer's line grammar |
| `demos/` | The scripted scenarios |
| `test/` | The Deno unit tests, the page scenes, and the browser proofs |

The [Rust workspace guide](rust/README.md) describes each crate.
