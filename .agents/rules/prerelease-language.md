---
description: "Prerelease language discipline: living-state docs describe today's Zig pancake, not the path from older shapes."
globs: **/*.md, src/**/*.zig, test/**/*.zig, bench/**/*.zig, examples/**/*.zig, examples/**/*.c, include/**/*.h
---

# pancake — Prerelease Language

This repository has no stable consumer migration burden yet. Living-state docs
and source comments describe the current shape, not the transition that produced
it.

## Scrub From Living-State Surfaces

- internal review labels or audit-wave labels;
- "formerly", "previously", "originally", or "renamed from" notes;
- "pre-1.0" / "pre-publication" as rationale;
- "during the transition" phrasing when the current repository role is enough;
- "later" / "future" when the actionable current fact is "not implemented".

## What To Write Instead

- Describe current APIs and invariants authoritatively.
- For missing pieces, state the present boundary: "production transports are not
  implemented" rather than narrating a roadmap.
- Keep transition rationale in PR descriptions or historical decision records,
  not first-read project surfaces.
