---
description: "Zig pancake resilience posture for attacker-controlled bytes and layer ownership."
globs: src/ocapn/codec/**/*.zig, src/ocapn/engine/**/*.zig, src/ocapn/session/**/*.zig, src/net_adapter/**/*.zig, src/c_abi/**/*.zig, test/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
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

Concern not listed? Give it to the layer that owns the decision — the
[architecture rule](architecture.md)'s Layer Ownership list is the map — never
to the layer where the symptom appeared.

## Anti-Patterns

- allocating from an unbounded length prefix;
- caching borrowed wire bytes in session state;
- returning a generic "internal" error for a known malformed frame shape;
- letting adapters invent protocol semantics;
- reusing a peer after fatal wire refusal without an explicit recovery contract.

Fail closed, surface typed reasons, and keep policy at the layer that owns it.
