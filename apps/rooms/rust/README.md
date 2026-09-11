# Rooms in Rust

The native interactive client runs with
`zig build rooms-chat -- <locator> <room> <nick>`. It accepts TCP host/port
addresses and TCP or iroh locators, follows the live directory, and supports
`/list`, `/open`, `/enter`, `/leave`, and `/help`. A refused room switch
preserves the previous membership. EOF and signals close the session and join
the terminal workers. The installed-client scenario runs in `rooms-peers-test`.

This workspace holds the Rust side of Rooms: the durable session peer a
browser attaches to, the durable archive peer, the room server members
register with and enter rooms on, the standalone IRC bridge and client front, and their shared application policy. Native listener, diagnostic, operator, peering and timeline capabilities are implemented. The default web launcher and deployment run Rust; the production browser uses Rust Wasm for its Host, local and attached session controllers, workspace intent, persistence and archive custody. TypeScript renders typed observations and supplies browser effects.
`zig build rooms-web-build` builds the native HTTP front;
`zig build rooms-web-native-test` exercises asset headers, rendezvous admission,
shutdown, timeline refusal forwarding and a Wasm peer calling the directory
through TCP and iroh. `rooms-web-tor-test` exercises private Tor and onion
forwarding with public networking disabled. Native process scenarios cover
attachment to an external directory, takeover after it exits, and preserving
its identity and operator capability. `rooms-web --prepare` atomically publishes
a complete browser generation; `--prepared --assets=<generation>` serves it
without application source or a compiler. Browser scenario launchers select the native front; the replaced TypeScript
web service owners are removed. The full page scenario passes through files,
refiles, multiple rooms and directories, IRC controls and operator capabilities. The native front reads a
versioned readiness record from its child, so an ephemeral timeline port remains
usable after startup or restart. Its compiler, directory probe and supervised
children retire on cancellation, including before readiness. Native
`rooms-web --check-ready`, `--locator` and `--ui-version` query a running front
without application source or browser build tools. `rooms-server --irc`
now serves network/channel leases, subscriptions, member posts and identity
changes through Rust. Durable IRC moderators and one-shot observer/participant
invitations are implemented, including moderator restart and revocation checks.
Observers receive the shared feed without opening an IRC identity socket.
IRC rooms, stewards and membership inboxes appear in the operator inventories;
bulk retirement, reference release and room reset await saved changes. Diagnostics
show IRC rooms without their authority tokens, and the timeline follows IRC
membership annotations. Remaining
recovery/race coverage is in progress. The browser
talks to the peers here over CapTP.
[`../operating.md`](../operating.md) says how to run the peers;
[`archive.md`](archive.md) is the archive's own design page.

The native server's saved operator changes share one operations-document
writer. Socket preparation runs independently; persistence and runtime
installation serialize. Shutdown drains accepted changes before closing
listeners, and an uncertain write refuses further changes until restart.
The room-authority writer reserves public names before persistence can yield.
Creation, IRC publication and peering respect both pending and durable claims,
including rooms with no live members. Uncertain replacements retain their
claims until restart reconciles the document. Deferred authority replies retain
their calling session, so room, manager and steward links use that caller's
negotiated routes after persistence completes. IRC channel identity uses IRC
case mapping; its Rooms directory labels use Rooms name equality.

The operator's retained-capability count measures application-owned reference
occurrences. Native room memberships hold one inbox each; published controls
consult generation state without extra room-owned handles. Management recovery
uses stable room identities, and public-name lookup follows the current listing
index even when a managed room has an opaque durable key.

The archive, session and room server binaries accept `--transport=onion` with a running Tor's SOCKS/control
endpoints. Shared listener startup reads and saves `onion-key` through the peer's
existing state owner, closes the listener on failed key persistence, and announces
readiness only after custody stands. A restored service keeps its saved key even
though Tor returns no new key. The native process check below uses a real Tor
with networking disabled; it proves restoration and local forwarding, not public
circuit reachability:

```sh
cargo test --manifest-path apps/rooms/rust/Cargo.toml -p rooms-native --features service --test onion_process -- --ignored
```

## The crates

