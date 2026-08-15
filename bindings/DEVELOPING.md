# Developing a binding

This page is for maintainers of the Rust, TypeScript, Python, and Racket
bindings. Application authors should start with the
[binding overview](README.md).

The Host and driver are separate, symbol-disjoint archives. Every native
binding loads `libpancake_host` for the `pancake_host_*` family and
`libpancake_driver` for the `pancake_driver_*` family. The driver adopts a
quiescent Host; it neither re-exports nor duplicates Host state. Transport
archives contribute packages through `pancake_driver_add_provider`: the TCP
archive's one package owns `tcp`, `keyed-tcp`, and `noise-tcp`, while the iroh
package owns both dial and listener execution. Bindings load and register a
package; they do not mirror its profiles, implementation tables, socket
choreography, or callback lifetime.

Python, Rust, TypeScript, and Racket use that driver path for native TCP and
iroh. The binding parks on the driver's one readiness descriptor, steps, and
drains one event queue. The byte-fed Host remains the deliberate path for wasm
and for channels an embedder explicitly supplies, including the current
keyed-relay bridge. TypeScript has one runtime constraint: parking is an
off-thread `poll(2)`, so Bun and the wasm adapter keep the byte-fed path.
Racket steps with zero timeout on its place's OS thread and parks through
`unsafe-file-descriptor->semaphore`, with the reentrant Host lock serializing
verbs against the park thread.

## The host loop

After a top-level `pancake_host_*` call succeeds, drain the work it created.
On the byte-fed path, Rust, Python, and Racket use `pancake_host_pump_drain`
with synchronous park-only hooks. TypeScript uses the normative
`pancake_host_next_action` pull queue because browser Wasm has no general
C-callback seam. On a loop-owned host, `pancake_host_pump_drain` never runs:
`pancake_driver_step` executes transport-shaped actions itself and forwards
the application-visible ones as loop events, so the binding's drain there is
one step plus the event queue. The byte-fed drain can request:

- `DIAL`: open a connection and report success or failure with its ticket;
- `FLUSH`: take outbound frames and write them;
- `NEED_GIFT_ID`: provide 32 random bytes, or report that entropy failed;
- `SETTLE` or `FAIL`: resolve the language promise named by the ticket.

A pump hook returning non-OK is a transactional refusal: it must have committed
no external effect, and the same action remains first for the next drain call.
Once a hook copies, parks, or otherwise takes responsibility for an action, it
returns OK even when the asynchronous work it scheduled may later fail.

Ignoring an action can strand a call or handoff. Every action therefore has a
terminal path: `DIAL` reports success/failure, and `NEED_GIFT_ID` reports
provided/failed. The shared Zig helper
`embedder_pump`, the generated action inventory, and the C pull queue keep this
loop from drifting across runtimes.

The same commit discipline governs work created by a language finalizer or a
detached progress task. Finalizers only park opaque Host IDs; they never call
the C ABI. The pumping thread calls `pancake_host_ref_release`, removes a token
only after PANCAKE_OK, and leaves the refused token and unattempted tail owned
for retry. A scheduled drain has no immediate caller, so the Host wrapper
retains its exact typed failure and surfaces it at the next verb head. Bindings
do not classify failures or invent release semantics: the C ABI guarantees
that non-OK committed no release, and the core remains the authority for what
the release means.

Inbound byte streams go through `pancake_host_session_feed_bytes`. The host
unwraps canonical Syrup byte strings, retains a split prefix or body, and
applies the declared-body limit. A binding should not add another scanner or
tail buffer. `PANCAKE_ERR_WOULD_BLOCK` from `feed_bytes` is outbound
backpressure, not a protocol refusal: drain actions / outbound frames and retry
the same byte chunk. On output, prefix each bare `take_outbound` frame with its
decimal byte length and `:`; write the prefix and frame separately.

When a feed fails, read the typed abort, drain again so the abort is written,
then surface the error. On EOF, call
`pancake_host_session_break_far_vows` before releasing the session so pending
calls fail instead of hanging.

