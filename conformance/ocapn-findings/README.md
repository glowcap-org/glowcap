# Pinned OCapN findings

This directory turns protocol discrepancies found while reviewing pancake into
small, neutral, reproducible checks over the exact upstream revisions in the
repository. It does not decide which participant is correct and it does not
modify any upstream checkout.

## `op:listen` operand count

Three pinned sources disagree on how many operands `op:listen` carries. The
exact text each one holds:

| Source | Says |
| ------ | ---- |
| draft CapTP specification | `<op:listen to-desc` … `listen-desc>      ; desc:import-object \| desc:import-promise` — two operands |
| OCapN test suite (`utils/captp_types.py`) | `assert len(record.args) == 3`, then `wants_partial = record.args[2]` |
| Spritely Goblins (`goblins/ocapn/captp.rkt`) | `(to-desc listener-desc wants-partial?)` |

pancake implements the three-operand form, following the suite and Goblins
rather than the draft. That is a choice about interoperating with what runs
today, not a claim about which shape is correct.

Run:

```sh
zig build ocapn-findings-check
```

It prints the commit each source is pinned at, and fails if any of those
observations stops matching its source or if a submodule has drifted off the
commit this repository pins. A pin bump must therefore re-evaluate the
discrepancy instead of silently carrying the note forward.

## Upstream-use note

This finding and its checker were prepared with AI assistance during a pancake
repository review, so they are evidence for the pancake maintainer rather than
an upstream-ready report, and nobody should submit this text or script as-is.

If you would like it filed upstream, ask. It will be reproduced by hand,
rewritten in the maintainer's own words, and checked against the target
project's contribution and AI-use policy before it is sent anywhere. See
[`PROVENANCE.md`](../../PROVENANCE.md) for why that order is not negotiable.
