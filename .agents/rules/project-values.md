---
description: "Zig pancake project values: explicit systems design, polished library surface, no hidden costs."
alwaysApply: true
---

# pancake — Project Values

pancake is a native Zig systems library for OCapN / CapTP. Keep the repository
small, direct, and product-grade.

The destination these values serve is [`docs/vision.md`](../../docs/vision.md).
The values below are how that destination is protected in day-to-day work; read
the vision itself when a tradeoff between them is unclear.

## Values

- **Protocol evidence over implementation folklore.** OCapN behavior, Goblins
  fixtures, and Zig protocol scenarios justify semantic claims. A C ABI dogfood
  consumer proves consumability, not the source of truth.
- **Explicit over implicit.** Ownership, allocation, copying, I/O, scheduling,
  and authority must be visible at the API boundary that performs them.
- **No hidden runtime.** The protocol core is deterministic, sync, and no-I/O.
  Adapters own host integration.
- **Boring public surface.** The C ABI ships as a small declared set of
  composable archives linked à la carte — `libpancake_ocapn`, `libpancake_net`,
  and one per transport (`libpancake_net_transport_tcp`,
  `libpancake_net_transport_inproc`, `libpancake_net_transport_iroh`) — each
  with its own header naming only the family it exports (ADR-0059). Each archive
  is itself boring: fixed-width types, `ptr + len` views, opaque handles,
  callbacks, return codes, and explicit release functions.
- **Examples must compile.** Public examples are part of the contract. If a
  README shows a command or a usage pattern, a build step should keep it honest.
- **Performance is correctness pressure.** A wire-path allocation or copy is a
  design event: forbid it, name it, or measure it.
- **Small modules, sharp boundaries.** Split by responsibility. A reader should
  know what a file owns before reading its body.
- **Polish matters.** A rough edge in the build, README, examples, or agent
  rules becomes a rough edge in every contribution.
- **Taste becomes code shape.** Do not commit external taste-reference names
  from prompts. Express the prompt through Zig-native control, clear lifetime
  surfaces, small modules, sharp tests, and boring public APIs.

## Release Bar

Work toward a 1.0 where the shape feels inevitable, a reader should not be able
to imagine a cleaner OCapN implementation at this layer without breaking what
pancake protects (performance, architecture, cross-binding interop).

- **Assess, then act or prove inaction.** Substantial work uses the
  [work skill](../skills/work/SKILL.md): fix what the assessment finds, or show
  gates and documented boundaries that justify leaving it.
- **Names and structure are architecture.** A misleading module or type name is
  a boundary bug, not cosmetics.
- **No half measures on touched surfaces.** If you open a layer, leave it
  sharper, code, tests, docs, and examples aligned in the same change.
- **Compound for the next agent.** Accurate living-state docs and passing gates
  matter more than session-local narration.

## Setup Litmus

Before adding setup, build, API, or documentation surface, ask:

- Does this move toward [`docs/vision.md`](../../docs/vision.md), or at least
  hold a line that protects it, rather than trading performance, the
  architecture, or cross-binding interop for local convenience?
- Does this keep framework-shaped ambition (actors, the simulator) _above_ the
  sans-io core instead of pushing authority or I/O down into it?
- Does this make `zig build`, `zig build check`, or first use simpler?
- Does this preserve plain `pancake` artifact names?
- Can a C consumer understand the ABI without knowing Zig?
- Can a Zig consumer understand ownership without reading implementation code?
- Would a hidden allocation, copy, runtime, or protocol authority decision
  become obvious in review?
