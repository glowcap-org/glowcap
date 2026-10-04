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

Names follow each language's conventions, but the conceptual operations are the
same. Each binding README gives the concrete signature and how ownership is expressed.

| Operation | Purpose |
| --- | --- |
| `runtime.connect(locator)` | Dial an `ocapn://` peer through explicitly composed transport authority and return a session. |
| `transport.listen(config)` | Accept partners and return one session per connection. |
| `session.listen(ref)` | Ask to be notified when a far capability you hold settles. CapTP 1.0 accepts far promises and live far objects; `glowcap-next` accepts only far promises. |
| `fetch(name)` | Fetch a capability published by the partner. |
| `publish(name, behavior)` | Make a local behavior fetchable by name. |
| `spawn(behavior)` | Create a local actor and return its capability. |
| `send(ref, verb, args)` | Call a capability and return a promise for its answer. |
| `tell(ref, verb, args)` | Send without asking for an answer. |
| `serve()` | Keep handling inbound calls until the session closes. |
| `close()` | Close the session. |
| `publishDurable(behavior, entropy?)` | Create a durable swiss name for a behavior. Omit the entropy to generate it locally. Keep it to restore the same name on a Host rebuilt from the same seed. |
| `closed()` | Wait for the session to end, without closing it or starting inbound delivery. TypeScript calls this `onClose`, and Racket calls it `session-wait-closed`. |

Native bindings load the Host and the driver, then install the transport
archives you need; [using glowcap from C](../docs/consuming-from-c.md) lists
them. Wasm, browser WebRTC, and a bare relay locator drive the byte-fed Host
directly instead. To listen on a wildcard interface (`0.0.0.0` or `::`), give
an explicit advertised host. The bind address is only a local socket, and
partners dial the advertised host.

The bindings also offer sturdyref enlivenment, promise pipelining,
attenuation, revocation, and opt-in distributed garbage collection.

### References

A `Ref` is opaque. Pass it as an argument and the binding picks the right wire
reference, so application code never handles import or export numbers.

Two `Ref`s are equal when they name the same capability on the Host: Rust
`==`, Python `==`, Racket `equal?`, and TypeScript `Ref.equals`. TypeScript's
`===` compares the wrapper objects instead. Those stay distinct, because each
wrapper is released separately.

Releasing a `Ref` spends that one occurrence, including its Rust clones.
Calls through a spent occurrence are refused, even if another occurrence keeps
the same target alive. Releasing one occurrence does not revoke the others.
Once the native release succeeds, the wrapper stays spent. Only a refusal
before that point can be retried. In Racket, a later drain failure is kept on
the surviving Host and reported when the Runtime closes; it does not undo the
release or spend another occurrence.

A send that cannot be issued returns a failed promise. TypeScript keeps the
original thrown value through awaiting, projection, and dependent sends. It
never relabels a scheduler or callback failure as an invalid argument.

### Profiles and limits

Each Host can choose the `native` or `interop` profile as one setting. The
binding looks the name up in generated ABI constants, so an application never
pairs a codec with a CapTP version by hand. The individual codec and version
selectors are still available for protocol tests and peers with unusual
preferences.

Each Host also takes optional session limits, using the language's usual
style for named arguments. Frame admission, pending-answer queue entries,
transient outbound bytes, and durable sent-answer bytes are set independently.
An omitted or zero field keeps the Host's current value, and a change applies
only to sessions created afterwards.

## A call can introduce another peer

Three-party handoff is part of the ordinary call path. If a result names a
capability hosted by another peer, the host opens or reuses the required
session and settles the call with the live capability.

