# glowcap

<img src="site/assets/glowcap-lit-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)
[![checks](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml/badge.svg)](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml)

glowcap is a Zig implementation of [OCapN](https://github.com/ocapn/ocapn), the
object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. Two
programs hand each other references to objects and call methods on them across
a network, under the same rules as a local call: a peer can use the references
it was given and cannot forge others. If capabilities are new to you,
[`docs/capabilities.md`](docs/capabilities.md) starts from zero, and
[What about identity?](https://jimisaacs.github.io/glowcap/identity/) covers where people, bots,
and AI agents fit.

<br clear="left" />

glowcap is built with AI coding assistants. The maintainer directs the work
and is answerable for what lands. [`PROVENANCE.md`](PROVENANCE.md) records
how, and why glowcap sends no generated reports or patches to projects that
refuse them.

You link glowcap into your program and own its memory, and the Zig API names
each place a frame is copied, allocated, or borrowed. The protocol
core is synchronous and does no I/O, so sockets, scheduling, and encryption
live in the transport adapters. Sessions speak
[CapTP](https://web.archive.org/web/20250114141521/http://erights.org/elib/distrib/captp/),
OCapN's session protocol, and encode it in [Syrup](https://github.com/ocapn/syrup), OCapN's canonical
format.

For an encrypted session, use [iroh](https://www.iroh.computer/), which is
QUIC with peer discovery, or `noise-tcp`, which is TCP that proves you reached
the key you dialed. Spritely Goblins, as it ships, talks to glowcap over Tor onion services.
[Choosing a transport](https://jimisaacs.github.io/glowcap/transports/choosing/)
lists the rest. Plain `tcp` is a testing transport, cleartext with no identity
proof.

[Loam](docs/loam.md) keeps an application's state in atomic records, on SQLite
or LMDB, or in memory. An actor can sleep in a record and wake when a message arrives,
and the references peers hold to it stay valid in between. Loam can also track
who has access to what and revoke it.

There are no releases or compatibility guarantees. Pin a commit, and read
[what ships](docs/shipped.md) and the [known limitations](docs/boundaries.md)
before depending on it.

## Quick start

```sh
zig fetch --save git+https://github.com/jimisaacs/glowcap#COMMIT_SHA
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
[Start building](https://jimisaacs.github.io/glowcap/start/) shows the
listening side of this exchange and the same program in other languages.

### The command line and Rooms

`zig build` puts the `glowcap` CLI in `zig-out/bin`.
[`docs/cli.md`](docs/cli.md) covers its REPL, `--json` scripting, the MCP
server, and a cleartext round-trip for local experiments.

Rooms is a chat application built on glowcap, and
[installing glowcap](apps/rooms/host.md) installs it too.
`glowcap apps rooms serve` starts the browser app, and
`glowcap apps rooms session` joins a room over encrypted iroh.

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

The checks for `main` and `dev` pushes include the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite) and live sessions
with [Spritely Goblins](https://spritely.institute/goblins/) over TCP.
Additional iroh and Tor checks run on demand. Check the successful run for the
commit you intend to use. The baseline is CapTP 1.0 encoded in Syrup:

```sh
zig build ocapn-conformance  # the upstream OCapN test suite, against a glowcap peer
```

[Community review](docs/community-review.md) lists every live check, what
each proves, and what each needs to run.

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

The [website](https://jimisaacs.github.io/glowcap/) is the primary guide. For
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

## License

Glowcap-authored work is licensed under [Apache-2.0](LICENSE-APACHE). Third-party files keep their
original terms. The [third-party notices](LICENSE-THIRD-PARTY) record their scope
and licenses. Contributions are accepted under glowcap's Apache-2.0 terms.
