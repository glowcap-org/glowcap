---
description: "Zig pancake project values: explicit systems design, polished library surface, no hidden costs."
alwaysApply: true
---

# pancake — Project Values

pancake is a native Zig systems library for OCapN / CapTP. Keep the repository
small, direct, and product-grade.

## Values

- **Protocol evidence over implementation folklore.** OCapN behavior, Goblins
 fixtures, and Zig protocol scenarios justify semantic claims. A C ABI dogfood
 consumer proves consumability, not the source of truth.
- **Explicit over implicit.** Ownership, allocation, copying, I/O, scheduling,
  and authority must be visible at the API boundary that performs them.
- **No hidden runtime.** The protocol core is deterministic, sync, and no-I/O.
  Adapters own host integration.
- **Boring public surface.** Public artifacts are `libpancake.a`,
  `libpancake.so`, and `pancake.h`. The C ABI uses fixed-width types,
  `ptr + len` views, opaque handles, callbacks, return codes, and explicit
  release functions.
- **Examples must compile.** Public examples are part of the contract. If a
  README shows a command or a usage pattern, a build step should keep it honest.
- **Performance is correctness pressure.** A wire-path allocation or copy is a
  design event: forbid it, name it, or measure it.
- **Small modules, sharp boundaries.** Split by responsibility. A reader should
  know what a file owns before reading its body.
- **Polish matters.** A rough edge in the build, README, examples, or agent rules
  becomes a rough edge in every contribution.
- **Taste becomes code shape.** Do not commit external taste-reference names from
  prompts. Express the prompt through Zig-native control, clear lifetime
  surfaces, small modules, sharp tests, and boring public APIs.

## Setup Litmus

Before adding setup, build, API, or documentation surface, ask:

- Does this make `zig build`, `zig build check`, or first use simpler?
- Does this preserve plain `pancake` artifact names?
- Can a C consumer understand the ABI without knowing Zig?
- Can a Zig consumer understand ownership without reading implementation code?
- Would a hidden allocation, copy, runtime, or protocol authority decision become
  obvious in review?

