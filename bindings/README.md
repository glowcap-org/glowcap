# Language bindings

glowcap has bindings for Rust, TypeScript, Python, and Racket. They live in
this repository. Pin a checkout, run `zig build`, and follow the README for
your language.

| Language | Start here | Runtime |
| --- | --- | --- |
| Rust | [`rust/README.md`](rust/README.md) | Tokio for the async session API. |
| TypeScript | [`ts/README.md`](ts/README.md) | Deno, Bun, and browser WebAssembly. |
| Python | [`python/README.md`](python/README.md) | Python 3.11+ with `asyncio`. |
| Racket | [`racket/README.md`](racket/README.md) | Racket threads and ports. |

All four wrap the same C ABI and present the same application model. A
`Session` represents one CapTP partner. A `Host` shares one identity and
handoff registry across several sessions. A binding `Ref` (C
`GlowcapReference`) is the host-scoped capability; Zig owning APIs name the
same row `driver.Capability`.

## Shared API

Names follow each language's conventions, but the conceptual operations are the
same. Each binding README gives the concrete signature and how ownership is expressed.

| Operation | Purpose |
| --- | --- |
| `runtime.connect(locator)` | Dial an `ocapn://` peer through explicitly composed transport authority and return a session. |
| `transport.listen(config)` | Accept partners and return one session per connection. |
| `session.listen(ref)` | Subscribe to the listen notification for a held far capability; 1.0 accepts far promises and live far objects, while glowcap-next accepts only far promises. |
| `fetch(name)` | Fetch a capability published by the partner. |
| `publish(name, behavior)` | Make a local behavior fetchable by name. |
| `spawn(behavior)` | Create a local actor and return its capability. |
| `send(ref, verb, args)` | Call a capability and return a promise for its answer. |
| `tell(ref, verb, args)` | Send without asking for an answer. |
| `serve()` | Keep handling inbound calls until the session closes. |
| `close()` | Close the session. |
| `publishDurable(behavior, entropy?)` | Mint a durable swiss name for a behavior. Omit entropy to draw it locally; retain it to restore the same name on a Host reconstructed from the same seed. |
| `closed()` | Observe session retirement without requesting close or starting inbound delivery. TypeScript spells this `onClose`; Racket spells it `session-wait-closed`. |

Native bindings load the Host and the driver, then install the transport
archives you need. [Using glowcap from C](../docs/consuming-from-c.md) owns
that archive graph. Wasm, browser WebRTC, and a bare relay locator drive the
byte-fed Host as owned integrations. Binding a wildcard interface (`0.0.0.0`
or `::`) needs an explicit advertised host: the bind address is a local
socket, and partners dial the advertised host.

The bindings also expose sturdyref enlivenment, promise pipelining,
attenuation, revocation, and opt-in distributed garbage collection. A `Ref` is
opaque. Pass it as an argument and the binding chooses the correct wire
reference; application code never manages import or export numbers. Capability
equality follows the opaque Host identity: Rust `==`, Python `==`, Racket
`equal?`, and TypeScript `Ref.equals`. TypeScript `===` compares wrapper
occurrences instead, which remain distinct because every occurrence owns its
own release unit.

Releasing a capability spends that occurrence, including its Rust clones.
Local calls and ABI projection refuse it even when another occurrence keeps
the same target alive. Releasing one occurrence does not revoke the others.
Once native release succeeds, the wrapper stays spent; only a refusal before
that commit is retryable. Racket retains a subsequent drain failure on the
surviving Host and reports it at Runtime close, without refusing the completed
release or spending another occurrence.

A send that cannot be issued returns a failed promise handle. TypeScript keeps
the original raised value through awaiting, projection, and dependent sends;
it does not relabel a scheduler or callback failure as an invalid argument.

Each Host can select the core-authored `native` or `interop` profile as one
choice. The binding resolves that name through generated ABI constants, so an
application does not pair a codec with a CapTP version itself. The individual
selectors remain available for protocol tests and peers with an unusual
preference.

Each Host also accepts selective session-limit options in the language's named
argument convention. Frame admission, pending-answer queue entries, transient
outbound bytes, and durable sent-answer bytes are independent; omitted or zero
fields keep the Host's current policy, and the change applies only to sessions
minted afterwards.

## A call can introduce another peer

Three-party handoff is part of the ordinary call path. If a result names a
capability hosted by another peer, the host opens or reuses the required
session and settles the call with the live capability.

