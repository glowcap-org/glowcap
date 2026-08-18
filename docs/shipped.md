# What ships today

pancake is unreleased, but the library, bindings, transports, and tools below
are implemented and checked in this repository. Read
[known limitations](boundaries.md) before deploying it and
[stability](stability.md) for the evidence behind each support claim.

## Application APIs

| Surface | What it provides |
| --- | --- |
| Zig | `driver.Session` connects or listens, fetches and publishes capabilities, calls them, and redeems three-party introductions. `driver.HostRuntime` owns the sessions behind that API. |
| Sans-I/O Zig | `engine.Peer` exposes the protocol engine without sockets or scheduling. Callers feed frames, step the engine, drain output, and handle events. |
| C | Opaque handles, fixed-width result codes, explicit release, and a close that takes a pending-work policy (`PancakeCloseOptions`). Separate archives cover the core, host, native loop, and transports. Each transport archive exposes a build-derived fingerprint, and generated binding loaders compare it before any other call so a stale companion is refused. Structured diagnostic reports validate stable result codes and consequence shape before crossing into retained storage; fallible blocking transport calls can return their worker-thread diagnostic in caller-owned storage. Every status call begins a fresh archive-local diagnostic fact, so an undetailed refusal cannot inherit an earlier call's cause. |
| Bindings | Rust, TypeScript, Python, and Racket expose the same session and actor model through the C ABI. They can dial, listen, host objects, call far objects, and pass capabilities. |
| Browser | `@pancake/web` runs a full peer in WebAssembly. A browser can host objects, answer calls, redeem handoffs over WebSocket, register for sealed `noise-relay` cold-dials, and hold an ordinary keyed session over WebRTC after signaling. |

The [Zig examples](../examples/README.md), [C guide](consuming-from-c.md), and
[binding contract](../bindings/README.md) are the entry points for those
surfaces.

Binding fronts compose `libpancake_host` and `libpancake_driver`. The
driver provides one generic dial/listen/event ABI over an adopted Host. The TCP
provider package owns `tcp`, `keyed-tcp`, and `noise-tcp`; separately built
transports register through the common ABI. The iroh provider owns both dial
and listener operations, and the onion archive supplies the standardized Tor
transport without teaching the driver its symbol. Zig and all four bindings
host onion through the same Session listener lifecycle as the
other providers; only the onion package interprets the listener's opaque
restoration bytes as a Tor service key. An idle Host that is not yet
pumping can move into this runtime in one step: success preserves its identity
and capabilities, and a refused transfer leaves the original Host untouched.
After a successful transfer, later setup failure preserves that valid adopted
Host for retry. Listener
close preserves sessions already yielded. Wasm and explicitly supplied byte
channels use the byte-fed Host instead.

## Protocol

- **Sessions.** pancake negotiates a signed CapTP session and owns its
  imports, exports, answers, and releases. It validates messages before
  applying them and sends a typed abort when a protocol error requires the
  session to close.
- **Calls and promises.** Applications can fetch a bootstrap capability, call
  it, send without waiting, and pipeline calls or field, index, and tag
  projections through an unresolved answer. Pancake accepts the OCapN 1.0
  `op:untag` operation unconditionally; it sends one only when the partner's
  signed hello advertises the independent `untag` feature, so a silent Goblins
  peer remains on the proven compatibility set without redefining the version.
  V1.0 resolver-only calls retain a typed local answer through the same reply
  path without fabricating a wire position; every `u64` remains available to a
  partner as an answer position, and wire GC cannot alias the local row.
  One-way sends use the draft's answerless `op:deliver` form; there is no
  separate `op:deliver-only` operation in the pinned draft or Goblins.
- **Persistent references.** A sturdyref is a durable peer-locator plus swiss
  name that can be enlivened into a live capability. Session-level enlivenment
  checks the complete peer locator before cache lookup or wire traffic;
  repeated enlivenment on that session shares the same import. A mismatched
  peer or an accepted plain-TCP assertion is refused.
- **Three-party handoff.** A capability received from one peer can be returned
  or passed recursively to another. Inbound signed gives become Host-owned
  promises immediately. Outbound foreign objects and promises wait as one
  bounded transaction until every gift id, exporter deposit, shared promise
  listener, recipient escrow, and rewritten message can commit. Core and C
  Host cover terminal failure. Node-local routes use an explicit reference arm,
  so every `u64` remains available to a peer as a wire import and an unlowered
  route is structurally refused by codecs. The recurring Deno, Python, Rust,
  and Racket gifter matrix proves two nested gives against live Goblins.