| Crate | Owns | Depends on |
| --- | --- | --- |
| `rooms-application` | Portable policy with no platform dependencies: documents, grants, the room protocol, file budgets, the archive, the session, and the wire vocabularies | nothing |
| `rooms-glowcap` | The view over the Rust binding's decoded values, and the clients that speak the Rooms protocol over a session | `rooms-application`, the Rust binding |
| `rooms-runtime` | Shared session and command execution, directory supervision, room memberships, direct routing/publication and media custody over platform adapters | `rooms-application`, `rooms-glowcap`, the Rust binding |
| `rooms-native` | Native storage and service composition, archives, room server, IRC edges and web front | the shared crates above |
| `rooms-browser` | Browser time/entropy, transport execution, directory signaling and IndexedDB archive effects | `rooms-application`, `rooms-glowcap`, `rooms-runtime`, the Rust browser binding |
| `rooms-migration-proofs` | The application contracts replayed natively and as browser Wasm from fixtures captured off the TypeScript owners | `rooms-application`; the Rust binding on both targets |

`rooms-application` decides; the other crates carry its decisions to a host.
A behavior that could be decided without a runtime belongs in the application
crate, with a fixture that proves it in both proof targets.

### rooms-application

- `documents`, `fields`, and `text` are the document contract: bounded fields,
  lossless text that keeps isolated UTF-16 surrogates a JavaScript author
  wrote, and the limits every reader applies before retaining anything.
- `grants` is the version-one grant ledger: validation, revocation tombstones,
  the dynamic access policy a facet reads on every call, and the HMAC
  derivation of published names. Its storage adapter executes one atomic
  replacement per commit; the ledger commits only after acknowledgement.
- `room` is the room protocol: the three room policies, line edit, refile,
  and withdraw, membership and stewardship, invitations, the inbox notice
  reader, and history bounded to 100 lines and 2 MiB.
- `files` is one host-wide upload and media budget with separate room and
  membership lifetimes, 64 KiB chunks, and the receiving budget a view or
  archive charges before it takes a file.
- `archive` is the member archive: records, coordinates, filters, blob
  digests, retention, merging across keepers, and shares.
- `session` is the shared session: the checkpoint and its redactions per
  access level, the durable state with its effect ledger and result recovery,
  command admission, reconciliation facts, and the twelve-field snapshot
  with a 900 KiB aggregate text budget.
- `bridge`, `direct`, `directory`, and `signaling` are the application wire
  vocabularies, each with its bounded reader and writer. `directory::wire`
  draws discovery snapshots and events in the shape `directory` reads, so a
  directory answers exactly what a client parses.
- `server` is the policy a Rooms server hosts: `server::document` is the
  server document with its identity seed, room-link secret, and relations;
  `server::links` is the durable authority read from it, its derived
  sturdyref entropy pinned to vectors captured from the TypeScript owner,
  and every change a successor whose document is persisted first;
  `server::directory` is the directory; `server::rooms` is the live rooms
  with their members, lines, files, invitations, and entrances;
  `server::history` is retention; `server::operations` is what an operator
  holds, the journal, the listener seats and their kept intent, the
  diagnostic snapshot, and the operator's inventories, pages, and revision;
  `server::peering` is the rooms other directories publish; and
  `server::viz` is the live timeline's records, producers, and replay.
  Connections are the adapter's keys and
  capabilities its tokens; every verb answers with the notices, releases,
  watcher events, dropped exchanges, and history changes the adapter must
  perform, so the same decisions run under any host and a test reads them
  without a wire.
- `failure` reads and writes the Rooms failure codes, tolerating a binding's
  diagnostic prefix without losing the classification.

### rooms-glowcap

`host_options` supplies the native profile and full feature offer for Rooms
Hosts. Each connection negotiates with its partner; identity routes require the
multi-location feature on both sides. Native service entrypoints share this
configuration with browser application composition.

`Value` borrows a decoded argument and reads arbitrary wire integers without a
second bignum representation; `ArgumentView` finds the capabilities an argument
carries so a verb can refuse the ones it does not take. Each client owns the
reply validation for its verbs and the custody of the capabilities it retains:
a membership subscribes and waits for both its seat and the room's arrival, a
line keeps its own authority independent of the membership, a file transfer
advances only on acknowledgement and refuses a second append after an
uncertain one, an invitation keeps one random receipt across retries. Deadlines
and task spawning are supplied by the caller through the `Deadline` and
`Tasks` traits, so the same clients run under Tokio natively and could run
elsewhere.

