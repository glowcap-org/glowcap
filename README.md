# pancake

<img src="assets/pancake-icon-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)
[![checks](https://github.com/jimisaacs/pancake/actions/workflows/check.yml/badge.svg)](https://github.com/jimisaacs/pancake/actions/workflows/check.yml)

pancake is a Zig implementation of [OCapN](https://github.com/ocapn/ocapn), the
object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. Two
programs hand each other references to objects and call methods on them across
a session, under the same rules as a local call: a peer can use the references
it was given and cannot forge others, so there is no ambient authority.

<br clear="left" />

The session protocol is [CapTP](http://erights.org/elib/distrib/captp/). The
core is codec-neutral, and on the wire it speaks
[Syrup](https://github.com/ocapn/syrup), OCapN's canonical encoding, which is
where the name comes from: you can't have pancakes without syrup.

It is a library, not a framework. You link it and manage its memory. The
protocol core is synchronous and does no I/O of its own; sockets, scheduling,
and encryption belong to the transport adapters. The plain TCP transport below
is cleartext and authenticates nobody, so use it to learn the API and for
cleartext testing against
[Spritely Goblins](https://spritely.institute/goblins/). For unmodified Goblins
over Tor, use onion; [iroh](https://www.iroh.computer/) carries the same
sessions over encrypted QUIC.
[`docs/boundaries.md`](docs/boundaries.md) says what each transport proves.
Every place a frame is copied, allocated, or borrowed is visible in the API.

If capabilities are new to you,
[`docs/capabilities.md`](docs/capabilities.md) starts from zero and carries
the glossary.

There are no releases or compatibility guarantees yet. Pin a commit, and read
[what ships](docs/shipped.md) and the [known limitations](docs/boundaries.md)
before depending on it.

## Quick start

```sh
zig fetch --save git+https://github.com/jimisaacs/pancake#COMMIT_SHA
```

Replace `COMMIT_SHA` with the revision you want to pin. In your `build.zig`:

```zig
const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pancake", pancake.module("pancake"));
```

Then dial a peer, fetch a capability by name, and call it. This is the body of
a function whose caller supplies `io`, `allocator`, and `designator`, the
peer's `host:port`; the compilable whole is
[`examples/zig/readme_quick_start.zig`](examples/zig/readme_quick_start.zig).

```zig
const std = @import("std");
const pancake = @import("pancake");

// Plain TCP uses a cleartext `host:port` locator.
var tcp_resident = pancake.net.tcp.Resident{ .io = io };
const partner = pancake.net.tcp.at(designator);

const session = try pancake.driver.connect(
    allocator,
    &.{tcp_resident.netlayer()},
    partner,
    .ephemeral,
    // Never leave a network wait unbounded.
    .{ .handshake = .{ .ms = 10_000 }, .settle = .{ .ms = 10_000 } },
);
defer session.deinit();

const greeter = try session.fetch("greeter"); // an opaque capability, by name
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
switch (settled) {
    .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
    .broken => |reason| std.debug.print("the greeter refused: {s}\n", .{reason}),
}
```

For a live peer to dial, `zig build` puts the `pancake` CLI in `zig-out/bin`,
and `pancake ocapn listen --publish greeter` serves the same greeter this
client fetches and prints its locator. [`docs/cli.md`](docs/cli.md) covers the
CLI, including the REPL, `--json` scripting, and MCP.

Both halves of the conversation are in
[`examples/zig/01_connect_and_serve.zig`](examples/zig/01_connect_and_serve.zig),
and [`examples/README.md`](examples/README.md) lists the rest of the chapters
and demos. The longer walkthrough, covering iroh, C, and the language
bindings, is [`site/content/start.smd`](site/content/start.smd); read it
rendered with `zig build docs-serve`. C consumers start at
[`docs/consuming-from-c.md`](docs/consuming-from-c.md), and the Rust,
TypeScript, Python, and Racket bindings live in
[`bindings/`](bindings/README.md).

## Conformance

pancake is tested against the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite) and holds live
sessions with [Spritely Goblins](https://spritely.institute/goblins/):

```sh
zig build ocapn-conformance  # the upstream OCapN test suite, against a pancake peer
zig build goblins-interop    # live Goblins over cleartext TCP (repo testing adapter)
zig build goblins-iroh       # live Goblins over iroh (repo adapter; needs cargo)
zig build goblins-onion      # live Goblins over Tor (upstream onion netlayer; needs tor)
```

Set up the submodules once with `bash conformance/bootstrap-submodules.sh`.
The suite needs `uv`, and the live peer needs Racket with the Goblins
collection; the devcontainer has both.
[`docs/community-review.md`](docs/community-review.md) lists every interop
check and what each one does and does not prove.
[`PROVENANCE.md`](PROVENANCE.md) describes how this project is built,
including its use of generative-AI tools.

<p align="center">
  <img src="assets/pancake-goblin-512.png" alt="a purple goblin studying a smiling stack of pancakes" width="320" />
</p>

## Build

pancake builds with Zig 0.16.0. `build.zig.zon` pins the minimum, and
[`.devcontainer/pins.sh`](.devcontainer/pins.sh) pins every other toolchain.

```sh
zig build          # C ABI archives + headers + the pancake CLI
zig build check    # the full in-tree check: tests, examples, fixtures, budgets
zig build test -Dtest-filter=substring   # just the tests whose names match
```

`zig build --help` lists the focused steps. The live interop runs, benchmarks,
demos, and header regeneration need extra runtimes on PATH;
[`CONTRIBUTING.md`](CONTRIBUTING.md#verifying-changes) has the verification
workflow.

## Documentation

The website is the front door. Run `zig build docs-serve` and open
`http://127.0.0.1:1990/pancake/` for Why OCapN, Start building, transports,
bindings, and the rest of the guided path.

Docs kept in step with today's code own the inventory:

- [What ships](docs/shipped.md) lists the usable surfaces.
- [Known limitations](docs/boundaries.md) lists deployment and API constraints.
- [Stability](docs/stability.md) says what recurring evidence supports them.
- [Architecture](docs/architecture.md) explains the layers.
- [Capabilities](docs/capabilities.md) is the glossary when the ideas are new.
- [The roadmap](docs/roadmap.md) lists the work that remains.

The [protocol diagrams](docs/protocol-diagrams/README.md) and
[decision records](docs/decisions/README.md) carry the deeper detail.
[SECURITY.md](SECURITY.md) explains how to report a vulnerability.

## License

Pancake-authored work is licensed under [Apache-2.0](LICENSE-APACHE). The copied Zig test runner is
MIT-only; [third-party notices](LICENSE-THIRD-PARTY) record its scope and
license. Contributions are accepted under pancake's Apache-2.0 terms.