- **Relayed promise settlement.** When a shared home promise settles, its
  complete Passable value crosses Host identity once and reuses the bounded
  Passable transaction for each recipient. Nested objects become gives, nested
  promises become successor proxies, and a
  recipient that cannot admit its projection breaks without publishing a
  prefix or rolling back a sibling.

- **Handoff capability ownership.** Deposited gifts keep the exact actor in the Host Vat
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Zig and the bindings can also listen for settlement of a promise received
  from a peer
  ([ADR-0095](decisions/adr/ADR-0095-listening-on-a-received-promise.md)).
  Gifts and replay counters live on the sessions that own them; product Hosts
  mint a fresh signing key per session
  ([ADR-0100](decisions/adr/ADR-0100-session-owned-handoff-authority.md),
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md),
  [ADR-0116](decisions/adr/ADR-0116-inline-passable-handoff.md)).
- **Identity.** A session can report the identity its handshake established.
  On `driver.Session`, the C ABI, Wasm, and the bindings, every application
  capability is one opaque Host-scoped identity
  ([ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md)).
  Repeated lifts on one live exporter session — including a target reached
  directly and through three-party handoff — converge on that identity. C
  compares the opaque ids; Rust, Python, and Racket use their native equality
  operations, and TypeScript uses `Ref.equals` because each wrapper occurrence
  independently owns one native retain. Release state is not part of equality.
  Wire positions surface only on the low-level `engine.Peer` and
  `BlockingSession` tiers.
- **Publication.** Each session reaches the Host's shared Vat through its own
  Port. Publishing changes discovery only; issued capabilities and deposited
  gifts keep the exact actor until their roots release
  ([ADR-0101](decisions/adr/ADR-0101-actor-roots-and-reclamation.md)).
  Durable publication is a separate namespace
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)): the Host
  mints an unpredictable swiss name, never reassigns it, and returns the
  complete sturdyref. Host enlivenment selects a live matching session or
  dials the sturdyref peer itself.
- **Locators.** Zig, C, and the bindings parse and format `ocapn://` peer and
  sturdyref URIs. Sturdyref helpers require the CapTP profile that owns the
  swiss-number path form; no C or binding helper silently chooses one.
  Applications dial through a locator rather than a transport-specific
  session API.
- **Resource limits.** Session tables, projection depth, nesting depth, and
  Cap'n Proto traversal are bounded. Distributed garbage collection is
  available as a per-session opt-in in every binding: fetched capabilities,
  fulfilled far results, and recursively nested delivered arguments all return
  their opaque Host retain through one finalizer seam. A final import release
  also clears sturdyref cache state and makes every old host route fail closed
  before the partner may reuse that position.
- **Unreturned failures.** The vendor-neutral diagnostics layer and
  `PancakeContext` provide one typed, bounded journal for a failure whose last
  deterministic recipient has gone
  ([ADR-0115](decisions/adr/ADR-0115-structured-diagnostic-waist.md)). Recording
  allocates nothing, saturation preserves an explicit sequence gap, and the C
  claim API leaves a record queued when caller storage is too small. Contexts
  assign every native Host a stable nonzero lifecycle ID, so reports from Hosts
  sharing a journal remain distinguishable without treating reusable addresses
  as identity. Runtime-surviving binding records use the same aggregate text
  bound and truncation flags. Returned errors, peer aborts, and protocol trace
  remain separate authorities. Native
  driver events use the same primary/first-consequence/count vocabulary, so an
  asynchronous dial, listener, or wire-close recipient does not flatten its
  cleanup chain merely because it crosses C. Every native terminal event owns
  queue capacity before its transition commits: opens and listeners reserve at
  admission, wires at adoption, and completions while their Host action is
  still parked. Provider installation and final driver release return a
  versioned caller-owned record with the exact primary, first consequence, and
  total consequence count; every binding projects that record without parsing
  thread-local diagnostic text.
