# pancake — Agent Guide

This repository is `pancake`: a Zig implementation of the OCapN / CapTP
substrate. Agents working here carry forward the Rust project's architectural
lessons without treating Rust implementation details as Zig protocol design.

OCapN behavior, Spritely Goblins fixtures, and Zig-local protocol scenarios are
the conformance authority. Rust is implementation history to mine and a C ABI
dogfood consumer; it is not the oracle for Zig semantics.

## First Principles

- Protocol correctness and capability semantics come before implementation
  convenience.
- Performance is a public contract: every allocation and copy on the wire path
  is forbidden, intentional, or measured.
- Production APIs should make the correct path the easy path. Do not rely on
  comments to prevent misuse.
- The portable core stays sync and no-I/O; adapters own `std.Io`, transports,
  scheduling, and host integration.
- Frame movement is owned transfer or bounded borrow. Test/debug copying lives
  outside production modules.
- Session state is authoritative; codecs parse and render but do not own
  authority.
- Conformance is load-bearing. A semantic claim needs a scenario or fixture.
- Names associated with external engineering taste references belong in prompts
  and plans, not in committed files. Encode that taste as explicit protocol
  vocabulary, honest allocation/lifetime surfaces, polished boundaries, and
  tests.

## Agent Scaffolding

Canonical agent guidance lives under [`.agents/`](.agents/). Claude gets rules
through one directory symlink, [`.claude/rules`](.claude/rules/) →
`.agents/rules`. Cursor gets one symlink per rule,
`.cursor/rules/<name>.mdc` → `.agents/rules/<name>.md`, because Cursor discovers
rules by `.mdc` file.

Read [`.agents/rules/agent-scaffolding.md`](.agents/rules/agent-scaffolding.md)
before changing scaffolding, public APIs, frame ownership, codec/session/runtime
boundaries, or test/debug helper placement.

Load the focused rule before touching its surface: `project-values`,
`architecture`, `memory`, `tests`, `resilience`, `cli`, `doc-drift`, and
`prerelease-language` all live under
[`.agents/rules/`](.agents/rules/).

Serena is first-class for code-symbol work. Read
[`.agents/rules/serena-mcp.md`](.agents/rules/serena-mcp.md) before symbol
lookup, reference walks, renames, implementation lookup, body-level edits, or
single-file diagnostics in Zig source. The operator notes live at
[`.agents/skills/serena/SKILL.md`](.agents/skills/serena/SKILL.md).
