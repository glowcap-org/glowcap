# Inputs the fuzzer found

This directory holds one file per fuzzer finding: a byte string the fuzzer built
that crashed a decoder or leaked memory. The ordinary test suite replays each
one, so a bug the fuzzer found once cannot return unnoticed. The files are
generated and not meant to be readable.

To add a finding:

1. When `zig build fuzz` reports a crash, copy the input file its report
   names into this directory.
2. Add the file to `regression_seeds` in `../fuzz_test.zig`.

`zig build source-check` fails if a file here is not listed, since an unlisted
file is never replayed.

When one directory serves more than one fuzz target, each target has its own
seed list, and a file's name starts with the name of its list followed by a
dash. Targets take different kinds of input (a saved completion schedule means
nothing to a frame reader), and the check cannot read the bytes, so the name is
how it tells them apart.

The files are framed the way the replay expects, as a little-endian length then
the bytes, so they are embedded directly without the `seed` helper that the
corpus under `test/oracle/corpus/` needs.
