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

## Locator hints type

Two pinned sources disagree on the shape accepted for a peer locator's hints:

| Source | Says |
| ------ | ---- |
| draft Netlayers specification | hints are “just a mapping of information” |
| Spritely Goblins (`goblins/ocapn/structs-urls.rkt`) | the constructor contract accepts only false or a string |

pancake currently represents non-empty hints as a Syrup dict. The constructor
contract applies only where Goblins-side code builds a locator. The wire
unmarshaller constructs nodes through the raw constructor, so a dict-hinted
locator arriving on the wire does decode, and `zig build goblins-gift-hints`
observes that live. This finding records only the pinned source mismatch; it
does not decide which hints shape upstream should choose or make a
pancake-specific extension an OCapN finding.

## Handoff withdrawal looks up sessions by the full node value

Two pinned observations in the same Goblins revision treat locator hints
differently:

| Source | Says |
| ------ | ---- |
| Spritely Goblins (`goblins/ocapn/structs-urls.rkt`) | `same-node-location?` compares transport and designator, "ignoring hints" |
| Spritely Goblins (`goblins/ocapn/captp.rkt`) | withdrawal resolves its session via `locations->open-session-names`, keyed by the full node value |

The withdrawal lookup is `equal?`-keyed over the whole node, hints included,
and the table is registered under the partner's hello-declared location. The
consequence, observed live: a `desc:handoff-give` redeems only when its
exporter locator equals the exporter's hello-declared location hints-and-all.
`zig build goblins-gift-hints` passes because the hinted location is advertised
in the exporter's hello and the give embeds it verbatim; a give hint the hello
did not carry misses the session lookup and the withdrawal errors. As above,
this records the pinned behavior without deciding whether hints should
participate in that lookup.

## Handoff replay count uses the wrong session

The draft and Goblins assign the receive certificate's replay counter to
different relationships:

| Source | Says |
| ------ | ---- |
| draft CapTP specification | `handoff-count` must not have been used in the **Exporter-Receiver** session |
| Spritely Goblins (`goblins/ocapn/captp.rkt`) | validates and advances the count on `gifter-exporter-session-coordinator` |

Two independent Receivers may each validly issue count zero on their first
Exporter-Receiver session. When both redeem gifts deposited through the same
long-lived Gifter-Exporter session, Goblins accepts the first zero, advances
the Gifter-Exporter coordinator's remote count, and rejects the second zero as
an invalid handoff certificate. The same mismatch affects a Receiver that
restarts its session-local counter after reconnecting.

pancake keeps accepted replay authority on each Receiver-Exporter session. Its
automatic V1 path uses a Node-lifetime issuance cursor to interoperate across
replacement sessions belonging to one Node, but independent nodes neither
share nor coordinate protocol state. Doing so would erase the session scope
the certificate names.

## Pre-handshake `op:abort` teardown

The draft says `op:abort` severs the connection. Goblins replaces its
pre-handshake handler with a no-op and keeps the read loop alive. The suite
accepts a timeout or clean EOF after sending more data, but not the TCP reset a
peer can observe when the receiver closes with that data unread.

Run:

```sh
zig build ocapn-findings-check
```

It prints the commit each source is pinned at, and fails if any of those
observations stops matching its source or if a submodule has drifted off the
commit this repository pins. A pin bump must therefore re-evaluate the
discrepancy instead of silently carrying the note forward.

## Upstream-use note

These findings and their checker were prepared with AI assistance during a pancake
repository review, so they are evidence for the pancake maintainer rather than
an upstream-ready report, and nobody should submit this text or script as-is.

If you would like it filed upstream, ask. It will be reproduced by hand,
rewritten in the maintainer's own words, and checked against the target
project's contribution and AI-use policy before it is sent anywhere. See
[`PROVENANCE.md`](../../PROVENANCE.md) for why that order is not negotiable.
