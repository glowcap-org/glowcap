---
type: static
description: How the Rust, TypeScript, Python and Racket bindings load the Host and driver archives, for binding maintainers.
sources:
  - resource: /bindings/
  - resource: /src/c_abi/
  - resource: /tools/c-abi/
---

# Developing a binding

Application authors should start with the [binding overview](README.md).

The Host and driver are separate, symbol-disjoint archives. Every binding that
loads the C libraries loads `libglowcap_host` for the `glowcap_host_*` family
and `libglowcap_driver` for the `glowcap_driver_*` family. The driver adopts a
quiescent Host and neither re-exports nor duplicates Host state. Transport
archives contribute packages through `glowcap_driver_add_provider`: the TCP
archive's one package owns `noise-tcp`, `keyed-tcp`, and testing `tcp`, and the
iroh package owns both dial and listener execution. A binding loads and
registers a package and mirrors none of its profiles, implementation tables,
socket choreography, or callback lifetime.

Python, Rust, TypeScript, and Racket use that driver path for TCP and
iroh. The binding parks on the driver's one readiness descriptor, steps, and
drains one event queue. The byte-fed Host is the path for wasm and for channels
an embedder supplies, including the keyed-relay bridge. TypeScript has one
runtime constraint: parking is an off-thread `poll(2)`, so Bun and the wasm
adapter keep the byte-fed path. Racket steps with zero timeout on its place's OS
thread and parks through `unsafe-file-descriptor->semaphore`, with the reentrant
Host lock serializing verbs against the park thread.

## The host loop

After a top-level `glowcap_host_*` call succeeds, drain the work it created.
On the byte-fed path, Rust, Python, and Racket use `glowcap_host_pump_drain`
with synchronous park-only hooks. TypeScript uses the
`glowcap_host_next_action` pull queue because browser Wasm has no general
C callbacks. On a loop-owned host, `glowcap_host_pump_drain` never runs:
`glowcap_driver_step` executes transport-shaped actions itself and forwards
the application-visible ones as loop events, so the binding's drain there is
one step plus the event queue. The byte-fed drain can request:

- `DIAL`: open a connection and report success or failure with its ticket.
- `FLUSH`: take outbound frames and write them.
- `NEED_GIFT_ID`: provide 32 random bytes, or report that entropy failed.
- `SETTLE` or `FAIL`: resolve the language promise named by the ticket.
- `CLOSE`: write any queued last frame, close the session's transport, and
  release the session.
- `RESUME`: keep draining, because the Host yielded with work left.
- `CANCEL_DIAL`: interrupt and join the dial named by the ticket, then report
  that it was cancelled.

A pump hook returning non-OK is a transactional refusal: it must have committed
no external effect, and the same action remains first for the next drain call.
Once a hook copies, parks, or otherwise takes responsibility for an action, it
returns OK even when the asynchronous work it scheduled may later fail.

Ignoring an action can strand a call or handoff, so every action has a
terminal path: `DIAL` reports success or failure, and `NEED_GIFT_ID` reports
provided or failed. The shared Zig helper `embedder_pump`, the generated action
inventory, and the C pull queue keep this loop the same across runtimes.

The same commit rule covers work created by a language finalizer or a detached
progress task:

- Capability-GC finalizers only park opaque Host ref IDs. They never call the C
  ABI.
- The pumping thread calls `glowcap_host_ref_release`, removes a token only
  after `GLOWCAP_OK`, and keeps the refused token and the unattempted tail for
  retry.
- A scheduled drain has no immediate caller, so the Host wrapper retains its
  exact failure and reports it at the next verb head or terminal close barrier.
- Bindings do not classify release failures or define release semantics. The C
  ABI guarantees that a non-OK release committed nothing, and the core defines
  what a release means.

Inbound byte streams go through `glowcap_host_session_feed_bytes`. The host
unwraps canonical Syrup byte strings, retains a split prefix or body, and
applies the declared-body limit. A binding should not add another scanner or
tail buffer. `GLOWCAP_ERR_WOULD_BLOCK` from `feed_bytes` is outbound
backpressure, not a protocol refusal: drain actions, wait until the session's
writer has written the frames queued so far, then retry the same byte chunk. On
output, prefix each bare `take_outbound` frame with its decimal byte length and
`:`. Write the prefix and frame separately.

Reading and writing are separate tasks. `FLUSH` and `CLOSE` wake the session's
one writer, which takes and writes the frames, and the action drain never waits
on that write. A reader that waits on its own write stops reading whenever the
transport's buffer is full, and two peers doing that over one bounded channel
each wait for the other to read. The feed refusal above already bounds each
session's outbound queue, so the reader needs no second bound.

While closing locally, observe `glowcap_host_session_lifecycle_state` before
feeding. `TERMINATING` or `CLOSED` already refuses ingress. `FINISHING` still
admits input, so its failures remain new terminal causes.

For a new failure, retain its typed refusal before looking up diagnostics or
draining the abort. Those effects can themselves fail or retire the session.
Retain their failures as consequences and preserve the original cause for all
terminal observers. On EOF, call
`glowcap_host_session_transport_closed` before releasing the session so the
core retires the connection and settles pending calls.

