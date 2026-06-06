---
description: "Agent scaffolding posture for Zig pancake — principles first, Serena-first symbol work, no-footgun APIs."
alwaysApply: true
---

# pancake — Agent Scaffolding Posture

This repository is pancake's Zig implementation. Agent scaffolding must preserve
the project vision before it preserves any incidental code shape.

## Priority Order

1. **No-footgun structure.** Make invalid, expensive, or debug-only paths
   unavailable by construction. Prefer types, ownership transfer, module
   boundaries, build boundaries, and `test/support` over warnings in comments.
2. **Principles before mechanics.** Start from the project contract: codec-neutral
   semantics, authoritative session state, sync no-I/O core, explicit frame
   ownership, C ABI, conformance gates, and measured performance.
3. **Zig-shaped implementation.** Express the ownership truth directly: owned
 `Frame`, borrowed `FrameView`, test-only fixtures outside production modules,
 and no hidden allocation/copy/runtime. Do not import workarounds shaped for
 another language's constraints.
4. **Serena is first-class.** For code-symbol questions, reference walks,
   implementation lookup, renames, and body-level edits, use Serena first when
   the language server supports the target. Use text tools for prose, config,
   literals, and byte-pinned edits.
5. **Scaffolding follows pancake.** Canonical agent guidance lives in `.agents/`;
   tool overlays point back to it. Do not duplicate rule content across tools.
   The overlay topology is intentional:
   - `.claude/rules` is one directory symlink to `.agents/rules`.
   - `.cursor/rules/<name>.mdc` is one symlink per rule because Cursor discovers
     rules by `.mdc` file.
   - `.claude/skills` and `.cursor/skills` are directory symlinks to
     `.agents/skills`.
6. **Meta scaffolding is gated.** `zig build meta-check` verifies the overlay
   symlinks, hook wiring, Serena MCP pointers, generated-state ignores, and
   documented `zig build` step names. If the topology changes, update
   `tools/meta_check.zig` in the same change.
7. **Progressive disclosure by default.** Start with the shortest useful answer:
   outcome, decision, blocker, or next action. Expand into details, logs, diffs,
   alternatives, or rationale only when they change the decision or the user asks
   for them.
8. **Verify before claims.** Run the relevant focused gate before calling work
   complete. For current Zig code, prefer `zig build check`; use focused gates
   while iterating.

## Litmus Tests

- Would an agent naturally choose the principled path without remembering a
  cautionary note?
- Is any test/debug convenience outside the production surface?
- Can a caller accidentally introduce hidden allocation, hidden copy, hidden I/O,
  hidden authority, or hidden runtime state?
- Does the change carry forward pancake's learned architecture while still being
  native Zig?
- Do public examples and build steps make first use simpler instead of clever?
- Would `zig build meta-check` catch this scaffolding shape if it drifted?
- Did the response avoid burning tokens on details that should have stayed
  behind a follow-up?
