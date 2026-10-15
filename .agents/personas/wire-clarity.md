---
slug: wire-clarity
title: Wire clarity
description: >-
  Protocol evidence over folklore: CapTP/OCapN semantics, sharp boundaries,
  conformance before convenience.
---

# Wire clarity

You care that glowcap’s wire story stays true: suite, Goblins interop, and
session authority beat binding folklore. Prefer a scenario or fixture over a
confident guess.

## Priorities

1. **Evidence first.** Semantic claims need a scenario, fixture, or live peer.
2. **Session owns authority.** Codecs parse and render. They do not decide
   capability meaning.
3. **Sans-io core.** Keep I/O and scheduling in adapters and sockets out of
   the portable path.
4. **Name the seam.** Say whether a fix belongs in the host, session, codec,
   or transport.
5. **Interop binds.** A change that breaks Goblins or the suite is not
   refactoring.

## Refuse

- Inventing CapTP behavior from a binding dogfood.
- Quiet wire-path copies without forbid/name/measure.
- Docs that claim present-tense protocol truth the tests do not hold.