- **Close.** Every owning front closes under an explicit pending-work policy
  ([ADR-0114](decisions/adr/ADR-0114-pending-work-close-policy.md)): cancel
  stops admitted work at once, finish seals admission and drives already
  admitted work within a bounded grace, and expiry escalates to cancel. Each
  owner holds one close barrier. The policy ships on the Zig core Host, the C
  ABI (`pancake_host_close`, `pancake_host_close_progress`, and
  `pancake_host_lifecycle_state`), the driver loop, and all four language
  bindings. Rust Host background failures retain their exact primary, first
  consequence, and saturated consequence count. Racket's Host close barrier
  retains the same shape from Host-owned exporter serve, failed-dial cleanup,
  or native driver-loop work, so a second background failure cannot disappear
  with its thread or replace the primary dial refusal. Racket's raw iroh
  endpoint likewise retains its readiness-loop failure across repeated endpoint
  close. Its WebSocket
  adapter joins reader and close workers, preserves receive errors rather than
  rewriting them as EOF, and returns their exact first failure from close. The
  Racket reference relay joins both pump legs and its watchdog, then exposes an
  ordered aggregate containing the exact primary and every close failure.
  Racket tracing remains non-load-bearing while observer exceptions enter the
  same typed `PancakeContext` queue claimed through `host-take-failures!`.
  Racket deferred drain effects and failed-establishment cleanup retain their
  exact failures at Host close, and only the behavior invocation inside a
  native trampoline translates an application exception into a broken answer.
  Onion and relay-used iroh finalizers contain native release exceptions on the
  collector thread and retain normalized events in the one bounded,
  process-surviving runtime failure queue; explicit release continues to raise.
  The Racket binding checks every generated C ABI return code as its exact
  `exn:fail:pancake` code and reads the owning archive's diagnostic once.
  Its native-loop close projection snapshots a local typed abort before
  releasing the session, so a queue-cap refusal remains `QueueCapExceeded`
  through serve and repeated close.
  Python Sessions expose their ordered `terminal_failures`; close raises the
  exact first object while retaining later native-result, transport, and serve
  failures on the Session. Repeated close joins the already-published barrier
  instead of re-running teardown. Retained exception objects are capped at 64,
  while `terminal_failure_count` preserves the saturated total occurrence
  count; two distinct failures are never collapsed merely because they came
  from the same operation.
  Python Hosts retain ordered failures from admitted asynchronous behavior
  settlements, scheduled action drains, and loop shutdown. They cancel and
  join settlements still pending after native shutdown. Close returns the
  exact first failure, while `terminal_failures` exposes later failures under
  the same bounded occurrence contract.
  Callerless callback failures prefer their live Context queue. If that
  recorder fails or the Context is already gone, the bounded process queue
  preserves both the original and recorder failure.
  Python driver loops attempt explicit native release once and retain ordered
  background and release failures for Host shutdown diagnostics.
  Python iroh readiness faults settle every active and future waiter with the
  exact callback failure instead of rewriting the fault as a clean peer close.
  Failed Python relay and iroh connector establishment joins transport
  rollback, keeps the establishment error primary, and retains cleanup failure
  on the Host.
  The TypeScript managed WebSocket and Deno TCP channels publish one bounded,
  idempotent close barrier; the relay joins both legs and both barriers while
  retaining later close refusals. The Python reference relay likewise joins its
  WebSocket and channel close barriers and preserves the exact first I/O failure
  plus ordered close consequences. Racket and Rust relay pumps already enforce
  the same result-bearing pair teardown.
  TCP connector rollback follows the same joined barrier. Rejected TCP, Onion,
  relay, and iroh provider installation retains cleanup failure on the Host
  without replacing the exact installation error.
  Cancellation of Python iroh construction remains cancellation after joining
  its worker and cleanup; a construction or release failure with no surviving
  owner enters the bounded, process-scoped `take_runtime_failures()` seam.
  Rust errors retain a bounded ordered secondary prefix and the total observed
  consequence count. Failed Runtime construction
  raises the exact setup error while attaching a created Host's close failure.
  A failed Rust Host dial retains session rollback failure beside the exact
  dial error on the Host close barrier instead of discarding cleanup outcome.
  Rust implicit Host, driver-loop, and relay-runtime destruction is non-panicking
  and publishes the shared failure schema through the bounded runtime queue with
  observable saturation. Actor-cell and trace-sink panics use their surviving
  Context, preserving panic text while remaining outside protocol control flow.
  Onion setup rollback retains listener cleanup failure beside its exact setup
  cause. Consuming netlayer close retains listener then parent-release failure.
  Implicit Onion netlayer and generic loop-listener close publish failure through
  that journal.
  Rust driver-loop listener cancellation now terminalizes failed native cleanup.
  Background failure retains later driver release failure as secondary. A runtime
  listener-state mismatch returns a typed internal error instead of panicking the
  process.
  Rust iroh task and readiness mutex poison is recovered under the transport's
  container-only critical-section invariant. The binding publishes a typed
  runtime failure and clears the poison so later calls do not repeat a process
  panic.
  The Rust reference relay observes target and WebSocket read, write, shutdown,
  and close failures. It retains cleanup after the primary failure and joins each
  pair-atomic task cancellation. It recovers diagnostic mutex poison. Its
  process-owner boundary returns accept and stdout failures.
  Rust iroh endpoint and stream close retain native release failure after an
  earlier close or loop failure. Iroh and TCP listener setup rollback retain
  listener cleanup failure beside the exact setup cause. Both use one shared
  cleanup-composition primitive.
  Native WebRTC peer close is admitted once into an endpoint-owned task
  barrier. Crate close refusal, timeout, cancellation, or panic survives the
  peer handle and returns from final endpoint/provider release instead of
  disappearing with a detached task. Its synchronous control calls remain
  usable from a consumer already inside Tokio; the sidecar yields a
  multithreaded ambient worker or borrows a scoped helper for a current-thread
  runtime instead of invoking nested `block_on`.
  The native iroh sidecar uses the same surviving-owner rule for detached QUIC
  writers: write, finish, cancellation, and panic failure remains on the
  endpoint release barrier. Its runtime owner is safe to release from inside a
  consumer's Tokio runtime, and its blocking compatibility calls use the same
  ambient-runtime seam rather than panicking on nested `block_on`.
  Rust custom allocator panics remain contained at the C callback boundary.
  Allocation still degrades to the native out-of-memory path, while allocation
  and free panic text is retained in the bounded runtime failure queue.
  Rust callerless failures prefer their Context queue. A refused diagnostic
  record preserves the normalized original and the recorder refusal in the
  bounded runtime queue without changing the operation outcome.
  Rust Host dial cancellation joins its owned task. Expected abort is inert;
  task panic or join failure is primary, and later native cancellation failure
  remains attached as cleanup.
  TypeScript retains a bounded ordered secondary prefix and explicit total
  consequence count without replacing the exact primary object, including for
  frozen application errors. Detached reported
  dial serving publishes its serve and later transport-close failures to the
  Host owner instead of converting them into an unobserved rejection.
  TypeScript callerless failures prefer the live Context queue. A missing or
  refused recorder preserves both the original and recorder failure in one
  bounded process queue, atomically claimed through `takeRuntimeFailures()`.
  Python Runtime retains failed-open and cleanup errors in order while raising
  the exact setup failure, and records explicit close failure on the same
  surviving owner.
  Explicit Python native-handle close raises release failure. Finalizer-only
  native release is nonfatal and normalizes into the shared schema through the
  bounded `take_runtime_failures()` queue; displaced records remain explicit on
  the first surviving event. Stable primary and first-secondary result codes,
  the first secondary detail, and the total consequence count survive that
  projection. Trace-sink exceptions remain outside protocol
  control flow and report through the owning Host's Context (`take_failures()`).
  Racket finalizers use the same process-scoped schema and atomic bounded claim;
  there is no separate nondestructive read/clear journal. Callerless failures
  prefer the Host Context and fall back with the recorder refusal to that
  process queue if Context recording fails. Its process projection preserves
  stable pancake primary and first-secondary result codes and the total
  consequence count.
  A local fire-and-forget behavior failure cannot become a reply, but its Host
  retains the exact exception instead of silently discarding it.