`client::session` implements attached-session snapshots, watch delivery, commands,
checkpoint replacement, effect recovery, files, grants and archive-share reads.
Operator pages and snapshots, listener/diagnostic inventories, visualization,
peering and bridge gateways use shared bounded response readers. The native
session relay uses those same readers when rendering CapTP answers as JSON.
Observer callbacks receive admitted application values and owned file guards;
dropping a watch releases callback captures immediately. `historyChanged` carries
no arguments for a whole-account invalidation, or a conversation kind, directory
and conversation identifier for a scoped one. Subscribe before reading; an
in-flight read invalidated by a later commitment must be repeated. Notifications
carry no file authority and require the observer's current history right.
The page currently rereads the affected conversation's retained history, with
coalescing and four fair read slots. High-traffic history cost remains to be measured.
The protocol has no
unwatch verb, so remote retirement follows delivery refusal or connection close.
The native executable scenario and Wasm session scenario exercise command/view
ordering, attenuation and revocation. Native inventory scenarios also exercise
operator response admission. The production page consumes this Rust client
through its attached-session controller.

### rooms-runtime

`session_state` and `session_commands` own initialization, acknowledged
checkpoint/effect commits, result recovery and bounded command admission on
both hosts. Storage, entropy and monotonic scheduling are typed adapters.
Native document workers keep filesystem custody; `VolatileDocuments` preserves
the lifetime of a tab-hosted session. Browser workspace and archive persistence
remain separate. `session_directory` shares connection, discovery, registration
and voucher custody through the binding's native/browser `Runtime`.
`directory_runtime` owns bounded supervision and reconnects, generation
retirement, direct acceptance, received room links and handed room capabilities.
Direct routes, coalesced openings, inbox publication and registration dispatch
also share execution. Direct message admission, delegated edits, media custody,
outgoing delivery and durable command completion now use shared owners too.
`archive` and `session_archive` own hosted admission, ordered storage execution,
file capture, source leases, shares and erasure. `archive::Backend` supplies
storage; `Source` supplies bounded file reads from live or materialized bytes.
Archive recording crosses a synchronous admission/receipt adapter. Operator
credentials, peering leases, received room/archive offers and bounded session
snapshot construction also have shared execution owners. Grant persistence,
publication and command replies share execution over fixed-role document adapters.
The native session consumes shared startup, worker supervision, capability
dispatch and attached views. Deferred work is bounded and retired by its facet;
files, listeners, readiness and the visualization publishing adapter remain native.
Native and Wasm execution share these owners; the platform supplies clocks,
tasks, deadlines and cryptographic entropy.
See [the execution contract](runtime/README.md).

### rooms-native

The runtime tier runs on one Tokio `LocalSet`; owners are `Rc` and `RefCell`,
never shared across threads, and every worker is joined at shutdown.

- `serving` is what every peer stands on to be reached: the transport and its
  options, the listener on the Host's loop, and serving one accepted partner
  to its end. A partner leaving is not reported; a refused accept is asked
  again after a pause, and only a closed listener ends serving.
- `documents` and `storage` lease the state directory, sweep the staging
  files an incarnation that died mid-replacement left, read and replace its
  documents atomically, and hand each document to the owner that keeps it.
- `grants` and `grant_publications` restore the grant ledger, publish every
  active grant on the Host, and refuse held capabilities the moment their
  grant is revoked, closed, or recovering. `grant_commands` queues at most 64
  grant commands, persists before answering, and reports a notification that
  could not be delivered without stopping service.
- `session_state` specializes the shared durable owner with native documents
  and entropy; `session_commands` reexports the shared command API. Native
  scheduling supplies its retry clock.
- `session_runtime` specializes shared directory supervision, direct routes,
  inbox publication, registration dispatch, room and direct message effects,
  memberships and received room offers for the native platform. It also owns
  outgoing room offers, archive shares, operator credentials, and peering. Each owner has a bounded
  budget named at its declaration and a `close` that observes its worker.
- `session_archive` specializes the shared session archive with native scheduling.
- `archive` composes the shared hosted worker with the native journal, blob
  storage, directory lease and standalone service.
- `room_server` is the room server; its own section follows the session
  peer's below.
- `media_files` specializes shared media custody with the native scheduler
  while shared archive sources read its retained chunks. Views and recordings
  share one materialization, pinned against eviction while readers hold it.
- `session_service` is the peer a browser attaches to; the next section is
  its shape.

## The session peer

