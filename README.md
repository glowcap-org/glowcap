# glowcap

<img src="site/assets/glowcap-lit-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)
[![checks](https://github.com/glowcap-org/glowcap/actions/workflows/check.yml/badge.svg)](https://github.com/glowcap-org/glowcap/actions/workflows/check.yml)

glowcap is a low-level Zig library for capability-based communication and
durable application state. It combines [OCapN](https://github.com/ocapn/ocapn)
and CapTP networking with [Loam](docs/loam.md), its transactional storage and
durable actor system. Applications control memory, I/O, and scheduling.

**0.1.0 alpha · Apache-2.0.** Public APIs, ABIs, and storage formats can
change before 1.0. glowcap has not received an independent security audit.
Read [what ships](docs/shipped.md) and the [known limitations](docs/boundaries.md)
before depending on it.

A capability is a reference that gives its holder access to an object.
OCapN lets programs pass those references and call methods across a network.
Loam stores object state and relationships, wakes actors on demand, and
provides durable names that peers can use after a restart. If capabilities
are new to you, [the introduction](docs/capabilities.md) explains the model.

<br clear="left" />

glowcap is built with AI coding assistants. The maintainer directs the work
and is answerable for what lands. [How glowcap is built](PROVENANCE.md)
explains the assistance, verification, and upstream policies.
[Contributions](CONTRIBUTING.md) are welcome with or without AI tools.

The Zig API distinguishes owned frames from borrowed views and takes explicit
allocators. The protocol core is synchronous and does no I/O. Sessions speak
[CapTP](https://web.archive.org/web/20250114141521/http://erights.org/elib/distrib/captp/),
OCapN's session protocol, and encode it in [Syrup](https://github.com/ocapn/syrup), OCapN's canonical
format.

For an encrypted session, use [iroh](https://www.iroh.computer/), which is
QUIC with peer discovery, or `noise-tcp`, which is TCP that proves you reached
the key you dialed. Spritely Goblins, as it ships, talks to glowcap over Tor onion services.
[Choosing a transport](https://glowcap.org/transports/choosing/)
lists the rest. Plain `tcp` is a testing transport, cleartext with no identity
proof.

Applications can opt into Loam to keep state in atomic records backed by
SQLite, LMDB, or memory. Durable actors can sleep outside memory,
and transactions save their state before a reply is sent. Loam also models
access, delegation, and revocation.

Build checks hold selected allocation, copy, and state-size budgets.
[Performance measurements](https://glowcap.org/performance/) report protocol,
transport, binding, and Loam costs with their workloads and methods.

## Quick start

### Try a local conversation

From a [working checkout](CONTRIBUTING.md#get-a-working-checkout), run:

```sh
zig build examples --summary all
```

The examples start their own peers. Chapter 01 publishes a greeter, connects
over encrypted TCP, and checks its reply. Chapter 02 adds an introduction
between three peers. The build summary shows which examples passed.
[The example guide](examples/README.md) links each program.

### Use glowcap in your program

```sh
zig fetch --save git+https://github.com/glowcap-org/glowcap#COMMIT_SHA
```

Replace `COMMIT_SHA` with the revision you want to pin. In your `build.zig`:

```zig
const glowcap = b.dependency("glowcap", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("glowcap", glowcap.module("glowcap"));
```

Then dial a peer over `noise-tcp`, fetch a capability by name, and call it. The
caller supplies `io`, `allocator`, the peer's public key, and its `host:port`
address. The complete program is
[`examples/zig/readme_quick_start.zig`](examples/zig/readme_quick_start.zig).

```zig
const std = @import("std");
const glowcap = @import("glowcap");

// Noise_XK seals the CapTP stream and proves the dialed key.
var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
const partner = glowcap.net.tcp.noise.locator(peer_key, address, &hint_storage);

const session = try glowcap.driver.connect(
    allocator,
    io,
    .{ .symbols = &.{.noise_tcp} },
    partner,
    .ephemeral,
    // Time limits for opening the session and for each answer.
    .{
        .handshake = glowcap.driver.default_handshake_budget,
        .settle = glowcap.driver.default_settle_budget,
    },
);
defer session.deinit();

const greeter = try session.fetch("greeter"); // a capability this peer published
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try session.call(greeter, "greet", &.{.{ .string = "world" }}, arena.allocator());
switch (settled) {
    .fulfilled => |value| std.debug.print("{s}\n", .{value.string}),
    .broken => |reason| {
        std.debug.print("the greeter refused: {s}\n", .{reason});
        return error.GreeterRefused;
    },
}
```

`fetch` asks the peer's bootstrap object for a name that side published.
[Start building](https://glowcap.org/start/) shows the
listening side of this exchange and the same program in other languages.

### The command line and Rooms

`zig build` puts the `glowcap` CLI in `zig-out/bin`.
[`docs/cli.md`](docs/cli.md) covers its REPL, `--json` scripting, the MCP
server, and a cleartext round-trip for local experiments.

Rooms is a chat application built on glowcap, and
[installing glowcap](apps/rooms/host.md) installs it too.
`glowcap apps rooms serve` starts the browser app, and
`glowcap apps rooms session join` joins a room over encrypted iroh.

To install from a checkout, run `./glowcap install`. It builds the product,
checks its file list, and installs it outside the checkout. `zig build rooms-build` stages the same files under `zig-out/product`
without installing them.

### Examples and other languages

[`examples/README.md`](examples/README.md) starts with chapter 01, which is this
fetch-and-call as a complete program. C consumers start at
[`docs/consuming-from-c.md`](docs/consuming-from-c.md).
The Rust, TypeScript, Python, and Racket bindings live in
[`bindings/`](bindings/README.md).

## Conformance

The interoperability checks use the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite) and live sessions
with [Spritely Goblins](https://spritely.institute/goblins/) over TCP.
The baseline is CapTP 1.0 encoded in Syrup:

```sh
zig build ocapn-conformance  # the upstream OCapN test suite, against a glowcap peer
```

[Community review](docs/community-review.md) lists outside-peer checks, what
each proves, and what each needs to run. [Stability](docs/stability.md) explains
which checks run in CI.

<p align="center">
  <img src="site/assets/glowcap-goblin-512.png" alt="a purple goblin studying the glowcap mark" width="320" />
</p>

## Build

The Zig version and every other toolchain are pinned, and
[dependencies](docs/dependencies.md) lists them.

```sh
zig build          # C ABI archives + headers + the glowcap CLI
zig build check    # in-process tests, static checks, examples, fixtures, budgets
zig build runtime-check # process, application, and language-workspace checks
```

To contribute, start with [a working checkout](CONTRIBUTING.md#get-a-working-checkout),
then [make a change](CONTRIBUTING.md#make-a-change) and open a pull request.

## Documentation

The [website](https://glowcap.org/) is the primary guide. For
a live preview of the hand-written pages, run `zig build docs-serve` and open
the address it prints. `zig build site` builds the whole site under
`zig-out/site/`, including the API reference.

Reference pages:

- [What ships](docs/shipped.md) lists the usable APIs and transports.
- [Known limitations](docs/boundaries.md) lists deployment and API constraints.
- [Stability](docs/stability.md) lists what is checked for each area and what is still open.
- [Threat model](docs/threat-model.md) says who glowcap defends against and how it handles untrusted input.
- [Architecture](docs/architecture.md) explains the layers.
- [Dependencies](docs/dependencies.md) lists what glowcap builds on.
- [Capabilities](docs/capabilities.md) is the glossary when the ideas are new.
- [The roadmap](docs/roadmap.md) lists the work that remains.

The [protocol diagrams](docs/protocol-diagrams/README.md) draw each message
flow, and the [decision records](docs/decisions/README.md) explain why each
design was chosen.
[SECURITY.md](SECURITY.md) explains how to report a vulnerability.

## Corporate sponsorship

Glowcap LLC maintains glowcap. [Sponsor Glowcap LLC through GitHub Sponsors](https://github.com/sponsors/glowcap-org)
to support development of capability networking, Loam transactional storage,
and durable actors in Zig.

Corporate sponsorship funds implementation, interoperability testing,
performance measurement, documentation, and maintenance.

## License

Copyright 2026 Glowcap LLC

Glowcap-authored work is licensed under [Apache-2.0](LICENSE-APACHE).
Third-party files keep their original terms. The
[third-party notices](LICENSE-THIRD-PARTY) record their scope and licenses. Contributions are accepted under glowcap's Apache-2.0 terms.
