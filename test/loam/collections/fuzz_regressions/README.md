# Inputs the fuzzer found

One file per finding, copied from `.zig-cache/f/crash` when `zig build fuzz`
reports one. Each is a byte string the fuzzer built that crashed a decoder or
leaked memory.

They are not hand-written and they are not readable; that is fine. What matters
is that each one is replayed by the ordinary test suite, so a bug the fuzzer
caught once cannot come back unnoticed. Wire a new file into `regression_seeds`
in `../fuzz_test.zig`; `zig build source-check` fails if a file here is not wired,
because a regression test that never runs is worse than none.

Where a directory serves more than one target, each target has its own seed
list and a file's name must begin with the list it belongs to, followed by a
dash. Two targets in one file can take different input shapes — a saved
completion schedule means nothing to a frame reader — and the name is the only
part of that a check can see, since it cannot read the bytes.

The files are already framed the way the replay expects — a little-endian
length, then the bytes — so they are embedded directly, without the `seed`
helper that the corpus under `test/oracle/corpus/` needs.