`rooms_runtime::session_service::Session` opens and retires the application
owners in dependency order, including failed startup. Named workers are supervised;
one ending unexpectedly is a session failure. Close removes its root publication
and drains commands before their archive dependency. The native peer surrounds
this owner with listeners and readiness. It observes accepted partners to their end.

`Facet` is the CapTP object every attached view talks to, for the
administrator root, every published grant, and every minted delegate. What a
caller may do is read from its grant on each call. Verbs live under
`session_service::verbs`, one file per subject: checkpoint adoption and
replacement, commands, typing, history, files, bridge forms, effect
resolution, delegation, operator inspection, operations, archive shares, and
archived attachments. A verb that must wait answers through `answer::later`,
which defers the turn and settles it from a task; an answer whose caller has
closed its session is dropped, one that cannot reach a caller still there is
reported.

`views` holds the attached views: the session each attached over, the grant
it came through, its rights, and its own event sequence. Events are told to
every view as they happen; snapshots are encoded once per distinct rights and
delivered once per tick. A view whose delivery fails, whose grant is revoked,
or whose session closes is retired at once, and a view losing its grant is
told why first. There is no per-view queue: a view that cannot keep up loses
its attachment and re-attaches, which the browser does on its own. At most 64
views attach at once.

Ordinary room effects are ledgered through `verbs::effects`; file commands use
`rooms::file_commands` to bind immutable attachment content before preparation.
An operation is
reserved before its work runs and settled by what the work reports: an effect
the room applied is committed even when the rest failed, one the room never
saw is abandoned so a new operation can send the intent again. A lost answer or
remote exception leaves the outcome pending for a reader to decide. Room file
sends and refiles reserve the membership's staged batch exclusively, acknowledge
the line change, then fill its uploads from the same frozen bytes used for retry
identity. Admission bounds requests, file bytes and metadata across all rooms;
each membership orders its admitted file commands. Losing the source during
capture leaves no posted line or pending effect and permits retry with the same
operation ID. A failed fill
leaves the applied line in place and attempts to discard its incomplete files.
An uncertain batch requires retiring that membership before another batch can
use it. Direct refiles carry inline file grants under their separate protocol.
Room refile identities include the runtime incarnation and membership epoch, so
reusing an old operation ID after rejoining cannot select a newly numbered line.

The room worker retains exact membership inputs and bounds outstanding joins.
A completion must match both its join attempt and current committed intent;
obsolete successful subscriptions are left explicitly. Room facts carry their
observed inputs into the portable reducer and a producer scope into the native
serializer. Membership identity is separate from manager, moderator and entry-link
custody: rotating those authorities preserves the seat, its callbacks and posted
lines. A missing saved publication becomes an exact retirement fact; reconnect
requires explicit intent instead of silently entering by name. Operator-backed
manager recovery commits its returned authority through the result ledger.

Native session views deliver a suspension transition once, then stop ordinary
notifications until resumed. Only administrator views receive operator inventory
changes and credential acquisition issues. Replacing operator credentials waits
for reconciliation before acknowledgement, and an acquisition completed after
replacement cannot install the obsolete credential.

