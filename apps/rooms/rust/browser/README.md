# Rooms browser adapter

This crate connects the shared Rust Rooms application and capability clients
to browser platform APIs. The production page loads this crate's Wasm module
to admit saved workspace state and directory identities before creating a Host.
Local, hosted and attached pages use the Rust application owner for live
controllers, reconnect and effect-ledger execution. React consumes its views.
The page constructor holds presentation, workspace persistence and typed Rust
handles. It no longer constructs TypeScript connections, protocol clients or an
archive recorder. Address navigation delegates session actions to that same
controller; form gating, media display and notification prompts stay in the UI.

The native web package serves the hashed Rust application Wasm and generated
glue. It neither packages nor serves the TypeScript binding's `glowcap_host.wasm`.
The browser import map includes generated ABI constants and runtime-free error
custody alongside presentation dependencies.

Shared Rust owns slash-command definitions, argument interpretation and composer
admission. The UI supplies text, selected files and view context, then renders a
refusal, submits a line or applies the returned gesture through its session.
Asynchronous gestures retain their completion: refusal preserves the draft, and
success clears only the submitted draft. Delayed edit acknowledgements and
failed sends cannot replace newer text or another conversation's composer.
Relative ignore and away changes commit against the session's current checkpoint.
Edit targets come from admitted Rust events; rendered history supplies no edit
authority. Room sharing captures the membership and peer registration before
directory work and checks both again on command retries.
Bridge widgets submit through the shared form validator, including its separation
of public answers from transient secrets. Room-access controls use Rust policy
values. Membership, away state, bridge seats and room facts arrive in the shared
room snapshot; the browser does not run a second presence reducer.

`web/ui/application_data.ts` is generated from Rust limits and the boot capability
catalog. `zig build rooms-browser-metadata-check` checks it as part of the browser
build. Regenerate it with `cargo run --manifest-path apps/rooms/rust/Cargo.toml
-p rooms-application --example browser_metadata` after changing those definitions.
Browser file adapters provide bounded byte readers and measure images with the
platform decoder; Rust validates descriptions before the composer clears.

`zig build rooms-browser-build` produces the application module and generated
JavaScript glue; every native web build and deployment preparation depends on it.
`rooms-web` packages the module with the page and serves it by content hash,
retaining the previous generation for pages already loading. Prepared serving
requires neither source nor a compiler. After changing Rust during development,
rebuild this artifact; the running front detects its changed content.
`zig build rooms-browser-test` exercises the production exports in Node and
Chromium. Workspace admission itself creates no Host.

`workspace_persistence` applies the shared workspace save policy to synchronous
browser storage and cancellable timers. A refused write preserves the prior
document; a successful replacement fences the previous writer. Setup composes
preferences with an admitted saved checkpoint, while a live session supplies
its own checkpoint. Display rows do not reconstruct session authority.
Controller attachment verifies a sibling capability on the existing connection
or opens a provisional view on the page Host. It saves the verified checkpoint
and controller together, then awaits provisional-view retirement. A local fork
preserves room holdings and drafts while clearing the original peer's names.

`platform::Platform` supplies browser monotonic time, local task custody and
cryptographic entropy to the shared runtime. The session command owner is the
same implementation used by native `rooms-session`. Tab hosting uses
`rooms_runtime::documents::VolatileDocuments`, matching the existing browser
Host lifetime; workspace preferences and archive records persist separately.

`transport::open` composes one Runtime around the application's chosen Host.
`WebFront::deployment` forwards complete TCP, keyed/Noise TCP, iroh and onion
locators through the page's native web front, preserving their routing hints.
The front owns target admission. It also authenticates the remote iroh QUIC
peer, so that route explicitly trusts the deployment for its key proof. Other
forwarded profiles receive no synthetic key proof. Both ends share the target
byte ceiling and native iroh dial allowance.

Locator-selected keyed/Noise relay routes use `glowcap::browser::relay`.
WebRTC uses the directory selector below. The page's relay owner retains the
registration and supplies readiness and incoming-session admission to the
application lifetime.

`signaling::connector` composes WebRTC with the Rust Runtime. Its selector reads
from the application's directory inventory and returns one held client before
any awaited effect. A pending dial carries the session that supplied its oldest
remaining give. The connector refuses a directory from another Host or another
introducing session; it never uses a global routing window. Explicit dials need
an application-selected directory. Local pages use their directory registration;
outbound attachment can also hold a signaling-only registration for a foreign
directory. Share can also establish this signaling registration before joining
any room. A chosen workspace nickname supersedes that temporary name; the
signaling supervisor yields to the workspace listener. Both paths use the same
Rust connection pool and Host.

`signaling::dial` carries WebRTC preparation through that held Rooms directory.
`signaling::Listener::open` files an answering inbox and returns only after the
directory accepts it. Drive `Listener::serve` inside the Host's LocalSet; its
callback transfers each established Session to the application. Both paths
use the directory connection's Host and platform scheduler, so registration,
signaling and peer identity cannot accidentally belong to different local Hosts.

