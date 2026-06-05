---
description: "Zig pancake architecture guardrails: codec-neutral model, authoritative session, sync no-I/O core."
globs: src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h, build.zig, README.md, docs/**/*.md, AGENTS.md
---

# pancake — Architecture Guardrails

## Protocol Authority

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. Rust pancake is implementation history to mine and a
C ABI dogfood consumer, not the oracle for Zig semantics.

Committed files should not mention external taste-reference names from prompts.
Encode that taste as Zig-native control, explicit protocol vocabulary, honest
allocation and lifetime surfaces, polished boundaries, and tests that prove
architectural claims.

## Runtime Shape

```text
Frame -> Codec view -> Session state -> Outgoing Message -> Codec -> Frame
```

Session state owns authority. Codecs parse/render bytes; they do not decide
whether references, answers, exports, imports, or releases are valid.

## Core Boundary

The portable core stays deterministic, sync, and no-I/O:

- no sockets;
- no hidden scheduler;
- no background tasks;
- no `std.Io` in core protocol modules;
- no adapter policy inside codecs/session/runtime.

Adapters may use `std.Io`, transports, callbacks, and host scheduling. They do
not add CapTP semantics that the core lacks.

## Layer Ownership

- `foundation`: bytes, IDs, frame ownership.
- `model`: codec-neutral semantic types.
- `codec`: encode/decode and borrowed semantic views.
- `session`: validation and authoritative tables.
- `runtime`: caller-owned `Peer`, `step`, inbound dispatch, outbound drain.
- `c_abi`: C-shaped vocabulary only.
- `io_adapter`: runtime-flavored I/O glue only.

If a change moves authority downward into codec/adapter code, stop and redesign.
