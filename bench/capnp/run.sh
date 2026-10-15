#!/bin/sh
# Build and run both Cap'n Proto echo benches, printing one line each.
# Usage: sh bench/capnp/run.sh [--smoke] [--pin=A,B]
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
out=$root/zig-out/bench-capnp
mkdir -p "$out"

(cd "$root/bench/capnp/rust" && cargo build --release --quiet)
rust_bin=$root/bench/capnp/rust/target/release/capnp-echo-bench

capnp compile -oc++:"$out" --src-prefix="$root/bench/capnp" "$root/bench/capnp/echo.capnp"
# shellcheck disable=SC2046
g++ -O3 -DNDEBUG -std=c++17 -I"$out" "$root/bench/capnp/cpp/echo.c++" "$out/echo.capnp.c++" \
    -o "$out/capnp-cpp-echo" $(pkg-config --cflags --libs capnp-rpc) -pthread

"$rust_bin" "$@"
"$out/capnp-cpp-echo" "$@"
