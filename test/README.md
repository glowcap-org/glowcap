# test/

The Zig test tree, one directory per layer under `src/`, plus `oracle/` for the
protocol corpus and scenario drivers, `support/` for shared fixtures, and the
crash and fault suites at this level. The [tests rule](../.agents/rules/tests.md)
places a new test.

## Bend proofs

From the repository root, run
`.agents/skills/work/bin/glowcap-dev python3 ci/gates.py run bend-proofs`.

### Spill growth

During an append-only run of non-saturating growth, the sum of old capacities
stays below the current capacity. That bounds bytes a relocating allocator
might copy. The Zig test checks the growth rule and counts actual allocation
events. [Growth laws](foundation/spill_laws/LAWS.bend)

### Stored-resolution releases

The last stored-resolution hold releases the parked retains. Bend checks
that releasing the application retain before or after that drop pays the same
total. The Zig test runs every bounded schedule across both profiles and codecs.
[Release laws](engine/held_resolution_laws/LAWS.bend)

### Loam recovery

When a commit advances the revision, its stamp identifies one ticket by
store, incarnation, revision, and sequence. Bend proves uniqueness. The Zig
fixture checks competing tickets and exhaustion at the revision limit.
[Recovery law](loam/core/recovery_laws/LAWS.bend)

### Loam resource scope

Exact selections depend on resource identity. Subtree scopes depend on
ancestry at a validated graph revision. Bend checks that subtree narrowing
preserves containment and that finite selections grant only covered
members. Zig exercises reparenting, grant checks, and reuse of a retired
resource slot.
[Scope laws](loam/access/scope_laws/LAWS.bend)

### Loam policy laws

A delegated permission survives exactly when every grant carries it.
Intersection preserves prerequisites. A child bound fits a chain exactly
when it fits every parent, including the starting grant.
[Permission laws](loam/access/policy_laws/LAWS.bend) · [Bound laws](loam/access/policy_laws/bounds/LAWS.bend)

Zig tests exercise the permission masks and prerequisite edges together.
The gate compares Zig’s policy bounds with Bend for each ordering and each
combination of absent bounds, using zero and the largest `u64` as witnesses.

### CapTP answer lifetime

The first fulfillment or break fixes a promise's outcome. Reusing a wire
position starts a fresh answer. An accepted notification can outlive the
position and still settle its own answer. Bend checks arbitrary sequences of
settlement attempts and gaps between stamps. Zig exercises both profiles and
a detached settlement after position reuse.
[Answer laws](session/answer_laws/LAWS.bend)

### Loam call allocation

Each positive allocation spends a request slot and at least one byte.
Bend checks that the aggregate allowance covers every partition within
the byte and request limits, and charges padding only for possible
requests. Zig measures the physical backing, alignment, and scratch lifetime.
[Allocation laws](loam/hosting/allocation_laws/LAWS.bend)

### Export range disjointness

Bend proves that adjacent half-open ranges share no position. The Zig tests
check node assignment and the bounds on fresh exports.
[Export range law](engine/export_range_laws/LAWS.bend)

### Handle generations

Within one owner’s row, a freed generation stays stale through any number
of reuses. Bend checks advancement and retirement. The Zig test exercises
ordinary reuse and the final two generations.
[Generation law](foundation/handle_generation_laws/LAWS.bend)

### CapTP descriptor roles

Sender and receiver exchange near and far references while preserving their
wire roles. Targets and listener destinations occupy disjoint roles. A
question stays addressable through settlement until its row retires. Zig
exercises both receive representations and verifies refusal before an
answer is installed or an import is introduced.
[Descriptor laws](session/descriptor_laws/LAWS.bend)

### Negotiation laws

Swapping peers preserves candidate order at every rank. The Zig test
checks the selector on the built-in offers, and the pairing tests
exercise the handshake. [Rank proof](engine/negotiation_laws/PROOF.bend)

### Peer outbound waterline

Ordinary producers need space below the waterline. A staged carrier's replacement
can finish at the waterline if its own charge fits. Repricing accounts for the
new carrier and preserves unrelated charges. Zig runs admission and drain
across both profiles. [Waterline laws](engine/peer/waterline_laws/LAWS.bend)

### Queue capacity and reference releases

A charge fits the remaining space exactly when the new total fits the cap.
For one CapTP position, a sequence of releases fits the releasable count
exactly when its sum fits. Applying those releases leaves the same releasable
count as subtracting the sum.

Relay input charges the live suffix. Gift admission checks the remaining
rows plus the replacement. One Bend law checks the capacity after either
operation removes the old charge.
[Accounting laws](support/bounded_arithmetic/LAWS.bend)

### Stream framing

Once the body length is known, Bend proves that splitting the input into
chunks consumes the same number of body bytes. The Zig test checks split
prefixes, the body, where the next frame begins, and which buffer lends
the result. [Body boundary law](foundation/stream_framing_laws/LAWS.bend)

### Actor proxies and turn budgets

An invocation reaches its target only when every proxy allows it. A revoked
caretaker blocks its entire path, and a verb grant leaves direct invocation
outside its authority. [Proxy laws](actors/ocap_laws/LAWS.bend)

For a fixed queue, splitting a turn budget leaves the same work pending.
Retrying an exhausted epoch leaves that work queued. The Zig tests exercise
both drive paths and observe the turns that actually commit.
[Turn budget laws](driver/turn_budget_laws/LAWS.bend)

### Loam receipt windows

Only the next sequence can start a new operation before exhaustion.
Eviction moves the floor and shifts the surviving receipt indices. Bend
checks those rules. Zig checks the exact receipt for each retained sequence.
[Retry laws](loam/access/retry_laws/LAWS.bend)

## Fuzz regression inputs

Each layer's `fuzz_regressions/` holds one file per fuzzer finding: a byte
string the fuzzer built that crashed a decoder or leaked memory. The ordinary
test suite replays each one, so a bug the fuzzer found once cannot return
unnoticed. The files are generated and not meant to be readable.

To add a finding:

1. When `zig build fuzz` reports a crash, copy the input file its report
   names into the layer's `fuzz_regressions/` directory.
2. Add the file to `regression_seeds` in that layer's `fuzz_test.zig`.

`zig build source-check` fails if a file there is not listed, since an unlisted
file is never replayed.

When one directory serves more than one fuzz target, each target has its own
seed list, and a file's name starts with the name of its list followed by a
dash. Targets take different kinds of input (a saved completion schedule means
nothing to a frame reader), and the check cannot read the bytes, so the name is
how it tells them apart.

The files are framed the way the replay expects, as a little-endian length then
the bytes, so they are embedded directly without the `seed` helper that the
corpus under `oracle/corpus/` needs.