Room lines are recorded to the session archive as their echoes arrive. A
line's file bytes are captured from the room beside the archive's request
queue, so history reads keep answering while a source is slow or gone; a
source that fails leaves its line archived with the file named and its bytes
recorded as unavailable, the way the room keeps it. The room's issue list
carries the reason. Successful writes invalidate attached history even when the
recording's receipt was abandoned. Slow observers receive a whole-account
invalidation if they fall behind the bounded scope stream. Writes to a selected
peer are covered; changes made independently by other writers on that peer are
not watched. Archive coordinates identify the session by its public key.
[Operating Rooms](../operating.md#session-archive-identity) describes the exposure
in earlier prerelease session archives.

## The room server

`room_server` is what a member's directory locator names: the directory that
files names, tells watchers who is registered and which rooms are open,
relays introductions and direct-route requests between members, and carries
WebRTC signaling between them; and the rooms members open and enter, with
their lines, files, topics, presence, invitations, and the durable links,
managers, and stewards issued over them. `rooms-server` leases one state
directory holding `rooms.json`, the same server document the TypeScript
server keeps, mints it with fresh entropy on first start, and takes its Host
identity from the document's seed, so its locator and every link it issued
survive a restart. Without a state directory it is process-local, as the
TypeScript server is.

The policies are `rooms_application::server::directory`,
`server::rooms`, and `server::links`, which hold no session and perform no
effect. The server gives them a connection id per accepted session and
applies what each verb answers: notices are queued on member inboxes,
every watcher hears each event in its own shape, capabilities go back to the
session that imported them, a dropped signaling exchange is rejected to its
originator, and kept lines go to the history worker. The directory root is
published on each accepted session, so a verb knows its connection without
a lookup, and the session ending is what withdraws everything the connection
held: memberships, uploads, invitations, registrations, and exchanges.

A room reference crosses connections, through a handoff or a link, so the
room, seat, line, topic, upload, blob, and invitation actors read the
calling session for their caller. Each is minted before the policy files
what it stands for, so a refusal drops an unfilled actor and never leaves an
orphan; a file line's blob capabilities are minted on each hearing member's
own connection when the line is told. Retained history is one index in the
policy, persisted by a worker as one JSONL file per room under `history/`,
in the row and file form the TypeScript server writes, so a directory of
kept lines moves between the two as it stands.

Durable authority changes one job at a time: a link, a steward, a manager,
a policy change, a revocation, or a topic prepares its successor in the
turn, persists the document, installs the successor, and only then
publishes or takes down durable names and answers the caller. Two other
deliveries are awaited outside a turn: a signaling offer is acknowledged to
its originator only once the target's inbox has accepted it, and an
introduction whose member has not yet offered an inbox asks that member and
breaks the caller's deferred answer with `introduction-pending` only after
the request landed. All of these reserve their seat in the server's work
queue before anything depends on them; a full queue refuses the verb.
Signaling exchanges expire and quiet uploads are reclaimed on the server's
own clock. Locator claims are checked the way the TypeScript server checks
them: a partner that proved a durable identity may register only a locator
naming that identity, and an unproved connection holds its own claim.

The operator capabilities are minted on an explicit ask, each under a swiss
number the state directory keeps, and published on the Host before the
listener opens. `--admin-listeners` administers the listener seats: one per
transport the server can realize, brought up over the same Host and served
the same way, with the intent kept in `operations.json`. `--diagnostics`
answers the read-only snapshot. `--operator` answers the seven inventories
in bounded pages under one revision, with search and retirement server-side,
the stewardship verbs, and a watch that hears every change. `--peering`
lists rooms another directory publishes here until their lease revokes them
or their publisher's session ends. `--viz` binds the live timeline endpoint
on loopback: producers publish over a WebSocket at `/publish`, viewers open a
CapTP session over a WebSocket at `/`, every socket presenting the swiss, and
the server's own trace goes in through the same door. The policies are
`rooms_application::server::operations`, `server::peering`, and
`server::viz`; the trace tap only queues, and everything that touches a
session runs outside it.

## Budgets

Every bound is a constant beside the owner it protects. The ones a reader
meets first:

| Bound | Value | Where |
| --- | --- | --- |
| Attached views | 64 | `session_service::views::MAX_ATTACHED_VIEWS` |
| Accepted connections served at once | 128 | `session_service::peer::CONNECTION_LIMIT` |
| Archived-file readers per attached connection | 512 | `session_service::verbs::attachments::MAX_READERS` |
| Session archive requests in flight | 64, within 2 MiB of retained input and 64 MiB of file bytes | `session_archive::MAX_PENDING` and siblings |
| Concurrent file captures | 32 | `session_archive::MAX_STREAMS` |
| Grant commands queued | 64 | `grant_commands::MAX_PENDING_GRANT_COMMANDS` |
| Room notices in flight to the worker | 256 | `session_runtime::rooms::NOTICE_LIMIT` |
| Room events in flight to the views | 256 | `session_runtime::rooms::EVENT_LIMIT` |
| Lines awaiting their echo per room | 2000 | `session_runtime::rooms::PENDING_LINES` |
| Direct dispatch requests | 32 | `session_runtime::direct_dispatch::REQUEST_LIMIT` |
| Route openings | 32 attempts, 256 waiters | `session_runtime::route_openings::{OPENING_LIMIT, WAITER_LIMIT}` |
| Directory watchers | 256 | `rooms_application::server::directory::MAX_WATCHERS` |
| Inboxes one member offers, and direct requests it tracks | 256 | `rooms_application::server::directory::MAX_DM_INBOXES` |
| Vouchers outstanding per name | 8 | `rooms_application::server::directory::MAX_NAME_VOUCHERS` |
| Signaling exchanges, each expiring after 30 seconds | 64 | `rooms_application::signaling::{MAX_EXCHANGES, TIMEOUT_MS}` |
| Room members | 256 | `rooms_application::server::rooms::MAX_ROOM_MEMBERS` |
| Rooms one connection opens, and live invitations per room | 256 and 64 | `server::rooms::{MAX_ROOMS_PER_CREATOR, MAX_ROOM_INVITATIONS}` |
| Kept lines per room, and for the whole server | 500, then 4096 lines over 256 rooms | `server::history::{LINES_KEPT, LINES_KEPT_TOTAL, ROOMS_KEPT}` |
| Room files held | 256 MiB over 4096 files, 64 MiB over 128 per room, 64 MiB in flight | `rooms_application::files::FileLimits` |
| Durable room names | 4096 | `server::document::MAX_ROOM_LINKS` |
| Server work queued, and history changes queued | 256 and 1024 | `room_server::state::WORK_LIMIT` and `room_server::history::QUEUE` |

## Building and proving

The steps below are the ones `zig build check` runs or that
[`docs/build-steps.md`](../../../docs/build-steps.md) documents beside it.

```sh
zig build rooms-browser-build   # production application Wasm and generated browser glue
zig build rooms-browser-test    # production startup contracts in Node and Chromium
zig build rooms-rust-test       # the workspace's native tests; part of check
zig build rooms-rust-lint       # clippy over the workspace with warnings denied; part of check
zig build rooms-peers-test      # the installed peers' identity, transport, restart, and signal shutdown; part of check
zig build rooms-session         # run the session peer; pass `-- --state=<directory> [--checkpoint=<Rooms JSON>]`
zig build rooms-archive         # run the archive peer; pass `-- --state=<directory>`
zig build rooms-server          # run the room server; pass `-- [--state=<directory>] [--history]`
zig build rooms-web-shared-session   # real browsers attached to the native session peer
```

Native tests that need the built glowcap archives take them from
`zig-out/lib`; run `zig build` first, then `cargo test` with
`LD_LIBRARY_PATH` pointing there and `--target-dir=apps/rooms/rust/target`.
Service-level tests and the `service` feature they need are enabled with
`--features rooms-native/service`.

The browser proof of the application contracts links the same Rust with
glowcap's Host and OCapN archives into one Wasm memory and runs it in Node and
Chromium. It also exercises the real Rust Context and locator binding against
generated Wasm layouts and archive fingerprints. The async proof runs the same Rust Host and Rooms directory client with
browser entropy and timers, including capability callbacks, finite close and
both handshake timeout directions. A controlled authenticated message channel
also exercises the core's WebRTC framing, cancelled close observers, physical
close refusal and cleanup after rejected admission. This fixture does not
exercise DTLS or SCTP. A separate Chromium scenario now uses the Rust browser
adapters with real WebSockets and RTCDataChannels. It starts installed native
`rooms-web`, opens distinct rooms through Rust-composed TCP and iroh forwarding,
checks cross-origin refusal, exchanges reciprocal keyed/Noise relay calls and
calls over a local RTC pair, and checks physical closure and
callback removal. Rust's `RtcPeer` also owns local SDP/ICE exchange and the
parent connection in a separate scenario, which checks cancelled SDP observers,
Host shutdown during preparation, and data-channel closure before parent
teardown. The [browser adapter](browser/README.md) now carries both signaling
halves through the native directory and proves direct calls survive directory
closure. Its IndexedDB archive backend runs under shared archive hosting and
checks compatibility with JavaScript-authored records and Blobs, retention fences,
rollback and eviction in Chromium. The production page consumes Rust workspace admission, controller composition, workspace writes and archive startup fallback. The proof needs the Rust
target and the locked Node tools once:

```sh
rustup target add wasm32-unknown-unknown
npm ci --prefix apps/rooms/rust/proofs/browser
cargo install wasm-bindgen-cli --version 0.2.128 --locked
zig build rooms-rust-browser-test
```

`wasm-bindgen-cli` must match the library version pinned by the proof crate;
the tool refuses mismatched schemas. `rooms-rust-browser-host-test` selects only
the async scenario. Its separate output directory preserves the import-free
static contract artifact. The runtime dependency belongs only to that async
embedding, so portable fixtures do not pull in browser entropy and timers.
JavaScript imports in the async module provide
platform effects; Rust calls the linked Zig Host directly.

The devcontainer provides Chromium. Outside it, install the browser matching
the locked Playwright package with
`npm exec --prefix apps/rooms/rust/proofs/browser -- playwright install chromium`.

## Native IRC owners

`rooms-native::irc` owns deadline-bound TCP/TLS connections, bounded framing and
output, registration and cancellation. TLS uses the system trust store, loaded
off the capability executor; account credentials require TLS. Socket receipts
report complete writes and distinguish queued writes from uncertain partial
writes. They do not claim acknowledgement from an IRC application.

`irc::feed` drives the shared gateway policy on one reconnecting socket per
configured network. Each channel retains its own publication identity, join
timer and failure status. Channel traffic is paced across the connection;
registration and PING replies bypass pacing. Removing the last channel ends
its feed socket without deleting the network configuration.

`irc::member` owns one member identity and its channel memberships. Posts require
a confirmed JOIN. PART retires a handle immediately but keeps the channel name
reserved until the server confirms departure; a late JOIN cannot make an old
handle usable again. Departure timeout retires the socket to resolve that
uncertainty. The native room server composes these owners under `--irc`; the
standalone `rooms-irc-bridge` composes the same connection, room and relay
policy with a bounded attributed-post queue. It publishes its directory before
listening, retains memberships across reconnects and drains or refuses every
admitted post on shutdown. Only writes proven unwritten retry; an uncertain
write is refused to avoid replaying a possibly delivered message. The
native `rooms-irc-front` projects ordinary IRC clients onto the shared Rust
Directory, Room and Direct clients. It owns bounded room memberships, direct
lines and nickname aliases. Each user has an independent Host and directory
connection. An authenticated local Noise attachment transfers scoped inbox
capabilities from one shared public Host, whose Noise/TCP/iroh listener carries
introductions and reply routes. The directory settles an offered capability
before announcing it, rechecking the registration generations after settlement.
IRC output acknowledges direct messages after socket delivery and preserves
the actual write failure on refusal. Registration ends its timeout on success;
TLS closes through the output owner after membership and inbox retirement.

## Fixtures

`proofs/fixtures` holds the cases captured from the TypeScript owners that the
proof crate replays; [`proofs/fixtures/README.md`](proofs/fixtures/README.md)
names each file and what it pins. A fixture is evidence that the two
implementations agree on a document or a reply, not that a production path
runs; the native tests and the browser proofs are where production paths run.

## Boundaries

- The native room server answers room, directory and operator capabilities.
  Its IRC gateway now issues/revokes durable moderators and mints one-shot
  invitations, and integrates operator inventories and retirement. Diagnostics and
  timeline membership annotations include IRC rooms. Pending name reservations
  and startup onion transport are implemented. Both standalone IRC entrypoints run Rust. The web launcher
  now starts the installed native server by default, including IRC/onion;
  `GLOWCAP_ROOMS_SERVER_BIN` overrides its path. Replacing a subscriber preserves
  its IRC identity and channel lease while retiring its prior capability.
  Failed identity changes restore through surviving channels; a new identity
  incarnation cannot inherit an old change's rollback. Operator batches capture
  selected authority tokens before yielding, then wait for bounded writer
  capacity. Session retirement awaits its close before answering. Durable acts
  still persist individually; this does not claim a storage throughput improvement.
- History uses JSONL files or PostgreSQL through the native server's `--storage`.
  The existing database schema is preserved, and one session lease excludes a
  second native owner. An I/O failure ends serving without replaying an uncertain
  transaction. The live database process scenario is opt-in through
  `zig build rooms-postgres-test`; [operating](../operating.md#storage-and-room-history)
  describes connection and trust options. Mutations reserve bounded writer capacity
  before changing policy or consuming uploads; a full queue refuses the call.
  Immutable retained rows share unchanged text across queued replacement tails.
  The database process scenario blocks writes, fills the queue, checks refusal
  across rooms, then drains and reads the accepted history after restart.
- Native IRC transport scenarios cover TCP registration, control traffic under
  paced output, write pressure, member confirmation and sibling channel
  retirement. TLS uses the system trust store and refuses credentials on
  cleartext connections.
- The native tier has been exercised on Linux. Directory synchronization and
  file locking on other platforms are unverified.
- The completed migration boundary and its evidence live in
  [`docs/planning/rooms-rust.md`](../../../docs/planning/rooms-rust.md).