The listener admits at most 32 pending offers and 64 bounded candidates per
offer. Each offer obtains fresh application-supplied ICE configuration. A
30-second preparation deadline includes that configuration request; the
caller also supplies a finite, nonzero OCapN handshake budget. Shutdown stops
admission, closes the inbox, and joins preparation workers. An already admitted
handshake finishes within its budget and its result is closed if shutdown won.
Sessions already handed to the application outlive the signaling listener.

The directory is an explicit authority choice. A dialing exchange is scoped to
the expected target key; browser DTLS binds the resulting channel to its SDP.
An inbound offer names an exchange, not a caller key, so the accepting side
does not fabricate a verified identity from that exchange ID.

`ice::Source::deployment()` reads native `rooms-web`'s `/ice` endpoint. Concurrent
readers share one request; a later attempt refreshes credentials. Each reader
receives its own browser configuration object. An empty server list remains
empty, and fetch or validation failures are reported without a fallback. The
shared Rooms decoder bounds collections before allocating their contents.
The fetch adapter bounds response bytes before copying them into Wasm.

The application owns the source and closes it before retiring its LocalSet.
Dropping a reader abandons observation; the source still owns the request.
`close` aborts the request and waits for its fetch/body read to settle. An
unexpected worker cancellation reports that retirement was not observed.

`zig build rooms-rust-browser-host-test` exercises both halves in Chromium
through the native `rooms-web` directory. It covers explicit Runtime dials and
three-party handoffs, checks the introducing session delivered to the connector,
and calls the received capability after both directory connections close.
It also checks shutdown during pending ICE configuration.
The same composition calls distinct rooms through native TCP and iroh forwarding,
and exchanges calls in both directions over keyed and Noise relay registrations.
Relay route admission reuses the native route corpus. These scenarios check
physical socket closure and callback retirement; they do not establish live
keyed/Noise TCP or onion forwarding through this Rust browser composition.
Both signaling halves read native `/ice`. Real HTTP fixtures also exercise
credential refresh, coalescing, retry after refusal, oversized responses, and
shutdown during a pending response-body read.
The Chromium scenario also runs the shared session command worker, including
multiple rooms/directories, abandoned replies, timed fact retries and fresh identity
when the volatile owner is replaced. The shared grant worker also executes over
volatile documents in Node and Chromium: issuance, narrowing of held authority,
history permission, revocation and notification-before-reply use existing wire
methods. Native scenarios retain disk failure and restart coverage. Another scenario
opens the same complete session lifecycle as the native executable. It checks
early startup failure, publication collision, command/view ordering, disabled
history at shutdown, and root retirement followed by reissue on the same Host.
Its visualization transport is a focused fixture; separate production-page
scenarios prove browser visualization publishing and page integration.
The native directory reached over a browser WebSocket also runs through the
shared directory owner: adoption commits reachability and retains discovery,
and retiring its watch leaves a sibling client usable.

`storage::Database` opens the existing `rooms-history` version-one IndexedDB
schema without resetting it. `storage::Archive` implements the shared archive
backend using the browser's record and revision indices. Record replacement,
blob positions, byte accounting and revision advance commit atomically. Retained
writes also compare their recording epoch in that transaction, so an older tab
cannot refill erased history. Source identity and revision survive retention
erasure. Explicit **Delete browser data** closes the recorder connection and
deletes the entire database, including obsolete schemas and device identity.
The deletion request retains its completion effects after a blocked reply or
abandoned observation. Repeated requests observe the same pending deletion;
success fences the old recorder and clears its volatile content and blob cache.
Attached pages erase their own device storage without changing remote retention.
Workspace removal follows archive deletion and reports partial completion when
browser storage refuses the second effect.

Request continuations enqueue their work inside IndexedDB's active event
callbacks. Transactions retain those callbacks until complete or abort, even
when the caller stops waiting. The serial archive executor observes an abandoned
write's outcome before admitting another operation. Closing a connection stops
admission and waits for its active transactions; other connections remain usable.
Stored tuples share the application archive grammar and keep their existing
BigInt fields and exact UTF-16 text. Invalid stored data produces an error.

Blob staging hashes 64 KiB source chunks before constructing immutable browser
Blobs. Reads check current committed record authority, then verify content outside
the transaction in bounded chunks. A cache holds at most 32 verified Blobs and
64 MiB of content; it can reuse verified content for the same digest after
checking current authority, without hashing the whole file for each chunk.
The local production session uses `PageArchive`, with a visible memory fallback
only when storage is unavailable at startup. Retention and archive work use the
shared runtime. Failures retain their concrete cause through the application
failure channel, and Chromium scenarios cover retention and erasure.
