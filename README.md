# glowcap

<img src="site/assets/glowcap-lit-256.png" alt="" align="left" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)
[![checks](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml/badge.svg)](https://github.com/jimisaacs/glowcap/actions/workflows/check.yml)

glowcap is a Zig implementation of [OCapN](https://github.com/ocapn/ocapn), the
object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community. Two
programs hand each other references to objects and call methods on them across
a session, under the same rules as a local call: a peer can use the references
it was given and cannot forge others, so there is no ambient authority.

<br clear="left" />

The session protocol is [CapTP](https://web.archive.org/web/20250114141521/http://erights.org/elib/distrib/captp/). The
core is codec-neutral, and on the wire it speaks
[Syrup](https://github.com/ocapn/syrup), OCapN's canonical encoding.

It is a library, not a framework. You link it and manage its memory. The
protocol core is synchronous and does no I/O of its own. Sockets, scheduling,
and encryption belong to the transport adapters.

[Loam](docs/loam.md) is the storage layer. It provides atomic records, bounded
leases, immutable collections, and an optional LMDB backend. An actor can keep
its state in a record and load it only when a message arrives, and the
references other peers hold to it stay valid while it sleeps. Loam also manages
resources and grants. The full API is in Zig. C and Rust get a smaller profile,
and the Rust one also runs in the browser on IndexedDB. Building Rooms on Loam
is still planned work,
described in the [application foundation plans](docs/planning/README.md).
[What ships](docs/shipped.md) separates those plans from the library you can
use today.

glowcap is built with AI coding assistants. The maintainer directs the work
and is answerable for what lands.
[`PROVENANCE.md`](PROVENANCE.md) records how, including the upstream-contact
limits that follow.

Two transports are the usual way to connect glowcap peers.
[iroh](https://www.iroh.computer/) is encrypted QUIC with peer discovery.
`noise-tcp` is encrypted TCP that proves you reached the key you dialed.
WebRTC, `noise-relay`, and onion encrypt too. See
[Choosing a transport](https://jimisaacs.github.io/glowcap/transports/choosing/)
for the full list.
To meet unmodified Goblins, glowcap uses Tor onion services; that check runs on
demand rather than on every build. Plain `tcp` is a testing transport. It is
cleartext with no identity proof, and the regular Goblins interop suite runs
over it. [Known limitations](docs/boundaries.md) says exactly what each
transport proves.

Every place a frame is copied, allocated, or borrowed is visible in the API.

If capabilities are new to you,
[`docs/capabilities.md`](docs/capabilities.md) starts from zero and carries
the glossary.

There are no releases or compatibility guarantees yet. Pin a commit, and read
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

Then dial a peer over `noise-tcp`, fetch a capability by name, and call it.
This is the body of a function whose caller supplies `io`, `allocator`, the
peer's durable key, and the `host:port` hint; the compilable whole is
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
    // Never leave a network wait unbounded.
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

`fetch` asks the peer's bootstrap object for a name that side published. A peer
that never published `"greeter"` cannot be fetched that way.

[Start building](https://jimisaacs.github.io/glowcap/start/) shows the
listening side of this exchange and the same program in other languages.

### The command line and Rooms

`zig build` puts the `glowcap` CLI in `zig-out/bin`.
[`docs/cli.md`](docs/cli.md) covers its REPL, `--json` scripting, the MCP
server, and a cleartext round-trip for local experiments.

Rooms is a chat application built on glowcap, and the
[complete host installation](apps/rooms/host.md) includes it.
`glowcap apps rooms serve` starts the browser app, and
`glowcap apps rooms session` joins a room over encrypted iroh.

To install from a checkout, run `./glowcap install`. It builds and verifies
the product, then installs it outside the checkout. An installed CLI never
builds source. `zig build rooms-build` stages the same installation under
`zig-out/product` without installing it.

### Examples and other languages

[`examples/README.md`](examples/README.md) begins with the Rooms app. Its
chapter 01 walks through the same fetch-and-call over loopback TCP. C
consumers start at [`docs/consuming-from-c.md`](docs/consuming-from-c.md).
The Rust, TypeScript, Python, and Racket bindings live in
[`bindings/`](bindings/README.md).

## Conformance

glowcap is tested against the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite) and holds live
sessions with Goblins. The suite checks signed CapTP 1.0 over Syrup on every
regular run:

```sh
zig build ocapn-conformance  # the upstream OCapN test suite, against a glowcap peer
```

Goblins peers normally meet over Tor. That check needs a Tor daemon, so it
runs on demand and not on every build:

```sh
zig build goblins-onion      # live Goblins over the upstream onion netlayer
```

The regular Goblins check uses this repository's cleartext TCP adapter
instead:

```sh
zig build goblins-interop    # live Goblins over cleartext TCP
```

Goblins also meets glowcap over iroh, through a Goblins adapter kept in this
repository. The recurring checks run a three-party handoff over iroh, and a
plain session runs on demand:

```sh
zig build goblins-handoff-iroh   # recurring: Goblins handoff over iroh
zig build goblins-iroh           # on demand: live Goblins session over iroh
```

Set up the submodules once with `bash conformance/bootstrap-submodules.sh`.
The suite needs `uv`, and the live peer needs Racket with the Goblins
collection; the devcontainer has both.
[`docs/community-review.md`](docs/community-review.md) lists the OCapN and
Goblins evidence and says what each check proves and what it does not.

<p align="center">
  <img src="site/assets/glowcap-goblin-512.png" alt="a purple goblin studying the glowcap mark" width="320" />
</p>

## Build

glowcap builds with Zig 0.17. `build.zig.zon` pins the exact minimum, and
[`.devcontainer/pins.sh`](.devcontainer/pins.sh) pins every other toolchain.

```sh
zig build          # C ABI archives + headers + the glowcap CLI
zig build check    # in-process tests, static checks, examples, fixtures, budgets
zig build runtime-check # process, application, and language-workspace checks
zig build test -Dtest-filter=substring   # just the tests whose names match
```

`zig build --help` lists the focused steps. The live interop runs, benchmarks,
demos, and header regeneration need extra runtimes on PATH;
[`CONTRIBUTING.md`](CONTRIBUTING.md#verifying-changes) has the verification
workflow.

## Documentation

The [website](https://jimisaacs.github.io/glowcap/) is the primary guide. For
a local preview, run `zig build docs-serve` and open
`http://127.0.0.1:1990/glowcap/`. Inside the devcontainer the server listens
on every interface, so the host port (`GLOWCAP_DOCS_HOST_PORT`, 1990 on the
primary checkout) reaches it.

The preview shows only the hand-written pages, and it reloads them as you
edit. `zig build site` produces everything else under `zig-out/site/`: the API
reference, `sitemap.xml`, and the files written for programs (`llms.txt`,
`llms-full.txt`, and an `index.md` copy of each page). Serve that directory
with any static file server to check them.

These pages must match the code as it is today:

- [What ships](docs/shipped.md) lists the usable APIs and transports.
- [Known limitations](docs/boundaries.md) lists deployment and API constraints.
- [Stability](docs/stability.md) says what recurring evidence supports them.
- [Architecture](docs/architecture.md) explains the layers.
- [Capabilities](docs/capabilities.md) is the glossary when the ideas are new.
- [The roadmap](docs/roadmap.md) lists the work that remains.

The [protocol diagrams](docs/protocol-diagrams/README.md) and
[decision records](docs/decisions/README.md) carry the deeper detail.
[SECURITY.md](SECURITY.md) explains how to report a vulnerability.

## License

Glowcap-authored work is licensed under [Apache-2.0](LICENSE-APACHE). Third-party files keep their
original terms; [third-party notices](LICENSE-THIRD-PARTY) record their scope
and licenses. Contributions are accepted under glowcap's Apache-2.0 terms.