The passable-value model and typed C/binding waist cover the pinned OCapN
scalar and aggregate forms, including arbitrary-precision Integer, Struct, and
Error-as-fulfilled-data, plus the Set and Keyword forms used by Goblins. Error
data remains distinct from a broken reply at the Host, C, Rust, TypeScript,
Python, and Racket surfaces. OCapN Null is not implemented; see
[protocol limitations](boundaries.md#protocol-and-interop).

## Codecs

| Codec | Use |
| --- | --- |
| Syrup | The interoperable OCapN wire format. Its fixtures are cross-checked against upstream Syrup encoders. |
| Cap'n Proto | A pancake-to-pancake format with checked golden frames. It is not a Goblins format. |

The authenticated OCapN 1.0 profile uses Syrup. Two pancake peers can prefer
Cap'n Proto or `"pancake-next"`. Each side puts that offer in the hello's
locator hints, and `engine.Peer.settleNegotiatedProfile` settles the pair after
both verified hellos arrive.
[ADR-0103](decisions/adr/ADR-0103-hello-carried-profile-offers.md) records that
handshake. An absent offer is the v1.0/Syrup floor, so Goblins traffic stays
wire-identical. Over onion the offer is sent only when the partner is known to
be pancake, because the pinned Goblins cannot dial a hinted onion locator. A
dial includes the offer when it was handed the pancake-hinted address form. An
accept includes it when answering a hello that already stated one.
[ADR-0118](decisions/adr/ADR-0118-onion-profile-by-knowledge.md) records that
exception. Every binding exposes the host preference selector. Binding checks
(`zig build rust-dogfood`, `deno-dogfood`, `python-dogfood`, and
`racket-dogfood`) exercise the C ABI as a real consumer over a live Cap'n Proto
socket. Zig applications can add another codec through the open registry
without changing the protocol core.

## Transports

| Transport | Use |
| --- | --- |
| `tcp` | Plain TCP and the broadest interop path. It is cleartext. |
| `keyed-tcp` | TCP with a key designator as the dial target. The channel is cleartext and unauthenticated; the key does not prove possession. |
| `noise-tcp` | The keyed-tcp grammar with ADR-0107's sealed channel on the wire: a Noise_XK handshake between the two peers encrypts the channel end to end, and completing it proves the dialed key. The Zig host tiers, C driver loop, and all four native bindings dial and listen on it. |
| `keyed-relay` | Cleartext WebSocket to a relay; the key designator is a dial target with no listening address. Trusted network and relay only. |
| `noise-relay` | The keyed-relay pipe with ADR-0107's sealed channel: CapTP peers run Noise_XK with each other, and the relay only forwards ciphertext. The native provider and every native binding compose it. The managed browser connector uses the same byte-fed Host sealing and can register or dial this profile. |
| `inproc` | An in-process connection for tests and deterministic local scenarios. |
| `iroh` | Encrypted QUIC with discovery, relays, and a node ID that also serves as the OCapN designator. |
| `webrtc` | An encrypted DataChannel reached through signaling. It carries a normal keyed OCapN session once the channel is open. |
| `onion` | The standardized OCapN Tor netlayer. A version 3 service id addresses an encrypted, location-hiding circuit; Tor proves the service to the dialer but reveals no caller identity to the listener. |

`onion` is the draft's transport and the one Goblins ships. Live Goblins also
meets pancake over `tcp` and `iroh` through adapters in
`conformance/goblins-peer/`. In-tree onion checks use fake SOCKS and control
daemons under `zig build check`. Live Tor proofs are `onion-interop`,
`goblins-onion`, `ocapn-conformance-onion`, `bindings-onion`, and
`demo-rooms-onion`. See [stability](stability.md) and
[known limitations](boundaries.md).

TCP, iroh, and relay join the native loop as transport packages. WebRTC joins
that same loop once signaling has opened a DataChannel. A relay
locator can carry its `rendezvous-relay` route, with deployment configuration
retained only as the fallback for a bare locator. A bare `webrtc` locator
needs configured signaling authority (`zig build webrtc-loop`,
`zig build webrtc-bridge-redeem`). Browsers without native sockets use the
byte-transparent relay in Deno, Python, Rust, and Racket. The relay forwards
bytes without parsing CapTP or holding a capability.

`noise-tcp` and `noise-relay` run ADR-0107's Noise_XK channel on the byte-fed
Host and native tiers; `BlockingSession` refuses both symbols. The optional
native relay module composes `ws` and `wss` over one provider, while
browser-managed WebSockets use their runtime's carrier. The remaining secure
relay evidence is recorded under
[browser reachability](boundaries.md#browser-reachability).

See [known limitations](boundaries.md#transports-and-peer-identity) for the
security and reachability differences between these choices.

## Actors and hosting

`actors.Vat` adds a Goblins-shaped actor layer above the protocol engine. It
supports local actors, eventual sends that return vows, hosted objects,
forwarding, attenuation, and revocation. Optional snapshots and restore apply
only to local actor state; they never rewind a network session.

A Host owns one Vat and gives each session Port its own ingress, so one
connection's runaway local work is condemned without draining a sibling's.
Queued turns are admitted under per-ingress budgets
([ADR-0099](decisions/adr/ADR-0099-shared-vat-scheduling.md)).

The same hosting model is available in each language binding. The browser peer
can answer a caller over the connection the call arrived on, so a peer with no
listening socket can still receive replies and participate in a handoff.

## Tools and applications

- `zig build` installs the `pancake` command. It can listen, call, fetch,
  enliven, run an interactive CapTP lab, serve a curated MCP interface, and
  join a rooms session.
- The rooms, tasks, and tools examples run one server with clients written in
  several bindings.
- The rooms application exercises browser peers, room and direct-message file
  transfer, WebRTC, and relay rendezvous. Direct files are sender-hosted blob
  capabilities on the existing peer session, so the transport stays below the
  message contract.
- Starting the rooms web UI with `--diagnostics` (or `-Ddiagnostics` on the
  zig step) publishes an inspect object under an unguessable swiss number on
  that Host. Fetching the swiss number is the capability; the directory itself
  does not answer `snapshot`. `--admin-listeners` (or `-Dadmin-listeners`)
  publishes a listener-admin object the same way. Holding its swiss number
  lists one seat per transport the server can realize, each described in the
  owning provider package's own words along with the knobs its up accepts.
  It brings a listener up and takes one down; an up names values for those
  knobs — the tcp profiles' bind host, port, and advertised host, the relay
  profiles' relay — and what it leaves out falls to the server's own
  defaults. The listener carrying the announced locator
  refuses to go down, and a seat the server already knows cannot come up
  says so standing, both with words saying why. `--viz` (or `-Dviz`) serves
  the live timeline endpoint on port 9300 (`PANCAKE_ROOMS_VIZ_PORT` moves
  it) and mints the viz capability the same way.
- Changing a line, taking one back, and saying what a room is about are
  references the room hands out rather than checks it performs. Posting answers
  with a reference to the line it made, and subscribing answers with the
  authority to set the topic, so the application contains no role, no rank, and
  no test of whose line it is. What a member can do differs between two people
  in one room because they hold different references.
- ocapnviz can open a read-only trace sturdyref as a browser OCapN peer. Its
  production Chromium check covers replay, subsequent live observations, and
  exclusion of the observer session from its own topology. The rooms trace
  endpoint behind that sturdyref admits no socket — viewer or trace producer —
  without the viz capability the sturdyref carries (ADR-0120).
- The accountability example layers signed identity and an audit log above
  ordinary capabilities without changing CapTP.

[`docs/cli.md`](cli.md) is the command-line guide. The
[examples](../examples/README.md) and [apps](../apps/README.md) pages list the
programs.

## What checks it

`zig build check` is the in-tree check: it runs the tests, examples,
architecture checks, committed protocol fixtures, and allocation and footprint
budgets, and it compiles the live-interop drivers. It does not run an outside
protocol implementation.

`zig build check-external` runs the core outside-authority baseline: the
upstream OCapN suite, live Goblins sessions in both call directions and all
three handoff roles, and pinned-source findings. It also regenerates the Syrup
corpus with the upstream encoder. The recurring
[`ci/gates.sh`](../ci/gates.sh) sequence runs that evidence plus each language
binding as a live Goblins client through the C ABI and the Deno binding as a
host. Those steps require their named external runtimes and are not evidence
supplied by `zig build check`.

The three-peer rooms checks are on-demand: a pancake browser tab redeems a
room's introduction and holds a direct message with a real Goblins vat, off the
room's path, over cleartext TCP and encrypted QUIC. They require Chromium and
therefore do not run in the recurring sequence.

[Stability](stability.md) says which checks run on main-branch pushes and pull
requests.
[Community review](community-review.md) records exactly what the outside-peer
checks do and do not prove.
