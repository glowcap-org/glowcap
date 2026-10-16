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

All four wrap the same C ABI and present the same application model:

- A `Session` is a conversation with one CapTP partner.
- A `Host` shares one identity and one handoff registry across several
  sessions.
- A `Ref` is a capability. It belongs to the Host, not to any one session.
  C calls it `GlowcapReference`, and the owning Zig APIs call it
  `driver.Capability`.

## Shared API

Names follow each language's conventions. Each binding README gives the
concrete signature and how ownership is expressed.

| Operation | Purpose |
| --- | --- |
| `runtime.connect(locator)` | Dial an `ocapn://` peer through the transports you composed into the Runtime and return a session. |
| `transport.listen(config)` | Accept partners and return one session per connection. |
| `session.listen(ref)` | Ask to be notified when a far capability you hold settles. CapTP 1.0 accepts far promises and live far objects. `glowcap-next` accepts only far promises. |
| `fetch(name)` | Fetch a capability published by the partner. |
| `publish(name, behavior)` | Make a local behavior fetchable by name. |
| `spawn(behavior)` | Create a local actor and return its capability. |
| `send(ref, verb, args)` | Call a capability and return a promise for its answer. |
| `tell(ref, verb, args)` | Send without asking for an answer. |
| `serve()` | Keep handling inbound calls until the session closes. |
| `close()` | Close the session. |
| `publishDurable(behavior, entropy?)` | Create a durable swiss name for a behavior. Omit the entropy to generate it locally. Keep it to restore the same name on a Host rebuilt from the same seed. |
| `closed()` | Wait for the session to end, without closing it or starting inbound delivery. TypeScript has `onClose(listener)`, which runs a callback once when the session ends. Racket calls it `session-wait-closed`. |

Rust, Python, and Racket load the Host and the driver, then install the
transport archives you need ([Using glowcap from C](../docs/consuming-from-c.md)
lists them). Wasm, browser WebRTC, and a bare relay locator drive the byte-fed
Host directly instead. To listen on a wildcard interface (`0.0.0.0` or `::`),
give an advertised host, because partners dial it and the bind address is only
a local socket.

The bindings also restore saved references (sturdyrefs), pipeline calls on
promises, attenuate, revoke, and collect references no peer still holds.
That last one, distributed garbage collection, is on by default in Rust and
opt-in per session elsewhere.

Field, index, and tag projections over an unresolved remote answer use the
`1.0` wire operations. On `glowcap-next`, await the value before projecting it
locally. Ordinary call pipelining remains available on both profiles.

### References

A `Ref` is opaque. Pass it as an argument and the binding picks the wire
reference, so application code never handles import or export numbers.

Two `Ref`s are equal when they name the same capability on the Host: Rust
`==`, Python `==`, Racket `equal?`, and TypeScript `Ref.equals`. TypeScript's
`===` compares wrapper objects, which stay distinct because each is released
separately.

Releasing a `Ref` spends that one occurrence, including its Rust clones:

- Calls through a spent occurrence are refused, even if another occurrence
  keeps the same target alive. Releasing one occurrence does not revoke the
  others.
- Once the release succeeds, the wrapper stays spent. Only a refusal before
  that point can be retried.
- In Racket, a later drain failure is kept on the surviving Host and reported
  when the Runtime closes. It does not undo the release or spend another
  occurrence.

A send that cannot be issued returns a failed promise. TypeScript keeps the
original thrown value through awaiting, indexing into the result, and dependent sends, and
reports a scheduler or callback failure as itself, not as an invalid argument.

### Profiles and limits

Each Host chooses the `glowcap` or `interop` profile as one setting. The binding
looks the name up in generated ABI constants, so an application never pairs a
codec with a CapTP version by hand. The individual codec and version selectors
remain for protocol tests and peers with unusual preferences.

