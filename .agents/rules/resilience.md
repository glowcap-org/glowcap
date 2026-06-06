---
description: "Zig pancake resilience posture for attacker-controlled bytes and layer ownership."
globs: src/codec/**/*.zig, src/engine/**/*.zig, src/session/**/*.zig, src/c_abi/**/*.zig, test/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
---

# pancake — Resilience

Every inbound frame is attacker-controlled until codec and session validation
complete.

## Layer Ownership

- Frame size caps belong at netlayer/adapter boundaries.
- Length arithmetic belongs where bytes are parsed; use checked arithmetic.
- Codec parse limits belong in codecs.
- Session validity belongs in session.
- Decode/session failures project through engine events and abort behavior.
- Application rate limits, authorization, and deadlines belong above pancake.

Concern not listed? Do layer analysis before patching.

## Anti-Patterns

- allocating from an unbounded length prefix;
- caching borrowed wire bytes in session state;
- returning a generic "internal" error for a known malformed frame shape;
- letting adapters invent protocol semantics;
- reusing a peer after fatal wire refusal without an explicit recovery contract.

Fail closed, surface typed reasons, and keep policy at the layer that owns it.