`send_redeeming` (named according to each language's style) is for the less common case
where the caller also needs the direct exporter session for session-specific
operations or peer identity. The capability itself remains Host-scoped.

Promises can be call targets before they settle. A chain of dependent sends can
therefore cross the network in one round trip. Await the last promise when the
intermediate results are not otherwise needed. A promise target is scoped to
the Host that minted it: any sibling Session of that Host may use it, while a
different Host refuses it before interpreting the Host-local vow number.

## Closing sessions and hosts

Closing a session ends one connection. Closing a host first stops its listeners
from admitting new sessions, then ends every session it owns, including
connections it opened while redeeming handoffs.

A Runtime owns its Host and transport composition. Closing one session ends one
connection; closing the Runtime ends its listeners, Host, and remaining
sessions. Applications may explicitly transfer an existing Host when several
fronts must share one identity: `adoptHost` in TypeScript, `adopt_host` in
Python and Rust, and `#:adopt-host` in Racket. The Runtime becomes the shutdown
barrier for the Host it adopts.

| Language | Host shutdown |
| --- | --- |
| Rust | `Host::close(PendingWork::Cancel).await` requests terminal close for every clone and waits for the native loop or Host-owned byte-channel tasks to stop before releasing the Host. |
| TypeScript | `await host.close()` requests terminal close immediately and waits for the native loop or Host-owned byte-channel work to stop before releasing the Host. |
| Python | `await host.close()` waits for Host-owned dial work and listener shutdown before releasing the Host. |
| Racket | `host-close!` stops the native loop or byte-channel workers before releasing native state; callback-time release is parked until the turn returns. |

## Where the languages differ

- Rust sessions are `!Send`. Create and use them on one Tokio `LocalSet`.
- Rust's `tell` returns after queueing the delivery; the other bindings wait
  for that write to flush.
- Rust reports a session abort through the promises it breaks rather than an
  error returned by `serve()`.
- Stopping a serve from outside follows each runtime's idiom. A Racket break
  aimed at the serving thread escapes as the break and leaves the session
  live, so a later `session-serve` resumes it. Dropping Rust's `serve` future
  gives up observing the session while delivery continues. Cancelling a
  Python `serve()` task ends that session: the loop closes the transport on
  the way out, as it does for every other exit.
- TypeScript, Python, and Rust keep at most 1024 settled outcomes that no
  caller has awaited yet, a cap the binding-policy generator writes into all
  three. Past it, the oldest result is dropped and a late await fails. Racket
  waits at the call site and needs no queue.
- Racket keeps its native actor vocabulary: `spawn`, `$`, `<-`, `on`, `bcom`,
  and `methods`.
- Every binding has a recurring check in which Goblins dials it as a server,
  enlivens a Host-wide actor, and calls it. All four also dial Goblins and
  exercise both application-facing handoff roles.

A `send` or `tell` to an actor spawned by the same session stays in process in
every binding.

Deferred reply cleanup uses the Host's `resolver_abandon` operation: it breaks
a live answer and succeeds if settlement or session shutdown already consumed
it. An id the Host never minted still refuses. Rust uses it when a resolver is
dropped; TypeScript and Python use it for automatic async completion cleanup;
Racket exposes `resolver-abandon!`. Explicit resolver fulfillment and break
retain their strict, single-settlement contract.

## Transports

iroh, onion, Noise, and WebRTC are the production paths.
[Choosing a transport](../docs/boundaries.md#transports-and-peer-identity)
says what each proves. iroh and onion are optional archives (iroh links a Rust
sidecar; onion needs a Tor you run). The TCP archive also carries `noise-tcp`
plus testing `tcp` and `inproc`.

Every native binding composes onion into the generic driver for ordinary
Session hosting and keeps the raw frame handles as an explicit embedding
surface. A TCP-only program does not load them. Rust, Python, and Racket expose
WebRTC's optional native C companion as raw FFI, including multiplexed readiness
and try-I/O. Its endpoint config is provider-neutral ICE data: URLs plus
optional TURN username/password credentials. TypeScript instead uses the
browser's `RTCPeerConnection` and does not load that companion. Its browser
package is the application-level WebRTC adapter shipped by the bindings. For
native consumers, the raw companion is the supported embedding surface;
application-level signaling and Host composition remain with the embedder.

TypeScript's raw onion transport runs through Deno's off-thread FFI. Bun's FFI
does not currently provide that execution contract, so onion operations refuse
there instead of blocking Bun's event loop behind a promise-shaped API.

Applications call `runtime.connect(locator)` after composing that Runtime with
the required provider or connector. Optional transport packages own locator
construction, configuration, setup, and operation options; generic bindings
never name a concrete transport.

The native relay package projects one Zig provider through the C ABI. Its
configuration is declarative: it selects `ws` or `wss`, system or copied-PEM
trust, and the registration posture, so a binding never parses a certificate
or owns TLS state. Provider installation, listener close, and the final loop
release all report through one versioned driver-failure record, and a binding
copies its exact primary and cleanup facts rather than reading diagnostic text
as control flow. A refused final release stays retryable: the binding keeps
one retry owner, makes at most one attempt at each later safe runtime
boundary, and retires that owner exactly once when a consuming result
arrives. Any release or cleanup failure along the way is recorded as a
consequence of the original terminal failure. Managed browser and event-loop
connectors use their runtime's WebSocket while the byte-fed Host still owns
Noise and CapTP. All four bindings also expose managed keyed and Noise relay
listeners over the native provider: a listener registers one durable Host
identity, publishes the relay-routed locator, and accepts sessions through
the binding's ordinary server type.

A failure with no caller left to return to is neither logged nor dropped. A
finalizer that refuses, or a retirement that fails after the code that
requested it moved on, becomes one typed record in the Host's bounded
diagnostic journal, and the application drains that journal when it decides
how to respond: `Host::take_failures` in Rust, `host.takeFailures()` in
TypeScript, `host.take_failures()` in Python, and `host-take-failures!` in
Racket. A full journal drops its oldest record and counts the loss, so a
drained suffix never reads as a complete history. Failures a call can return,
and failures a close barrier reports, never appear there twice.

## Building and checking

```sh
zig build bindings
```

The complete binding check needs Cargo, Deno, Bun, Python, and Racket. The
devcontainer includes them. Focused build steps are listed in each language
README.

Binding maintainers should read [Developing a binding](DEVELOPING.md). The
per-binding proof families, one scenario run once per language, live in
[`proofs/`](proofs/README.md).
Packagers and release operators should read
[Finding and publishing the C archives](PACKAGING.md).
