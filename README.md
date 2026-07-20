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

pancake lets two programs pass each other unforgeable references to remote
objects and call methods on them across a session, with the same authority
rules as a local call. Hold the reference and you can use it. There is no
ambient authority and no string-typed permission to forge.

It is a Zig library for OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. You
link it and manage its memory yourself. Every copy, every allocation, the wire
format in play, and where I/O and scheduling live stay visible at the boundary
that owns them.

New to capabilities, CapTP, or OCapN? Start with
[`docs/capabilities.md`](docs/capabilities.md).

<p align="center">
  <img src="assets/pancake-goblin-512.png" alt="a purple goblin studying a smiling stack of pancakes" width="320" />
</p>

## Quick start

Fetch the Zig package, then connect / fetch / call. The human walkthrough
(tcp + iroh, C, bindings) is
[`site/content/start.smd`](site/content/start.smd) (`zig build docs-serve`).

```sh
zig fetch --save git+https://codeberg.org/jimisaacs/pancake
```

```zig
const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pancake", pancake.module("pancake"));
```

```zig
const std = @import("std");
const pancake = @import("pancake");

// tcp: the peer is a place, a cleartext `host:port`. The slice names the
// transports this client can reach; `tcp.at` spells the designator as a locator.
var tcp_resident = pancake.net.tcp.Resident{ .io = io };
const partner = pancake.net.tcp.at(designator);

const session = try pancake.driver.connect(
    allocator,
    &.{tcp_resident.netlayer()},
    partner,
    .ephemeral,
    .{},
);
defer session.deinit();

const greeter = try session.fetch("greeter"); // a capability, by name
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try session.call(greeter, .{
    .verb = "greet",
    .args = &.{.{ .string = "world" }},
}, arena.allocator());
switch (settled) {
    .fulfilled => |arg| std.debug.print("{s}\n", .{arg.string}),
    .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
    // The third outcome: an introduction to a capability on another peer,
    // which a `driver.Bridge` + Host redeems for you. This greeter never sends one.
    .give => {},
}
```

`zig build examples` and `meta-check` hold this snippet identical to
[`examples/zig/readme_quick_start.zig`](examples/zig/readme_quick_start.zig).
Both halves live in
[`01_connect_and_serve.zig`](examples/zig/01_connect_and_serve.zig). For C,
read [`docs/consuming-from-c.md`](docs/consuming-from-c.md); for the language
bindings, [`bindings/`](bindings/README.md); for chapters and demos,
[`examples/README.md`](examples/README.md).

## Design posture

The core does no I/O; adapters own it. Session state is authoritative, and
every wire-path cost is forbidden, named, or measured. The evidence lives in
[`docs/architecture.md`](docs/architecture.md),
[`docs/vision.md`](docs/vision.md), and
[`docs/community-review.md`](docs/community-review.md).

## Status

[shipped](docs/shipped.md) · [boundaries](docs/boundaries.md) ·
[ladder](docs/ladder.md) · [community-review](docs/community-review.md)

## Build

```sh
zig build          # C ABI archives + headers + pancake CLI (+ thin rooms-peer shim)
zig build check    # full in-tree check: tests, examples, reference fixtures, budgets
zig build pancake  # run the CapTP CLI; pass `-- help` / `-- ocapn …` / `-- mcp`
```

Put the CLI on your `PATH` (`export PATH="$PWD/zig-out/bin:$PATH"`), then call a
capability from your shell, script CapTP with `--json`, or drop pancake into an
agent via MCP: [`docs/cli.md`](docs/cli.md).

Focused steps while iterating:

```sh
zig build test
zig build test -Dtest-filter=substring   # only tests whose names match
zig build examples
zig build bindings        # rust + deno + bun + python + racket C ABI smokes
zig build oracle-check    # protocol reference fixtures + Syrup fixture parity
zig build meta-check      # documented build steps, overlays, and doc registry
```

Live interop, conformance, benchmarks, demos, and header regeneration need extra
runtimes on PATH. See [`CONTRIBUTING.md`](CONTRIBUTING.md#verifying-changes) for
the contributor verification workflow.

## Documentation

- [`docs/capabilities.md`](docs/capabilities.md): capabilities, CapTP, and
  OCapN from zero, plus the glossary.
- [`docs/consuming-from-c.md`](docs/consuming-from-c.md): build, link,
  ownership rules, first complete C program.
- [`docs/cli.md`](docs/cli.md): installable CapTP CLI walkthrough (listen, call,
  REPL, MCP).
- [`docs/architecture.md`](docs/architecture.md): layers, memory, and the C ABI
  contract.
- [`docs/protocol-diagrams/`](docs/protocol-diagrams/README.md): the living
  CapTP diagrams.
- [`docs/shipped.md`](docs/shipped.md) and
  [`docs/boundaries.md`](docs/boundaries.md): what exists and where it ends.
- [`docs/community-review.md`](docs/community-review.md): interop target, evidence
  matrix, and divergences for an external protocol read.
- [`docs/decisions/`](docs/decisions/README.md): the accepted decision records.
- [`SECURITY.md`](SECURITY.md): vulnerability reporting and the invariants a
  report may cite.

## License

Licensed under [Apache-2.0](LICENSE-APACHE). Contributions are accepted under the same terms.
