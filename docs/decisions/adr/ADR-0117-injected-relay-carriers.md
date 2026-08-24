---
id: ADR-0117
status: accepted
date: 2026-08-17
tags: [relay, transport, websocket, tls, c-abi, bindings, browser]
decision: "Every relay initializer selects an owned WebSocket carrier. Native Zig composes TCP, an injectable TLS stream engine, and a shared WebSocket client; managed runtimes use their own WebSocket connector without callbacks from the native driver."
supersedes: []
superseded_by: []
amends: [ADR-0086, ADR-0107, ADR-0112]
amended_by: []
---

# ADR-0117 Relay initializers select an owned carrier

## Context

The relay has three existing execution forms. A blocking resident opens a
WebSocket through Zig sockets, the completion backend drives many relay sockets
through platform operations, and a browser or another runtime that owns I/O
opens its WebSocket and feeds the byte-owned Host. All three carry the same
`keyed-relay` and `noise-relay` profiles, but their initialization and failure
contracts are expressed separately.

A public browser deployment normally requires WSS. Zig's standard TLS client
does not expose the resumable connection state needed by Pancake's shared
readiness loop. A thread per connection would avoid that API mismatch but would
make the project's session-scale target pay one stack and scheduler participant
per relay connection. Rust, Python, Racket, Deno, and browsers already have
environment-owned WebSocket integrations, but choosing one of those must not
move relay routing, CapTP, Noise, or lifecycle policy into a binding.

This engages the replaceable-edges, one-authority, and visible-cost principles.
The architecture needs one named edge between relay semantics and the
environment that moves its bytes.

## Decision

Every relay initializer retains one **carrier runtime**. It opens many validated
`ws` or `wss` requests, and every successful open transfers one bounded binary
channel lease. The carrier owns channel readiness, backpressure, cancellation,
and close barriers. The relay owns route and
rendezvous semantics, profile selection, admission, configuration equivalence,
lifecycle identity, and projection of carrier failures. The Host above it
remains the owner of CapTP and of the end-to-end Noise channel.

The carrier is selected at initialization rather than through process-global
state. The relay retains it before admitting work and releases it only after
all open attempts and channels have reached their terminal barriers. A failed
initialization leaves the carrier with its caller. A failed open settles its
one dial or listener operation. A failure after admission settles the owning
connection or listener. Cleanup consequences attach to that primary failure;
only failures with no surviving return recipient enter ADR-0115's diagnostic
waist. A carrier observer can report but cannot alter an operation's result.

There are three physical projections of this one semantic contract:

1. A pollable native carrier supplies the blocking resident and the generic C
   driver's multiplexed relay runtime.
2. A completion-native carrier supplies platform operations and buffers to the
   completion loop used by the native scale path.
3. A managed carrier runs in the runtime that owns its event loop. Browser,
   Deno, Python, Rust, and Racket adapters may use their environment's
   WebSocket implementation and feed the byte-owned Host. They implement the
   carrier contract as a connector; the native driver never calls back into a
   JavaScript isolate, Python interpreter, Racket runtime, or foreign async
   executor.

The two native projections share protocol state and failure vocabulary, not a
blocking read and write interface. The resident drives that state with pollable
sockets; the completion backend drives it with platform operations. Managed
language objects stay on their runtime side of the byte-fed Host seam. The
public initializers use the same concepts and defaults without pretending these
three projections have one physical callback ABI.

Native transport composition has two replaceable edges below the relay. TCP is
one raw byte transport and never gains a plain-or-secure mode. A generic TLS
stream transform wraps an underlying byte transport and accepts an injected TLS
engine. A generic WebSocket client then runs over the plain or secured stream.
The native relay carrier composes them as follows:

```text
ws  = TCP + WebSocket
wss = TCP + TLS(engine) + WebSocket
```

Pancake's default native TLS engine uses a pinned Mbed TLS release compiled by
Zig and driven through nonblocking BIO callbacks. Zig owns sockets, scheduling,
cancellation, and failure projection. Mbed TLS is private to the optional
native TLS transform rather than to TCP, the relay, or the C archive.

The built-in native carrier supports both schemes and selects the stream stack
for each validated open request. A locator route may therefore select `wss`
when the provider's deployment fallback uses `ws`, or the reverse. Carrier
backend names do not enter public configuration or configuration equivalence.

Trust is process-owner policy carried by native relay configuration. The native
secure carrier verifies the URL hostname, supplies SNI, uses system roots by
default, and accepts copied PEM roots for controlled deployments and tests. A
filesystem path or live root reload is not an initializer authority: a process
owner may read a file and supply its immutable bytes. The carrier provides no
verification-disable or WSS-to-WS fallback. Browser and managed carriers use
their runtime's trust machinery and cannot weaken the Host's end-to-end Noise
policy.

