# Inputs the fuzzer found

This directory holds one file per fuzzer finding. When `zig build fuzz`
reports a crash, copy its input from `.zig-cache/f/crash` into this directory.
Each file is a byte string the fuzzer built that crashed a decoder or leaked
memory.

The files are generated, not hand-written, and are not meant to be readable.
What matters is that the ordinary test suite replays each one, so a bug the
fuzzer found once cannot return unnoticed. Add each new file to
`regression_seeds` in `../fuzz_test.zig`. `zig build source-check` fails if a
file here is not listed, because a regression test that never runs is worse
than none.

When one directory serves more than one fuzz target, each target has its own
seed list. A file's name must then start with the name of the list it belongs
to, followed by a dash. Two targets in one file can take different kinds of
input (a saved completion schedule means nothing to a frame reader), and the
check cannot read the bytes, so the name is the only way it can tell them
apart.

The files are already framed the way the replay expects: a little-endian
length, then the bytes. So they are embedded directly, without the `seed`
helper that the corpus under `test/oracle/corpus/` needs.
