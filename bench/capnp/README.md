# Cap'n Proto RPC echo benches

Two small benches time Cap'n Proto RPC call round trips so the benchmarks
page can set them beside glowcap's own CapTP calls. One uses the `capnp-rpc`
Rust crate and the other the C++ reference library. They share `echo.capnp`,
an `Echo` interface with two calls:

- `greet` takes one `Text` name and returns a constant string.
- `report` takes a `Text` source, a list of eight `Text` tags, a list of
  sixty-four `Int64` readings, and an `Int64` timestamp. The server sums the
  readings and returns their count and sum.

Each bench runs one process with two threads over loopback TCP. The server
thread binds an ephemeral port on 127.0.0.1 and the client thread makes each
call in series, waiting for each reply before the next call: `greet` with the
name "world", then `report` with the fixed batch `bench/iroh_bench.zig` sends.
The timed window covers building the request, the round trip, and reading the
reply's fields. The comparison against the expected values runs after the
clock stops.

The C++ bench and its generated code are compiled with full optimization and
assertions off (`-O3 -DNDEBUG`). The installed Cap'n Proto library it links
keeps its own build settings. The Rust bench builds with
`cargo build --release`, and glowcap runs in ReleaseFast.
The Rust client runs the `capnp-rpc` crate on a current-thread tokio runtime
through the futures compat layer. Both sides park between
calls, and nothing spins.

The default run makes 3000 calls after 300 warmup calls. `--smoke` makes 200
after 50. `--pin=A,B` pins the client thread to core A and the server thread to
core B. Each bench prints one line per call in the same form as glowcap's own
round trip line, with `transport=capnp-rust` or `transport=capnp-cpp` and
`call=greet` or `call=report`.

Run both from the repository root, which builds them first:

```
zig build bench-capnp -- --pin=6,7
```

The step needs `capnp`, `cargo`, `g++` and the `capnp-rpc` pkg-config package,
all present in the devcontainer. Build output lands in `zig-out/bench-capnp/`
and `bench/capnp/rust/target/`, neither committed.
