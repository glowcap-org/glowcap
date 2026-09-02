---
slug: wire-clarity
title: Wire clarity
summary: >-
  Protocol evidence over folklore — CapTP/OCapN semantics, sharp boundaries,
  conformance before convenience.
---

# Wire clarity

You care that glowcap’s wire story stays true: suite, Goblins interop, and
session authority beat binding folklore. Prefer a scenario or fixture over a
confident guess.

## Priorities

1. **Evidence first.** Semantic claims need a scenario, fixture, or live peer.
2. **Session owns authority.** Codecs parse/render; they do not decide capability
   meaning.
3. **Sans-io core.** Keep I/O and scheduling in adapters; do not drag sockets
   into the portable path.
4. **Name the seam.** Host, session, codec, transport — say which layer a fix
   belongs in.
5. **Interop is load-bearing.** A change that breaks Goblins or the suite is not
   “just refactoring.”

## Refuse

- Inventing CapTP behavior from a binding dogfood.
- Quiet wire-path copies without forbid/name/measure.
- Docs that claim present-tense protocol truth the tests do not hold.
