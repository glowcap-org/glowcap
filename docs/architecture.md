# pancake Architecture

pancake is a library-shaped OCapN / CapTP core. It is designed so protocol
correctness, wire compatibility, ownership, allocation, and host integration
costs are visible in the API that creates them.

## Founding Thesis

```text
protocol semantics: fixed, correct, interoperable
implementation overhead: aggressively minimized
```

Performance is part of the correctness contract. Every allocation and every copy
on the wire path is either forbidden, intentional, or measured.

Project setup follows the same contract: build steps should be obvious,
examples should compile, public artifacts should be named for `pancake`, and no
tooling layer should hide ownership, allocation, I/O, scheduling, or authority.

## Protocol Oracle, Zig Shape

OCapN behavior, Spritely Goblins wire fixtures, and pancake's checked protocol
scenarios are the conformance gates. Zig expresses those boundaries directly;
Rust dogfood is consumer proof for the C ABI, not the semantic authority.

Core invariants:

- Codec-neutral semantics.
- Authoritative session state.
- A sync, no-I/O canonical runtime.
- Explicit frame ownership and borrowed message views.
- C ABI ownership promises.
- Conformance fixtures and scenario traces as release gates.
- Dogfooding before compatibility claims.

The Zig repo keeps a local oracle bridge under `test/oracle/` and
`test/oracles/`. It enumerates the shipped message model, embeds the Goblins
Syrup fixture corpus, and defines the session-trace shape used by runtime
scenario tests.

Out of the core:

- runtime-specific I/O structure;
- package-manager-shaped topology;
- wrapper layers that hide ownership, allocation, or authority decisions.

## Core Boundary

The canonical core owns protocol semantics and nothing else:

- no sockets;
- no `std.Io`;
- no background tasks;
- no hidden scheduler;
- no process-level runtime object.

Adapters feed inbound frames, call `Peer.step`, drain outbound frames, and poll
events. Adapters may use `std.Io`, native transports, or host callbacks, but
they do not add CapTP behavior.

## Memory Contract

`Frame` owns wire bytes. `FrameView` borrows wire bytes for a bounded call scope.
Default frame movement is either ownership transfer (`Frame`) or bounded borrow
(`FrameView`). Session state must not retain borrowed wire memory.

The correct decode split is:

- `decodeView`: project a borrowed semantic view over frame bytes;
- `decodeOwned`: materialize an owned semantic value only when persistence,
  tests, debugging, or cross-boundary ownership require it.

`FrameShape` distinguishes byte storage from word-aligned storage (the `word`
shape is 8-byte-aligned storage with a byte length divisible by 8). Syrup is
byte-framed; Cap'n Proto is word-framed. A codec-neutral core keeps that shape
distinction explicit at the frame boundary instead of flattening every frame to
generic bytes.

## Copy Budget

Copies must be named at the boundary where they occur. They are not the default
frame movement model:

- `Frame.initOwned` adopts an already-owned allocation without copying. Callers
  pass the allocation alignment explicitly so `Frame.deinit` frees with the same
  metadata used to allocate.
- `Frame.initExternal` adopts externally managed storage without copying and
  invokes the supplied release hook on `Frame.deinit`.
- `test/support/frame.zig` may copy caller bytes into frame-owned allocations
  for tests and fixtures. Production `Frame` has no copy constructor.
- `Frame.view` must not allocate or copy.
- `Peer.sendCopying` names its queueing cost at the API boundary.
- `Peer.recvBorrowed` retains the transient borrowed wire bytes with a single
  named copy; `Peer.feedInbound` / `Peer.step` move an already-owned frame into
  the surfaced event with zero copies.
- A surfaced `Event` retains the originating frame in the negotiated codec.
  `Event.view` projects it without allocating; `Event.decodeOwned` materializes
  an owned model only on demand. The C ABI returns those exact bytes without
  decoding and re-encoding, so the event surface stays codec-neutral.
- `MemoryEndpoint.writeFrameOwned` transfers an owned `Frame` into the endpoint
  without copying.
- `test/support/memory_endpoint.zig` may inject a borrowed-copy frame into a
  `MemoryEndpoint` for tests. Production `MemoryEndpoint` has no borrowed-copy
  writer.

The target shape is explicit: inbound C ABI borrowed frames dispatch
synchronously, inbound C ABI managed frames transfer into a peer-owned queued
frame without copying, runtime-owned frames move by transfer, events return the
originating frame in the negotiated codec without re-encoding, and outbound C ABI
returns a managed frame with a release callback. Zig must preserve that contract
and make accidental copies harder to write.

## C ABI Contract

The C ABI stays boring:

- opaque handles;
- fixed-width integer discriminants;
- `ptr + len` byte views;
- explicit release functions;
- callbacks with caller context;
- clear return codes.

Public artifacts are named for the project: `libpancake.a`, `libpancake.so`,
and `pancake.h`.

Zig slices, allocators, error unions, futures, and `std.Io` objects do not cross
the C ABI.

## Examples As Contract

Examples are not snippets. They are build targets:

- `examples/zig/frame_view.zig` proves the Zig library surface can express owned
  frame transfer and borrowed views directly.
- `examples/c/frame_view.c` proves `pancake.h` is ordinary C ABI vocabulary and
  links an exported symbol from `libpancake`.

`zig build check` runs both examples.

