# Developing a binding

This page is for maintainers of the Rust, TypeScript, Python, and Racket
bindings. Application authors should start with the
[binding overview](README.md).

Every binding drives `libpancake_host`, the byte-fed multi-session host. The C
library owns CapTP state, promises, routing, and handoff. The binding owns its
runtime's sockets, tasks, and scheduling.

## The host loop

After a top-level `pancake_host_*` call succeeds, drain the work it created
with `pancake_host_pump_drain`. The drain can request:

- `DIAL`: open a connection and report success or failure with its ticket;
- `FLUSH`: take outbound frames and write them;
- `NEED_GIFT_ID`: provide 32 random bytes;
- `SETTLE` or `FAIL`: resolve the language promise named by the ticket.

Ignoring an action can strand a call or handoff. The shared Zig helper
`embedder_pump` and the C function `pancake_host_pump_drain` keep this loop in
one place.

Inbound bytes go through `pancake_host_session_feed_bytes`. The host finds frame
boundaries, retains a partial tail, and applies the frame limit. A binding
should not add another scanner or tail buffer.

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
`zig build meta-check` rejects a missing module, a direct action-pop loop, or a
binding that bypasses the generated action decoder.

Host action tags and layouts are generated from one Zig table. Callback bodies
remain handwritten because they cross into language-specific I/O.

## Callback rules

Hosted behaviors run on the pumping thread inside the current host call. They
may queue sends, tells, vow operations, garbage-collection releases, and
exporter locations. They may not recursively drive the host by feeding bytes,
taking outbound frames, opening sessions, publishing, fetching, or releasing
the current session.

A behavior that closes its own session must park the release until the callback
returns. Language finalizers follow the same rule: they record a token, and the
next pump performs the C call on the owning thread.

Every vow-producing function returns its vow ID. Insert that ID into the
binding's promise table immediately. Its result later arrives as a `SETTLE` or
`FAIL` action, so there is no separate listener registration.

## Structs and generated functions

TypeScript's ABI constants, layouts, and function tables are generated. Rust,
Python, and Racket generate their function bindings but keep some struct
declarations by hand. Those declarations are checked against documented sizes
and offsets at compile time or import time.

A C layout change must update every hand-written mirror in the same change.

## iroh

iroh is a separate optional library,
`libpancake_net_transport_iroh`. It exposes a readiness file descriptor and
non-blocking accept, connect, read, and write calls. Each runtime waits on that
descriptor in its native way:

| Binding | Wait mechanism |
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
