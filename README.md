# pancake

<img src="assets/pancake-icon-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)
[![checks](https://github.com/jimisaacs/pancake/actions/workflows/check.yml/badge.svg)](https://github.com/jimisaacs/pancake/actions/workflows/check.yml)

> **pancake is a codec-neutral [CapTP](http://erights.org/elib/distrib/captp/)
> core for [OCapN](https://github.com/ocapn/ocapn).** It speaks Syrup where
> OCapN requires it, and every frame crossing a boundary is either owned or
> borrowed, never ambiguously both. Because you can't have pancakes without
> syrup.

<br clear="left" />

## What is this?

pancake lets two programs pass each other references to objects and call
methods on them across a session, with the same authority rules as a local
call. A peer can call only the references it has been handed, and it cannot
construct one it was not given, so there is no ambient authority to fall back
on. Confidentiality and integrity stay the netlayer's job. Plain TCP is
cleartext; iroh is encrypted.

It is a Zig library for OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. You
link it and manage its memory yourself. Every copy, every allocation, the wire
format in play, and where I/O and scheduling live stay visible at the boundary
that owns them.

New to capabilities, CapTP, or OCapN? Start with
[`docs/capabilities.md`](docs/capabilities.md).

## Does it actually speak the protocol?

Run it and see. Two of these three are someone else's code:

```sh
zig build ocapn-conformance  # the upstream OCapN suite, against a pancake peer
zig build goblins-interop    # a live conversation with a real Goblins vat, both ways
zig build check              # the in-tree checks: tests, examples, budgets, fixtures
```

One-time setup: `bash conformance/bootstrap-submodules.sh`, plus `uv` for the
suite and Racket with the Goblins collection for the live peer. The devcontainer
has both. The first command runs the
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite), pinned as a git
submodule. The second holds a real session with
[Spritely Goblins](https://spritely.institute/goblins/), the implementation
pancake is measured against; `goblins-handoff` and `goblins-gift` add three-party
handoff as gifter and as recipient.

[`docs/community-review.md`](docs/community-review.md) is the full matrix, including
what each check does **not** prove. [`PROVENANCE.md`](PROVENANCE.md) says how this
project is built.

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

This URL may move. pancake falls within Codeberg's rule against projects mostly
written by generative-AI tools ([`PROVENANCE.md`](PROVENANCE.md) says so
plainly), so a consumer should expect the origin to change. There are no
release tags yet, which means the URL above tracks a branch that moves under
you. Until there is a tag to pin, fetch a specific commit:

```sh
zig fetch --save git+https://codeberg.org/jimisaacs/pancake#<commit-sha>
```

```zig
const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pancake", pancake.module("pancake"));
```

```zig
const std = @import("std");
const pancake = @import("pancake");

// tcp: the peer is a place. Its name, a cleartext `host:port`, is called the
// "designator", and `tcp.at` wraps that name as a dialable locator. The slice
// names the transports this client can reach.
var tcp_resident = pancake.net.tcp.Resident{ .io = io };
const partner = pancake.net.tcp.at(designator);

const session = try pancake.driver.connect(
    allocator,
    &.{tcp_resident.netlayer()},
    partner,
    .ephemeral,
    // Both budgets default to 0, which means "wait forever". A silent or
    // unreachable peer would park this program with no way out, so a
    // client always passes finite ones.
    .{ .handshake_timeout_ms = 10_000, .settle_timeout_ms = 10_000 },
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
    // The third outcome: an introduction to a capability on another peer.
    // A Host presents it there and hands you the live result. This greeter never sends one.
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

The core is synchronous and does no I/O; adapters own sockets and scheduling.
Session state, not the codec, decides whether a reference is valid.
[`docs/architecture.md`](docs/architecture.md) is where those boundaries are
argued, and [`docs/shipped.md`](docs/shipped.md) is what holds today.

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
- [`docs/stability.md`](docs/stability.md): a support tier for every transport,
  binding, and codec, set by what proves it and how often.
- [`docs/community-review.md`](docs/community-review.md): interop target, evidence
  matrix, and divergences for an external protocol read.
- [`docs/decisions/`](docs/decisions/README.md): the accepted decision records.
- [`SECURITY.md`](SECURITY.md): vulnerability reporting and the invariants a
  report may cite.
- [`PROVENANCE.md`](PROVENANCE.md): how this project is built, and how to check
  its claims without taking anyone's word for them.

## License

Pancake-authored work is licensed under [Apache-2.0](LICENSE-APACHE). The copied Zig test runner is
MIT-only; [third-party notices](LICENSE-THIRD-PARTY) record its scope and
license. Contributions are accepted under pancake's Apache-2.0 terms.
