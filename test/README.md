# test/

The Zig test tree, one directory per layer under `src/`, plus `oracle/` for the
protocol corpus and scenario drivers, `support/` for shared fixtures, and the
crash and fault suites at this level. The [tests rule](../.agents/rules/tests.md)
places a new test.

## Loam policy laws

A delegation chain can only narrow its starting rights. Intersecting valid
grants also preserves each permission's prerequisites. The
[permission laws](loam/access/policy_laws/LAWS.bend) prove these properties
one permission or dependency at a time.

A child bound fits a delegation chain exactly when it fits every parent,
including the starting grant. A supplied fact follows the same rule. The
[bound laws](loam/access/policy_laws/bounds/LAWS.bend) cover absent bounds
and inclusive floors and ceilings. They use Zig's decisions and assume
`std.math.order` orders `u64` the same way Bend orders natural numbers.
The gate exercises the Zig adapters with absent bounds, zero, and the largest
value. [Policy tests](loam/access/policy_test.zig) check how Loam applies the
rules across fields.

Run `.devcontainer/bin/tools.sh exec bend -- zig build loam-policy-proof` in the
devcontainer to check the proof. `zig build test` checks the Zig operations.

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
