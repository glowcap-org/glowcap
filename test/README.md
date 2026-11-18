# test/

The Zig test tree, one directory per layer under `src/`, plus `oracle/` for the
protocol corpus and scenario drivers, `support/` for shared fixtures, and the
crash and fault suites at this level. The [tests rule](../.agents/rules/tests.md)
places a new test.

## Loam policy laws

A delegated permission survives exactly when every grant carries it.
Intersection preserves prerequisites. A child bound fits a chain exactly
when it fits every parent, including the starting grant.
[Permission laws](loam/access/policy_laws/LAWS.bend) · [Bound laws](loam/access/policy_laws/bounds/LAWS.bend)

In the devcontainer, run `.devcontainer/bin/tools.sh exec bend -- zig build loam-policy-proof`.

The permission proof models one bit per right. Zig tests exercise the masks
and prerequisite edges together.

Bend proves the bound laws over natural numbers. A supplied fact must satisfy
each parent bound. An omitted fact places no demand. The gate compares Zig’s
policy operations with Bend for every ordering and combination of absent
bounds, using zero and the largest `u64` as witnesses.

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