## Scope (what this does not decide)

This decision does not make TLS an OCapN or Noise requirement. TLS protects the
WebSocket carrier and its routing metadata; `noise-relay` still supplies the
peer-to-peer authenticated channel.

This decision does not require every binding to ship a second managed relay
implementation. The native provider is the default for native bindings. A
managed carrier is supported where the environment owns I/O or where an
optional runtime integration has recurring evidence.

This decision does not standardize an application WebSocket server or proxy
policy. Origin checks, relay admission, outbound proxy selection, and target
allow-lists remain with the process owner.

## Alternatives Considered

- **Use one blocking worker per native WSS connection**: rejected because its
  stack and scheduler costs scale with connection count, and a split reader and
  writer cannot assume concurrent mutation of one TLS state is safe.
- **Put TLS inside the TCP transport**: rejected because it would make TCP a
  mode-switched type, attach certificate policy to raw sockets, and prevent the
  secure stream from being reused independently.
- **Put Mbed TLS directly in the C relay archive**: rejected because native Zig
  and the C projection must consume one Zig-owned transport implementation.
- **Make every binding use its runtime's TLS and WebSocket libraries**:
  rejected because this would duplicate native behavior and make the bindings
  transport authorities rather than consumers of the C ABI.
- **Pass every managed runtime through one C callback table**: rejected because
  interpreter affinity, reentrancy, wakeups, and shutdown are runtime-owned
  facts that a native driver callback cannot safely erase.
- **Keep native and managed relay initialization unrelated**: rejected because
  route validation, bounds, lifecycle, and failure semantics would continue to
  drift across surfaces.

## Consequences

The native net layer gains a reusable TLS stream transform with an injectable
engine and a reusable WebSocket client state machine. The Zig relay gains a
carrier opener beneath its resident and completion execution forms. Its clear
and secure carriers compose those lower layers rather than owning parallel
WebSocket or TLS implementations.

Mbed TLS is pinned, built, licensed, namespaced, and linked only when the
optional native secure carrier is composed. Native Zig and
`libpancake_relay` consume the same module.

The C relay configuration gains a size/version prefix, trust policy, and
effective carrier bounds with copied initialization data and generated binding
mirrors. It constructs the built-in native carrier and gains no carrier
callback table. Bindings project the declarative configuration idiomatically.
They do not parse certificates, resolve DNS, classify TLS errors, or retain
another provider registry. Managed connector packages adapt their runtime
WebSocket to the same observable contract and retain their own event-loop
affinity.

The native secure carrier owns one shared trust configuration per relay
runtime and bounded state per connection. The build records shared and
per-connection footprints, handshake allocations, cancellation latency, and
steady-state copies. No carrier may add an unbounded queue or a per-connection
thread.

## Evidence and check

In-tree evidence is one compositional matrix, not one test implementation
forced across incompatible execution owners. A binding-neutral corpus owns
route policy; shared Zig TLS and WebSocket scenarios own native wire semantics;
pollable, completion, and each managed runtime test their real scheduling,
cancellation, backpressure, and close barriers. C failure injection owns the
fixed projection, and thin binding tests prove that record decodes unchanged.
Together the matrix covers dial and registration, partial I/O, backpressure,
cancellation at every acquisition phase, clean and truncated close, exact
primary and cleanup failures, configuration equivalence, and allocation
injection before and after admission. The direct-C provider scenario sends ping
and binary data in one carrier write, then proves the pong control wake,
buffered-data READABLE republication, payload drain without another POLLIN
edge, and close response. This split follows one-authority DRY: duplicating the
semantic oracle in every binding would create drift, while
sharing an interpreter-shaped harness would erase the lifetimes being tested.

Evidence for this decision is complete only when native execution runs on Linux
and macOS release targets, verifies DNS, SNI, hostname and CA refusal, and
records memory budgets. Binding checks must prove the generated C configuration
and the same observable failure vocabulary. A real browser must register over
WSS and complete a native `noise-relay` call while a relay observer sees no
CapTP plaintext. In-tree mechanics belong to `zig build check`; platform,
binding, and browser execution belong to separately named recurring checks for
the environments they require.

## Forward compatibility

Another native TLS engine can implement the secure-stream contract, and another
runtime-native connector can implement the carrier contract, without changing
relay locators, CapTP profiles, or binding application APIs. Adding one expands
the evidence matrix; it does not add backend policy to TCP or the relay.
