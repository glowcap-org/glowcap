# test/

The Zig test tree, one directory per layer under `src/`, plus `oracle/` for the
protocol corpus and scenario drivers, `support/` for shared fixtures, and the
crash and fault suites at this level. The [tests rule](../.agents/rules/tests.md)
places a new test.

## Bend proofs

From the repository root, run
`.agents/skills/work/bin/glowcap-dev python3 ci/gates.py run bend-proofs`.

### Stored-resolution releases

The last stored-resolution hold releases the parked retains. Bend checks
that releasing the application retain before or after that drop pays the same
total. The Zig test runs every bounded schedule across both profiles and codecs.
[Release laws](engine/held_resolution_laws/LAWS.bend)

### Loam policy laws

A delegated permission survives exactly when every grant carries it.
Intersection preserves prerequisites. A child bound fits a chain exactly
when it fits every parent, including the starting grant.
[Permission laws](loam/access/policy_laws/LAWS.bend) · [Bound laws](loam/access/policy_laws/bounds/LAWS.bend)

Zig tests exercise the permission masks and prerequisite edges together.
The gate compares Zig’s policy bounds with Bend for each ordering and each
combination of absent bounds, using zero and the largest `u64` as witnesses.

### Export range disjointness

Bend proves that adjacent half-open ranges share no position. The Zig tests
check node assignment and the bounds on fresh exports.
[Export range law](engine/export_range_laws/LAWS.bend)

### Handle generations

Within one owner’s row, a freed generation stays stale through any number
of reuses. Bend checks advancement and retirement. The Zig test exercises
ordinary reuse and the final two generations.
[Generation law](foundation/handle_generation_laws/LAWS.bend)

### Negotiation laws

Swapping peers preserves candidate order at every rank. The Zig test
checks the selector on the built-in offers, and the pairing tests
exercise the handshake. [Rank proof](engine/negotiation_laws/PROOF.bend)

### Queue capacity and reference releases

A charge fits the remaining space exactly when the new total fits the cap.
For one CapTP position, a sequence of releases fits the releasable count
exactly when its sum fits. Applying those releases leaves the same releasable
count as subtracting the sum.
Relay input charges the live suffix. Bend proves the admission check for
any positive arrival and any number of bytes already consumed.
The Zig tests cover the queue, release, and relay paths.
[Accounting laws](support/bounded_arithmetic/LAWS.bend)

### Stream framing

Once the body length is known, Bend proves that splitting the input into
chunks consumes the same number of body bytes. The Zig test checks split
prefixes, the body, where the next frame begins, and which buffer lends
the result. [Body boundary law](foundation/stream_framing_laws/LAWS.bend)

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
