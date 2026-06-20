# pancake

<img src="assets/pancake-icon-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![copy-budget contract](https://img.shields.io/badge/copy--budget-contract-blue.svg)](docs/architecture.md)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

> **pancake is a codec-neutral [CapTP](http://erights.org/elib/distrib/captp/)
> core for [OCapN](https://github.com/ocapn/ocapn).** **Syrup where OCapN
> requires it. Owned frames or borrowed views wherever frames cross a
> boundary.** **Because you can't have pancakes without syrup.**

<br clear="left" />

## What is this?

pancake is a Zig implementation of the object-capability networking core: two
programs hand each other unforgeable references to remote objects and call
methods across a session with the same authority discipline as local references.
No ambient authority, no string-typed permissions. If you hold the reference,
you can use it.

New to capabilities, CapTP, or OCapN?
[`docs/capabilities.md`](docs/capabilities.md) explains the ideas and the
vocabulary before any code appears.

It targets OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. You
use it as a library, and you manage its memory yourself. Nothing important
hides: where a copy happens, where something is allocated, which wire format is
in play, where I/O and scheduling live: all of it stays visible at the boundary
that owns it.

<p align="center">
  <img src="assets/pancake-goblin-512.png" alt="a purple goblin studying a smiling stack of pancakes" width="320" />
</p>

## Quick start

pancake is a Zig package:

```sh
zig fetch --save git+https://codeberg.org/jimisaacs/pancake
```

```zig
const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pancake", pancake.module("pancake"));
```

A client is one object and a handful of verbs: connect, fetch a capability by
name, call it, switch on the settled outcome, close.

```zig
const pancake = @import("pancake");

// Dial by locator, the one dialer. The transport set is a bare slice naming
// the transports this client can reach (here, just TCP); `tcp.at` turns a
// `host:port` into a `tcp` locator with no caller buffer. Add `iroh` by
// putting one more netlayer in the slice, the same call.
var tcp_resident = pancake.net.tcp.Resident{ .io = io };

const conn = try pancake.driver.connect(&.{tcp_resident.netlayer()}, allocator, pancake.net.tcp.at(designator), .ephemeral, .{});
defer conn.close();

const greeter = try conn.fetch("greeter"); // a capability, by name
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try conn.call(greeter, .{
    .verb = "greet",
    .args = &.{.{ .string = "world" }},
}, arena.allocator());
switch (settled) {
    .fulfilled => |arg| std.debug.print("{s}\n", .{arg.string}),
    .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
}
```

That snippet is machine-checked:
[`examples/zig/readme_quick_start.zig`](examples/zig/readme_quick_start.zig)
carries the same code verbatim and runs under `zig build examples`. The hosting
half is the same shape;
[`examples/zig/01_connect_and_serve.zig`](examples/zig/01_connect_and_serve.zig)
is the runnable version of both halves.

Not writing Zig? The same library is a C ABI with bindings:
[`docs/consuming-from-c.md`](docs/consuming-from-c.md) is the route for C and
FFI consumers, and [`bindings/`](bindings/README.md) holds the Rust, Deno,
Python, and Racket surfaces, each speaking the same nine application verbs.

## Learn by example

The [example chapters](examples/README.md) read top-down, from the application
surface to the raw engine: connect and serve, actors and far-sends, lookup by
name, then explicit frames one `step` at a time. Three full applications then
run the same code across every binding on one wire: a capability-secure chat
room (`zig build demo-rooms`), a shared task board (`zig build demo-tasks`), and
an AI-agent tool harness with delegation, attenuation, and revocation
(`zig build demo-tools`).

## Design posture

The portable core is deterministic, sync, and no-I/O; adapters own sockets,
scheduling, and host integration. Session state is authoritative; codecs parse
and render but decide nothing. Every wire-path allocation and copy is forbidden,
named, or measured, and the budgets are build gates, not intentions. Conformance
is load-bearing: a real Spritely Goblins peer holds a live conversation with
pancake in both directions, and the upstream OCapN test suite runs against it.
The whole argument lives in [`docs/architecture.md`](docs/architecture.md) and
[`docs/vision.md`](docs/vision.md).

## Status

What ships today — the wire operation surface, both codecs, three netlayers, the
actor layer, third-party handoffs, live Goblins interop from every binding — is
inventoried in [`docs/shipped.md`](docs/shipped.md). The edges that remain
(cleartext TCP, process-lifetime bootstrap registrations, the fail-closed OCapN
Null, the unbuilt `griddle` network simulator) live in
[`docs/boundaries.md`](docs/boundaries.md), and the ordered route to 1.0 in
[`docs/ladder.md`](docs/ladder.md).

## Build

```sh
zig build          # the composable C ABI archives + their headers under zig-out/
zig build check    # the full hermetic gate: tests, examples, oracles, budgets
```

Focused steps while iterating:

```sh
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build examples
zig build bindings        # rust + deno + bun + python + racket C ABI smokes
zig build oracle-check    # protocol manifest + Syrup fixture parity
zig build meta-check      # scaffolding and documented build-step parity
```

Live interop, conformance, benchmarks, demos, and header regeneration need extra
runtimes on PATH. See [`CONTRIBUTING.md`](CONTRIBUTING.md#verifying-changes) for
the contributor verification workflow.

## Documentation

- [`docs/capabilities.md`](docs/capabilities.md) — capabilities, CapTP, and
  OCapN from zero, plus the glossary.
- [`docs/consuming-from-c.md`](docs/consuming-from-c.md) — build, link,
  ownership rules, first complete C program.
- [`docs/architecture.md`](docs/architecture.md) — layers, memory, and the C ABI
  contract.
- [`docs/protocol-diagrams/`](docs/protocol-diagrams/README.md) — the living
  CapTP diagrams.
- [`docs/shipped.md`](docs/shipped.md) and
  [`docs/boundaries.md`](docs/boundaries.md) — what exists and where it ends.
- [`docs/decisions/`](docs/decisions/README.md) — the accepted decision records.
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting and the invariants a
  report may cite.

## License

Licensed under [Apache-2.0](LICENSE-APACHE). Contributions are accepted under the same terms.