Each Host also takes optional session limits as named arguments. Limits
for accepted frames, queued pending answers, transient outbound bytes, and
durable sent-answer bytes are set independently. An omitted or zero field keeps the
Host's current value, and a change applies only to sessions created afterwards.

## A call can introduce another peer

Three-party handoff is part of the ordinary call path. If a result names a
capability hosted by another peer, the Host opens or reuses the required
session and returns the live capability.

`send_redeeming` (named in each language's style) covers the case where the
caller also needs the direct exporter session for session-specific operations
or peer identity. The capability itself stays Host-scoped.

Promises can be call targets before they settle, so a chain of dependent sends
can cross the network in one round trip. Await only the last promise when you
do not need the intermediate results. A promise belongs to the Host that
created it: any Session of that Host may use it, and a different Host refuses
it.

## Closing sessions and hosts

Closing a session ends one connection. Closing a Host first stops its listeners
accepting new sessions, then ends every session it owns, including
connections it opened while redeeming handoffs.

A Runtime owns its Host and transport composition. Closing the Runtime ends its
listeners, Host, and remaining sessions. When several parts of an application
must share one identity, hand the Runtime an existing Host: `adoptHost` in
TypeScript, `adopt_host` in Python and Rust, and `#:adopt-host` in Racket. The
Runtime becomes the shutdown barrier for the Host it adopts.

| Language | Host shutdown |
| --- | --- |
| Rust | `Host::close(PendingWork::Cancel).await` requests terminal close for every clone and waits for the driver loop or Host-owned byte-channel tasks to stop before releasing the Host. |
| TypeScript | `await host.close()` requests terminal close immediately and waits for the driver loop or Host-owned byte-channel work to stop before releasing the Host. |
| Python | `await host.close()` waits for Host-owned dial work and listener shutdown before releasing the Host. |
| Racket | `host-close!` stops the driver loop or byte-channel workers before releasing C-side state. Callback-time release is parked until the turn returns. |

## Where the languages differ

- Rust sessions are `!Send`. Create and use them on one Tokio `LocalSet`.
- Rust's `tell` returns after queueing the delivery. The other bindings wait
  for that write to flush.
- Rust reports a session abort through the promises it breaks rather than an
  error returned by `serve()`.
- Stopping a serve from outside follows each runtime's idiom. A Racket break
  aimed at the serving thread escapes as the break and leaves the session
  live, so a later `session-serve` resumes it. Dropping Rust's `serve` future
  gives up observing the session while delivery continues. Cancelling a
  Python `serve()` task ends that session: the loop closes the transport on
  the way out, as it does for every other exit.
- TypeScript, Python, and Rust keep at most <!-- value ../tools/gen/binding/policy.zig unobserved_outcome_cap -->1,024<!-- /value --> settled outcomes that no
  caller has awaited yet, a cap the binding-policy generator writes into all
  three. Past it, the oldest result is dropped and a late await fails. Racket
  waits at the call site and needs no queue.
- Racket keeps its own actor vocabulary: `spawn`, `$`, `<-`, `on`, `bcom`,
  and `methods`.
- Every binding has a regular check in which Goblins dials it as a server,
  enlivens a Host-wide actor, and calls it. All four also dial Goblins and
  play both application-facing handoff roles.

A `send` or `tell` to an actor spawned by the same session stays in process in
every binding.

Cleaning up a deferred reply uses the Host's `resolver_abandon` operation. It
breaks an answer that is still live, succeeds quietly if settlement or session
shutdown already consumed it, and refuses an id the Host never created. Rust
calls it when a resolver is dropped, TypeScript and Python call it for
automatic async completion cleanup, and Racket exposes `resolver-abandon!`.
Explicit resolver fulfillment and break settle once.

## Transports

iroh, onion, Noise, and WebRTC are the transports for real deployments
([known limitations](../docs/boundaries.md#transports-and-peer-identity) says
what each one proves). iroh and onion are optional archives: iroh links a Rust
library, and onion needs a Tor daemon you run. The TCP archive carries
`noise-tcp`, plus the testing `tcp` and `inproc`.

Applications call `runtime.connect(locator)` after composing the Runtime with
the provider or connector they need. Each optional transport package owns its
locator construction, configuration, setup, and options, and the generic
binding code never names a concrete transport.

### Onion and WebRTC

- Every binding that loads the C library composes onion into the generic driver
  for ordinary Session hosting, and the raw frame handles stay available for
  programs that run their own loop. A program that uses only TCP does not load the onion archive.
- TypeScript's raw onion transport runs on Deno's off-thread FFI. Bun's FFI
  cannot run it without blocking Bun's event loop, so onion operations refuse
  on Bun.
- Rust, Python, Racket, and Deno dial WebRTC through the optional C library
  with `webrtc.provider(signaling)` and answer offers with `webrtc.listen`
  (`listen-webrtc` in Racket): the library runs each signaling exchange and
  your `SignalingAuthority` carries the offer, answer, and candidates. Its configuration is ICE data: URLs plus optional TURN username
  and password. Rust, Python, and Racket also expose the library's raw
  multiplexed readiness and try-I/O interface.
- In a browser, TypeScript uses the browser's `RTCPeerConnection` instead and
  does not load the library. Its browser package dials with `connector` and
  answers with `listener`, over the same `SignalingAuthority`, and the
  `/driver` entry is the Deno provider.

### Relays

The relay package exposes one Zig provider through the C ABI.

- Its configuration is declarative: `ws` or `wss`, system or copied-PEM trust,
  and how registration works. A binding never parses a certificate or holds
  TLS state.
- All four bindings offer managed keyed and Noise relay listeners. A listener
  registers one durable Host identity, publishes the relay-routed locator, and
  accepts sessions through the binding's ordinary server type.
- Managed browser and event-loop connectors use their runtime's own WebSocket,
  while the byte-fed Host still handles Noise and CapTP.
- Failures from installing a provider, closing a listener, or releasing the
  loop come back as one versioned failure record. A binding reads that record
  and never parses error text.
- If the final release is refused, the binding retries it once at each later
  safe point and stops when a result arrives. A release or cleanup failure
  along the way is recorded as a consequence of the original failure.

Rust keeps unfinished releases if their thread exits, because the C code may
still borrow the Rust callbacks or allocator. Finish close and any required
recovery on the owning thread to reclaim them. Abandoned releases stay
allocated for the process lifetime.

### Failures with no caller

Some failures have no caller left to receive them, such as a finalizer that
refuses or a shutdown step that fails after the code that asked for it has
moved on. Such a failure becomes one typed record in a bounded list the Host
keeps, and the application drains that list when it chooses:

- Rust: `Host::take_failures`
- TypeScript: `host.takeFailures()`
- Python: `host.take_failures()`
- Racket: `host-take-failures!`

A full list drops its oldest record and counts the loss, so a drained set
never looks like a complete history. A failure that a call returns, or that a
close reports, never appears in the list as well.

## Building and checking

```sh
zig build bindings
```

The complete binding check needs Cargo, Deno, Bun, Python, and Racket, which
the devcontainer includes. Each language README lists focused build steps.

- Binding maintainers: [Developing a binding](DEVELOPING.md). The proof
  families, one scenario run once per language, live in
  [`proofs/`](proofs/README.md).
- Packagers and release operators:
  [Finding and publishing the C archives](PACKAGING.md).

## Loam resources

Rust's optional `loam` feature manages persistent Loam resources through
`libglowcap_loam` and its LMDB companion, using the same Host and capabilities
as the rest of the binding. The [lifecycle
guide](../docs/loam/c-and-rust.md) covers the API and its tests. Compiled for
`wasm32-unknown-unknown`, the same feature stores to IndexedDB, as the [browser
guide](../docs/loam/browser.md) describes. TypeScript, Python, and Racket have
no Loam API.