## Shared module structure

Each binding separates the synchronous C callback path from work that may
await:

- the **pump module** owns the handshake, feed, flush, serve loop, and
  `last_abort`
- the **action module** decodes host actions and parks any I/O until after the
  C call returns
- `promise` owns remote promises, projections, fetch, enlivenment, `promiseFor`,
  and the far-send helpers such as `sendFar`
- `gc` parks finalizer releases for the pumping thread
- `dial` handles ordinary and handoff redemption dials
- `listen` owns servers and accepted sessions
- the **trampoline** module runs hosted behaviors, follows local forwards, and
  provides caretaker/attenuate and spawn/publish
- Rust's `session_shared` holds state shared by its session handles

The files follow each language's naming conventions, and the division is the
same in all four bindings. `zig build source-check` rejects a missing module, a direct action-pop loop, or
a binding that bypasses the generated action decoder.

### TypeScript package surface

Each `@glowcap/*` directory under `bindings/ts/` is a publishable package.
Its root is the ship surface: source that a consumer imports. Tests, harnesses,
smokes, benches, and probes live under that package's `test/` directory (or
under the workspace-level `dogfood/`), not beside `mod.ts`. Every package
`deno.json` names `test/**` in `publish.exclude`, so a broad `**/*.ts` include
cannot ship them. `zig build source-check` refuses `*_test.ts`, `*_smoke.ts`,
`*_bench.ts`, `*_probe.ts`, and `*_harness.ts` outside `test/` in a package,
and a publish block that includes TypeScript without excluding `test/**`.

Host action tags and layouts are generated from one Zig table. Callback bodies
are handwritten because they cross into language-specific I/O.

## Callback rules

Hosted behaviors run on the pumping thread inside the current host call. They
may queue sends, tells, vow operations, garbage-collection releases, and
exporter locations. They may not recursively drive the host by feeding bytes,
taking outbound frames, opening sessions, publishing, fetching, or releasing
the current session.

- A behavior that closes its own session parks the release until the callback
  returns.
- A reachable Host stays on its owning thread. Once a language finalizer has
  exclusive terminal ownership, `glowcap_host_release` may run on that
  finalizer thread, because it cannot race a Host call or leave a live verb to
  migrate.
- Terminal Host and driver release differ from capability-GC release. Only a
  pre-consumption refusal keeps the C handle live for retry. Every
  teardown outcome consumes it and leaves any failure at the terminal close or
  diagnostic owner.

Every vow-producing function returns its vow ID. Insert that ID into the
binding's promise table immediately. Its result later arrives as a `SETTLE` or
`FAIL` action, so there is no separate listener registration.

## Structs and generated functions

TypeScript's ABI constants, layouts, and function tables are generated. Rust,
Python, and Racket generate their function bindings but keep some struct
declarations by hand. Every one of those declarations is checked against the
whole shape of the C struct it mirrors: its size, and each field's name, offset,
and width, reflected off the real Zig types by
`zig build gen-binding-ffi-layouts`. Rust checks at compile time in a `const`
block. Python and Racket check the moment the module is imported. A mirror that
declares no such check fails `zig build source-check`, so every mirror is
covered.

A C layout change must update every hand-written mirror in the same change.

## iroh

iroh is a separate optional library, `libglowcap_net_transport_iroh`. On the
loop tier a binding loads `libglowcap_driver`, registers the archive-owned
provider package, and parks on the loop's one aggregate readiness descriptor.
The archive drains the provider. On the byte-fed path that serves iroh listen
and the named loop exceptions, the library exposes a readiness file descriptor
and non-blocking accept, connect, read, and write calls. Each runtime waits on
that descriptor in its own way, with no polling thread:

| Binding | Wait mechanism (byte-fed iroh path) |
| --- | --- |
| TypeScript | a `node:net` socket around a duplicated descriptor |
| Python | `asyncio.add_reader` |
| Rust | Tokio `AsyncFd` |
| Racket | `unsafe-file-descriptor->semaphore` |

A hint-less handoff uses the host's configured iroh
reachability policy. Direct-address hints use a direct dial. Keep the exporter
session pumping after a redemption because withdrawal and settlement continue
on that connection.

WebRTC's optional companion follows the same descriptor rules after a peer is
created: one endpoint fd reports stable peer-id open, candidate, readable,
writable, and closed events, and try-I/O never parks the runtime. Unlike iroh,
peer creation and signaling submissions are synchronous control operations, and
a bare locator has no authority to perform them. Every server binding dials
through `webrtc.provider(signaling)`, which hands the library the signaling
callbacks and lets the driver run the exchange. Rust also listens through
`webrtc::listen` with the same callbacks. Rust, Python, and Racket also
expose the raw family. The Deno entry loads the library for that dial only, and
the browser package uses `RTCPeerConnection` directly and never loads it.

## Checks

```sh
zig build bindings
zig build bindings-goblins-interop
zig build bindings-goblins-handoff
zig build bindings-goblins-gift
zig build bindings-iroh-loop
```

[`examples/c/host_embedder_pump.c`](../examples/c/host_embedder_pump.c) is the
small compiled reference for feed, drain, refusal, and EOF.
