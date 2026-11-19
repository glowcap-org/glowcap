---
name: bend-laws
description: >-
  Use for Bend laws, deterministic property coverage, and migrating test or
  fuzz cases that exercise the same rule.
---

# Bend laws

Bend checks proof models under `test/`. Keep it in the proof toolchain.

1. **Find the contract.** Name the owning code and read the spec or decision
   that defines its behavior. Start with the [existing books](../../../test/README.md#bend-proofs).
   Look for a rule over values, paths, or schedules. Reuse a law that already
   covers it. Migrate when the law and its implementation evidence are easier
   to maintain than the cases they replace or would take to cover the rule.
2. **State the law.** Put the model and laws beside the owning tests.
   Follow the [release laws](../../../test/engine/held_resolution_laws/LAWS.bend)
   and their [proof bodies](../../../test/engine/held_resolution_laws/PROOF.bend).

   Quantify over relevant inputs and histories. State how the model treats
   limits such as integer overflow and missing state. Prove allowed and
   refused cases where the rule has both. Share lemmas through the owning
   book or `test/support/`.
3. **Tie it to the implementation.** Use a compact Zig witness for each
   distinct path, or [compare with Bend](../../../test/loam/access/policy_laws/bounds/table_test.zig)
   when the model supplies expected results. Name the cases the law
   subsumes and remove repeated fixtures in the same change.

   Keep implementation checks for allocation, copying, timing, parsing,
   cryptography, foreign code, live interop, and durable effects. Keep
   regression inputs until an implementation check covers their failure.
   Benchmarks own the figures published on the site.
4. **Prove it fails for the right reason.** In scratch, change the model
   to violate each new guarantee. Confirm the verifier reports the false
   law, then run the original book and the focused Zig witnesses. When a
   proof needs a fix, check the law against its spec before changing it.
5. **Wire the book.** Register its entry point with `bend_proof()` in
   [ci/groups.py](../../../ci/groups.py) and add the law, witness, and owning
   implementation paths to the `bend-proofs` triggers. Link the book from
   [test/README.md](../../../test/README.md). Run the shared phase before
   handing off.

The devcontainer front selects pinned Bend and its verification kernel on
demand. Run one book with the same deadline and verdict CI uses.

```sh
.agents/skills/work/bin/glowcap-dev bash .devcontainer/bin/tools.sh exec bend -- \
  python3 tools/run-with-timeout.py --quiet-success --kill-after 2s 30s \
  bend test/engine/held_resolution_laws/PROOF.bend --verdict
```

Run all registered books through
`.agents/skills/work/bin/glowcap-dev python3 ci/gates.py run bend-proofs`.