`send_redeeming` (named according to each language's style) is for the less common case
where the caller also needs the direct exporter session for session-specific
operations or peer identity. The capability itself remains Host-scoped.

Promises can be call targets before they settle, so a chain of dependent sends
can cross the network in one round trip. Await only the last promise when you
do not need the intermediate results. A promise belongs to the Host that
created it. Any Session of that Host may use it, and a different Host refuses
it.

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
- Every binding has a regular check in which Goblins dials it as a server,
  enlivens a Host-wide actor, and calls it. All four also dial Goblins and
  play both application-facing handoff roles.

A `send` or `tell` to an actor spawned by the same session stays in process in
every binding.

Cleaning up a deferred reply uses the Host's `resolver_abandon` operation. It
breaks an answer that is still live, and succeeds quietly if settlement or
session shutdown already consumed it. An id the Host never created is still
refused. Rust uses it when a resolver is
dropped; TypeScript and Python use it for automatic async completion cleanup;
Racket exposes `resolver-abandon!`. Explicit resolver fulfillment and break
retain their strict, single-settlement contract.

## Transports

iroh, onion, Noise, and WebRTC are the transports for real deployments, and
[known limitations](../docs/boundaries.md#transports-and-peer-identity) says
what each one proves. iroh and onion are optional archives: iroh links a Rust
sidecar, and onion needs a Tor daemon you run. The TCP archive carries
`noise-tcp`, plus the testing `tcp` and `inproc`.

Applications call `runtime.connect(locator)` after composing the Runtime with
the provider or connector they need. Each optional transport package owns its
locator construction, configuration, setup, and options. The generic binding
code never names a concrete transport.

### Onion and WebRTC

- Every native binding composes onion into the generic driver for ordinary
  Session hosting. The raw frame handles stay available for embedding. A
  program that uses only TCP does not load them.
- TypeScript's raw onion transport runs on Deno's off-thread FFI. Bun's FFI
  cannot run it without blocking Bun's event loop, so onion operations refuse
  on Bun.
- Rust, Python, and Racket expose WebRTC's optional native C companion as raw
  FFI, including multiplexed readiness and try-I/O. Its endpoint
  configuration is provider-neutral ICE data: URLs plus optional TURN username
  and password. For native programs this raw companion is the supported
  interface, and signaling and Host composition are up to you.
- TypeScript uses the browser's `RTCPeerConnection` instead and does not load
  the companion. Its browser package is the application-level WebRTC adapter.

### Relays

The native relay package exposes one Zig provider through the C ABI.

- Its configuration is declarative: `ws` or `wss`, system or copied-PEM trust,
  and how registration works. A binding never parses a certificate or holds
  TLS state.
- All four bindings offer managed keyed and Noise relay listeners. A listener
  registers one durable Host identity, publishes the relay-routed locator, and
  accepts sessions through the binding's ordinary server type.
- Managed browser and event-loop connectors use their runtime's own WebSocket,
  while the byte-fed Host still handles Noise and CapTP.
- Provider installation, listener close, and the final loop release all
  report through one versioned driver-failure record. A binding copies the
  exact primary failure and cleanup facts from it, and never makes decisions
  by reading diagnostic text.
- A refused final release can be retried. The binding keeps one owner for the
  retry, tries at most once at each later safe point, and retires the owner
  exactly once when a final result arrives. Any release or cleanup failure
  along the way is recorded as a consequence of the original failure.

### Failures with no caller

A failure with no caller left to receive it is neither logged nor dropped.
Examples are a finalizer that refuses, or a retirement that fails after the
code that asked for it has moved on. It becomes one typed record in the Host's
bounded diagnostic journal, and the application drains the journal when it
chooses:

- Rust: `Host::take_failures`
- TypeScript: `host.takeFailures()`
- Python: `host.take_failures()`
- Racket: `host-take-failures!`

A full journal drops its oldest record and counts the loss, so a drained set
never looks like a complete history. A failure that a call returns, or that a
close reports, never appears in the journal as well.

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

## Loam resources

Rust's optional `loam` feature projects the first persistent-resource lifecycle
through `libglowcap_loam` and its LMDB companion. It shares the existing Host
and capability owners. Zig owns policy, transaction installation and recovery;
the binding owns callbacks and retired storage jobs. See the
[lifecycle guide](../docs/loam/c-and-rust.md) for the
implemented scope and evidence. Compiled for `wasm32-unknown-unknown`, the same
feature stores to IndexedDB, as the [browser guide](../docs/loam/browser.md)
describes. TypeScript, Python, and Racket have no Loam projection.
