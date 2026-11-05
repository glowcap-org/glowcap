# Cap'n Proto authoring comparison

This adapter lets a Cap'n Proto schema author the same interface description
the text modules do, so `zig build interface-authoring-check` can compare the
two paths. It reads the compiler's binary `CodeGeneratorRequest`
through Rust's `capnp::schema_capnp` API and writes
[the shared canonical description](../../../../test/interface/authoring/comparison.syrup).
The shared description reader and model validate it before emission. The
adapter never parses Cap'n Proto source or a compiler text dump.

`comparison.capnp` authors the shared corpus. Its annotations describe glowcap
calls. An annotated single-field struct preserves aliases and bounds because
`using` aliases disappear from compiler requests. `direct` means no selector.
`wireName("")` means an empty named selector. `optional` shortens the argument
list, `nullValue` distinguishes null from Void/undefined, and `pending` describes
a passable promise without waiting for it.

Only the comparison's shapes are supported. Inheritance, generic declarations
and brands, copied structs, unions, groups, defaults, unsupported types, and
unknown applied annotations are refused. This includes `throws`: the canonical
method triple has no throws metadata. A method can still break its promise at
runtime, and the description does not declare how.

Requests and output each have a 1 MiB ceiling. Limits also cover 4,096 schema
nodes, 256 parameters per method, 65,536 translation items, and bounded reader
traversal/nesting. Expanded names and references are charged before copying.
Their payload bytes are a lower bound on output size. Maps and output trees
exist only during translation.

## Checks

```sh
.agents/skills/work/bin/glowcap-dev zig build interface-test interface-authoring-check interface-authoring-lint
```

The checks compare exact canonical bytes, validate the shared model, and repeat
after bound, reply, and method edits. They test refusals, malformed requests,
and long-module expansion. A generated Rust Reader call reaches the existing
raw TCP peer, asserts Syrup/V1.0, and checks the exact request and string reply.
Its inner deadline is 20 seconds and outer deadline 30 seconds. The shared
runtime corpus runs once per emitter.

## Dependencies and measurements

The sole active adapter dependency is exact locked `capnp` 0.27.3. Its optional
`embedded-io` 0.7.1 appears in the lockfile but is disabled. The separate proof
crate uses the existing glowcap/Tokio stack. Both lockfiles are retained.

Requests must report compiler version 1.1.0. The reader uses the schema bundled
with Rust capnp 0.27.3. The container installs compiler 1.1.0 through Debian's
`capnproto` package, rather than an independent `pins.sh` entry.

| Measurement | Result |
| --- | --- |
| Request / canonical output | 16,440 / 1,151 bytes |
| Release executable | 662,000 bytes |
| Cold build / compiler-tree peak RSS | 1.350 s / 297,828 KiB |
| Warm adapter, mean ± standard deviation | 0.914 ± 0.250 ms |
| Warm compiler + adapter | 2.677 ± 0.611 ms |
| Adapter child RSS upper bound | 15,416 KiB, including Python's inherited spawn floor |

Warm timings used 20 runs after three warmups, without CPU pinning. Startup
noise is visible. These measure frontend work, not emitted consumers or runtime
performance. RSS does not isolate payload allocations.

Nonblank source counts are 424 Rust adapter lines (including the version test),
113 Python test lines, 42 Rust proof lines, 38 schema lines, and 39 separate Zig
build-integration lines. Manifests, lockfiles, and prose are excluded.

The measured source digest is
`d3eaba4de50ddd79baf11a9358599c875dd63f427042c00f6632d0ce67ebdfd0`.
It hashes Cargo.toml, Cargo.lock, src/main.rs, src/schema.rs, and src/syrup.rs in
that order, using each repository path, NUL, then contents.

Reproduce the cold build with absent target and intermediate directories.
The container otherwise shares intermediates independently of `--target-dir`:

```sh
.agents/skills/work/bin/glowcap-dev --env CARGO_BUILD_BUILD_DIR=/workspaces/glowcap/zig-out/capnp-cost-build cargo build --release --locked --offline --manifest-path tools/interface/authoring/capnp/Cargo.toml --target-dir zig-out/capnp-cost-target
```

Build time used Python `time.monotonic()` around Cargo. Peak RSS used
`resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss` in a fresh process.
Warm timing used `hyperfine --warmup 3 --runs 20 --shell bash` on the adapter
with a saved request, then the compiler-to-adapter pipeline with `pipefail`.
Both wrote canonical bytes to scratch files.
