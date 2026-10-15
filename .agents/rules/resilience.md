---
description: "Resilience posture for untrusted inbound bytes and layer ownership."
globs: src/ocapn/codec/**/*.zig, src/ocapn/engine/**/*.zig, src/ocapn/session/**/*.zig, src/net/**/*.zig, src/c_abi/**/*.zig
paths:
  - "src/ocapn/codec/**/*.zig"
  - "src/ocapn/engine/**/*.zig"
  - "src/ocapn/session/**/*.zig"
  - "src/net/**/*.zig"
  - "src/c_abi/**/*.zig"
---

# glowcap — Resilience

Every inbound frame is untrusted until codec and session validation
complete.

## Layer Ownership

- Frame size caps belong at netlayer/adapter boundaries.
- Length arithmetic belongs where bytes are parsed, and it uses checked
  arithmetic.
- Codec parse limits belong in codecs.
- Session validity belongs in session.
- Decode and session failures project through engine events and abort behavior.
- A wire-fatal refusal retires that session into one explicit terminal state
  and never terminates the embedding process. All owned waiters settle from the
  same first cause before the failure returns across a public close barrier.
- Application rate limits, authorization, and deadlines belong above glowcap.

A concern not listed goes to the layer that owns the decision (the
[architecture rule](architecture.md)'s Layer Ownership list is the map), not the
layer where the symptom appeared.

## Anti-Patterns

- Allocating from an unbounded length prefix.
- Caching borrowed wire bytes in session state.
- Returning a generic "internal" error for a known malformed frame shape.
- Letting adapters invent protocol semantics.
- Reusing a peer after fatal wire refusal without an explicit recovery contract.
- Swallowing a cleanup or detached-task failure because the immediate caller
  is gone.
- Returning an error while the object it condemned is still ambiguously live.
- Treating peer input, I/O, resource pressure, or a callback refusal as a
  process-fatal condition.

Fail closed, surface typed reasons, and keep policy at the layer that owns it.