## Shared module structure

Each binding separates the synchronous C callback path from work that may
await:

- the **pump module** owns the handshake, feed, flush, serve loop, and
  `last_abort`;
- the **action module** decodes host actions and parks any I/O until after the
  C call returns;
- `promise` owns remote promises, projections, fetch, enlivenment, `promiseFor`,
  and the far-send helpers such as `sendFar`;
- `gc` parks finalizer releases for the pumping thread;
- `dial` handles ordinary and handoff redemption dials;
- `listen` owns servers and accepted sessions;
- the **trampoline** module runs hosted behaviors, follows local forwards, and
  provides caretaker/attenuate and spawn/publish;
- Rust's `session_shared` holds state shared by its session handles.

The files use each language's naming conventions, but this division is the
same in all four bindings. The embedder-spine module split is complete.
`zig build source-check` rejects a missing module, a direct action-pop loop, or a
binding that bypasses the generated action decoder.

### TypeScript package surface

Each `@pancake/*` directory under `bindings/ts/` is a publishable package.
Its root is the ship surface: source that a consumer imports. Tests, harnesses,
smokes, benches, and probes live under that package's `test/` directory (or
under the workspace-level `dogfood/`), never beside `mod.ts`. Every package
`deno.json` names `test/**` in `publish.exclude`, so a broad `**/*.ts` include
cannot ship them. `zig build source-check` refuses `*_test.ts`, `*_smoke.ts`,
`*_bench.ts`, `*_probe.ts`, and `*_harness.ts` outside `test/` in a package,
and a publish block that includes TypeScript without excluding `test/**`.

Host action tags and layouts are generated from one Zig table. Callback bodies
remain handwritten because they cross into language-specific I/O.

## Callback rules

Hosted behaviors run on the pumping thread inside the current host call. They
may queue sends, tells, vow operations, garbage-collection releases, and
exporter locations. They may not recursively drive the host by feeding bytes,
taking outbound frames, opening sessions, publishing, fetching, or releasing
the current session.

A behavior that closes its own session must park the release until the callback
returns. A reachable Host stays on its owning thread. Once a language finalizer
has exclusive terminal ownership, `pancake_host_release` may run on that
finalizer thread; it cannot race a Host call or leave a live verb to migrate.

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
block; Python and Racket check the moment the module is imported. A mirror that
declares no such check fails `zig build source-check`, so every mirror is
covered.

A C layout change must update every hand-written mirror in the same change.

## iroh

iroh is a separate optional library, `libpancake_net_transport_iroh`. On the
loop tier a binding loads `libpancake_driver`, registers the archive-owned
provider package, and parks on the loop's one aggregate readiness descriptor;
the native archive drains the sidecar. On the byte-fed
path that still serves iroh listen and the named loop exceptions, the library
exposes a readiness file descriptor and non-blocking accept, connect, read,
and write calls, and each runtime waits on that descriptor in its native way:

| Binding | Wait mechanism (byte-fed iroh path) |
| --- | --- |
| TypeScript | a `node:net` socket around a duplicated descriptor |
| Python | `asyncio.add_reader` |
| Rust | Tokio `AsyncFd` |
| Racket | `unsafe-file-descriptor->semaphore` |

There is no polling thread. A hint-less handoff uses the host's configured iroh
reachability policy; direct-address hints use a direct dial. Keep the exporter
session pumping after a redemption because withdrawal and settlement continue
on that connection.

WebRTC's optional companion follows the same fd discipline after a peer is
created: one endpoint fd reports stable peer-id open, candidate, readable,
writable, and closed events, and try-I/O never parks the runtime. Unlike iroh,
peer creation and signaling submissions are synchronous control operations and a
bare locator has no authority to perform them. Native bindings currently expose
the raw family only in Rust, Python, and Racket. TypeScript uses
`RTCPeerConnection` directly and does not load the native companion; its browser
package owns the application-level adapter.

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
