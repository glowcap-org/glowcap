# test/

The Zig test tree, one directory per layer under `src/`, plus `oracle/` for the
protocol corpus and scenario drivers, `support/` for shared fixtures, and the
crash and fault suites at this level. The [tests rule](../.agents/rules/tests.md)
places a new test.

## Loam policy laws

A delegation chain can only narrow the rights held at its start. The
[Bend laws](loam/access/policy_laws/LAWS.bend) state this for any number of
intersections. The [Zig tests](loam/access/policy_test.zig) check the link to
Loam on two finite sets of policies, one with prerequisites and one with
ordered bounds. Each Zig bit stands for a child policy the parent can delegate.
Bitwise intersection applies Bend’s Boolean AND to each child.

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
