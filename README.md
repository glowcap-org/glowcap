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
protocol core is synchronous and does no I/O of its own; sockets, scheduling,
and encryption belong to the transport adapters.

glowcap is built with AI coding assistants. The maintainer directs the work
and is answerable for what lands.
[`PROVENANCE.md`](PROVENANCE.md) records how, including the upstream-contact
limits that follow.

[iroh](https://www.iroh.computer/) and `noise-tcp` are glowcap-to-glowcap
paths: encrypted QUIC with discovery, and a sealed TCP route that proves the
dialed key. Unmodified Goblins over Tor uses onion; that meeting is on demand.
Plain `tcp` is a testing transport: cleartext, no identity proof, used for the
recurring Goblins TCP suite. [`docs/boundaries.md`](docs/boundaries.md) says
what each transport proves. Every place a frame is copied, allocated, or
borrowed is visible in the API.

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
var noise_resident = glowcap.net.tcp.noise.Resident{ .io = io };
const netlayers = [_]glowcap.net.netlayer.Netlayer{noise_resident.netlayer()};
var hint_storage: [1]glowcap.ocapn.model.HintEntry = undefined;
const partner = glowcap.net.tcp.noise.locator(peer_key, address, &hint_storage);

const session = try glowcap.driver.connect(
    allocator,
    &netlayers,
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

[Start building](https://jimisaacs.github.io/glowcap/start/) is the listen half
and the other languages. `zig build` puts the `glowcap` CLI in `zig-out/bin`;
`glowcap app rooms-peer` is an encrypted conversation over iroh.
[`docs/cli.md`](docs/cli.md) covers the REPL, `--json` scripting, MCP, and the
cleartext lab round-trip.

[`examples/README.md`](examples/README.md) starts at the rooms app.
Chapter 01 is the loopback TCP walk of the same fetch-and-call. C consumers start at
[`docs/consuming-from-c.md`](docs/consuming-from-c.md), and the Rust,
TypeScript, Python, and Racket bindings live in
[`bindings/`](bindings/README.md).

## Conformance

glowcap is tested against the upstream
[OCapN test suite](https://github.com/ocapn/ocapn-test-suite) and holds live
sessions with Goblins. The recurring outside claim is signed CapTP 1.0 over
Syrup:

```sh
zig build ocapn-conformance  # the upstream OCapN test suite, against a glowcap peer
```

The standardized Goblins meeting is Tor. That step needs a daemon and is not
in the recurring set:

```sh
zig build goblins-onion      # live Goblins over the upstream onion netlayer
```

The recurring Goblins check uses this repository's cleartext TCP adapter:

```sh
zig build goblins-interop    # live Goblins over cleartext TCP
```

On demand, a repository iroh adapter:

```sh
zig build goblins-iroh       # live Goblins over iroh (needs cargo)
```

Set up the submodules once with `bash conformance/bootstrap-submodules.sh`.
The suite needs `uv`, and the live peer needs Racket with the Goblins
collection; the devcontainer has both.
[`docs/community-review.md`](docs/community-review.md) maps the OCapN and
Goblins evidence and says what each listed check does and does not prove.

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
`http://127.0.0.1:1990/glowcap/`. In the devcontainer that process binds every
interface so the published host port (`GLOWCAP_DOCS_HOST_PORT`, 1990 on the
primary checkout) reaches it.

That preview renders the authored pages and reloads them as you edit, and it
is all it renders. The generated API reference, `sitemap.xml`, and the three
surfaces written for programs, `llms.txt`, `llms-full.txt`, and each page's
`index.md` twin, are produced by `zig build site` under `zig-out/site/`; serve
that directory with any static file server to check them locally.

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
