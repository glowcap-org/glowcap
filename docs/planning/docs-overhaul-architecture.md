# Documentation architecture — stage two of the docs overhaul

Status: historical snapshot. This file recorded the design for the
documentation reorganization: the information architecture, the authoritative
home for every duplicated topic, the disposition of every current README
section, and the README draft. Stage three has since landed — the README is
trimmed to a front door, `docs/shipped.md` and `docs/boundaries.md` carry the
moved inventory, and `zig build site` builds the Zine site with the autodoc
reference installed under `reference/api`. The design below is the record of
what was planned, not a description of the current tree.

One stage-three item shipped in a different shape than designed. The "Mermaid
gate" in the build design below — a `mermaid-check` step that parses every
Mermaid block — was not built. The site renders hand-authored SVG diagrams
rather than Mermaid, and `meta-check` instead grew an SVG-ASCII gate
(`checkSiteSvgAscii`) that keeps those SVGs valid XML. The
`docs/protocol-diagrams/**` Mermaid corpus stays, and its parse-validity is
not yet gated.

The audit that fed this design is
[`docs-overhaul-audit.md`](docs-overhaul-audit.md). Its corrective findings
(1–9) were applied to the tree; this plan carried findings 10–12.

## The shape

Four tiers, wearing pancake's vocabulary rather than a framework's. Each tier
answers one kind of question, and a page that tries to answer two kinds gets
split.

**Start** answers "get me to a working program." It is the tutorial tier: the
existing example chapters narrated as a path, one page per language entry
(Zig package, C consumer, each binding). Every code block on a Start page is
machine-checked — the pages wrap programs that `zig build examples` and the
dogfoods already run, which is how the "examples must compile" value extends
to the tutorial tier for free.

**Guides** answer "how do I do this one thing": talk to a live Goblins vat,
run the cross-language demos, choose a codec, choose or write a netlayer,
run the conformance suites, embed the peer in an existing event loop. Each
guide is small, names its prerequisites, and ends when the task does.

**Reference** answers "what exactly is this": the generated Zig API
documentation (autodoc, new in stage three), the annotated `pancake.h`, the
build-step catalog, and the glossary. Reference pages are generated or
mechanically gated wherever possible.

**Understanding** answers "why is it this way": the capabilities on-ramp, the
architecture and its memory story, the protocol diagram corpus, what ships
today and where the boundaries sit, the vision/ladder/roadmap trio, and the
decision records.

## One home per topic

The cure for the audit's duplication finding is an ownership assignment, not
a deletion pass. The rule: the home states the fact; every other surface gets
at most one sentence plus a link.

| Topic | Authoritative home | Everyone else |
| --- | --- | --- |
| Wire-path allocation budget (one alloc per steady-state deliver) | `docs/architecture.md` | vision and ladder keep one sentence each, linking the architecture section and the gating test |
| 500k-session arithmetic and footprint budget | `docs/ladder.md` (it owns the rungs and the numbers) | vision keeps the destination sentence; README drops the number entirely |
| The nine-verb application surface | `bindings/README.md` (it is the cross-language contract) | README cites "nine verbs" with a link; vision links instead of enumerating |
| Layer inventory and ownership | `docs/architecture.md` | README's inventory moves out (disposition below); agent rules keep their terse mirror, which the gate already holds in sync |
| Build-step catalog | `.agents/rules/cli.md` (already the case) | README and CONTRIBUTING keep curated subsets that say they are subsets (already done) |
| Demo descriptions | `examples/README.md` and the per-app READMEs | README keeps the three one-liners |
| Conformance authority statement | `conformance/README.md` | README keeps two sentences and the link |

## Disposition of every README section

"Moved" and "deleted" are different decisions; this table makes each one
explicit. Line numbers refer to the README as of the audit.

| Section (lines) | Decision | Where it lands |
| --- | --- | --- |
| Header, badges, tagline (1–11) | **Keep** | Front door, unchanged. |
| What Is This? (13–26) | **Keep, plus the capabilities link** | Already landed in stage one's fixes. |
| Quick Start (28–76) | **Keep, trimmed** | The fetch command, the snippet, the machine-checked note. The hosting-half paragraph shrinks to one sentence linking chapter 01. |
| Examples (78–143) | **Shrink to ~12 lines** | The chapter list and per-app deep descriptions live in `examples/README.md` (already do); the README keeps the chapter path in one paragraph and the three app one-liners. |
| Vision (145–159) | **Shrink to ~4 lines** | The full argument is `docs/vision.md`; the README states the destination and links vision + ladder. |
| On The Wire Today (161–402) | **Move** | Becomes `docs/shipped.md` ("What ships today"), an Understanding-tier status page, content carried over bullet-for-bullet then edited for voice. Registered living-state automatically (top-level docs gate). The README keeps a six-line summary. Deliberate deletions inside the move: the second nine-verb enumeration (the bindings README owns it), and the demo bullet's repetition of the Examples section (one cross-link instead). |
| Current Boundaries (403–545) | **Move** | Becomes `docs/boundaries.md`, the honest-edges page: netlayer state, codec tradeoff, completion-loop posture, durability, Null. Same registration. The README keeps two sentences. |
| Build & gates (547–587) | **Shrink to ~10 lines** | `zig build`, `check`, artifacts, the consuming-from-c link, the cli.md pointer (subset note already landed). |
| Devcontainer (589–599) | **Move** | Into `CONTRIBUTING.md` as a "Dev environment" section; it is contributor-facing. README drops it. |
| Reference & Conformance (601–628) | **Shrink to ~6 lines** | The authority statement stays (two sentences); the upstream-module detail merges into `conformance/README.md` if not already there; the directory tour is already `conformance/README.md`'s job. |
| Documentation (630–642) | **Keep, grown into the site map** | Already grew in stage one; in stage three the links point into the site sections. |
| License (643–647) | **Keep** | Unchanged. |

## Doc-drift ownership

Every page in the new structure is registered. The living-state registry
already carries (from stage one): the README, CONTRIBUTING, SECURITY, the
docs/ pages including `capabilities.md` and `consuming-from-c.md`, the
diagram corpus glob, the bindings READMEs, `examples/README.md`, and
`.devcontainer/README.md`. Stage three adds `docs/shipped.md` and
`docs/boundaries.md` (enforced automatically by the top-level-docs gate) and
the site content tree under one glob. The new gate from stage one — a
subdirectory doc that declares itself living-state must be covered by a
registry entry — holds the diagram corpus and any future corpus to the same
standard.

## Where the canonical text lives once the site exists

The one real risk in adding a site is a second copy of every page. The
design: **the repository Markdown stays canonical, and the site builds from
it.** Zine's content directory will hold thin SuperMD pages for site-only
surfaces (the front page, section indexes) and the build copies or includes
the canonical docs — it does not fork them. Reader-facing pages keep exactly
one source file each:

- `docs/capabilities.md`, `docs/consuming-from-c.md`, `docs/shipped.md`,
  `docs/boundaries.md`, `docs/architecture.md`, vision/ladder/roadmap — one
  source, rendered into the site's Start/Guides/Understanding sections.
- `docs/protocol-diagrams/**` — one source, rendered under Understanding;
  the Mermaid gate (below) runs on the canonical files.
- The API reference is generated (autodoc), never hand-written.
- ADRs render as-is under Understanding/decisions.

If Zine's SuperMD requires syntax the canonical files cannot carry as plain
Markdown, the resolution is a small build-time transform, never a second
copy. That decision point is named here so stage three cannot drift into
forking content silently.

## Stage-three build design

One command — a new `site` build step — builds the whole public face and fails when
it is broken:

1. **Zine**, pinned in `build.zig.zon` via `zig fetch --save`, wired through
   `build.zig` per Zine's own build-integration documentation. Malformed
   templates and SuperMD fail the build by construction.
2. **Autodoc**: a `docs` step emits Zig's generated documentation for the
   public `pancake` module; `site` consumes the emitted artifact and installs
   it as the reference section. This is the audit's finding 12.
3. **Link gate**: internal links across the site output are checked as part
   of `site` (Zine reports dead internal links; whatever it does not catch,
   the existing `meta-check` relative-link gate already covers for the
   canonical Markdown).
4. **Mermaid gate**: a `mermaid-check` step parses every Mermaid block in
   `docs/protocol-diagrams/**` and fails on a block that does not parse. It
   runs under deno (already a required runtime for the demo gates) so it can
   use the Mermaid project's own parser; the exact harness (mermaid's
   `parse()` against a minimal DOM shim, or the `@mermaid-js/parser` package
   for the diagram types it covers) is an implementation choice inside the
   step, with the acceptance criterion fixed: a malformed block fails
   the `site` step. This is the moment the diagram corpus joins the
   "examples must compile" contract.
5. **Hermeticity posture**: `site` joins the sibling-step family (like
   `bindings` and the demos) rather than the hermetic `check`, because it
   needs deno for the Mermaid gate. The canonical-Markdown gates that protect
   the same content (meta-check links, registry, prerelease language) stay
   inside `check`.

**Deployment, both forges.** The same static output ships two ways: a GitHub
Actions workflow (build with Zig, upload-pages-artifact, deploy-pages) and a
Forgejo workflow for Codeberg Pages (build, push the output to the `pages`
branch). Both wrap the same `site` step invocation the same way the
existing CI wraps `ci/gates.sh` — one artifact, two front doors, zero
divergence.

## The README draft

The full text of the post-overhaul README. Two-minute read. Section targets
from the disposition table; link targets exist today (the two `docs/*.md`
moves land with stage three, and the draft links them). The draft sits in a
fence because its links are written root-relative, for the README's location,
not this file's.

````markdown
# pancake

<img src="assets/pancake-icon-256.png" alt="" align="right" width="140" />

[![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)](https://ziglang.org/)
[![zero-copy contract](https://img.shields.io/badge/zero--copy-contract-blue.svg)](docs/architecture.md)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](#license)

> **pancake is a codec-neutral [CapTP](http://erights.org/elib/distrib/captp/) core for [OCapN](https://github.com/ocapn/ocapn).**
> **Syrup where OCapN requires it. Owned frames or borrowed views wherever frames cross a boundary.**
> **Because you can't have pancakes without syrup.**

## What is this?

pancake is a Zig implementation of the object-capability networking core: two
programs hand each other unforgeable references to remote objects and call
methods across a session with the same authority discipline as local
references. No ambient authority, no string-typed permissions. If you hold
the reference, you can use it.

New to capabilities, CapTP, or OCapN?
[`docs/capabilities.md`](docs/capabilities.md) explains the ideas and the
vocabulary before any code appears.

It targets OCapN, the open object-capability network protocol from
[Spritely Institute](https://spritely.institute/) and the OCapN community.
You use it as a library, and you manage its memory yourself. Nothing
important hides: where a copy happens, where something is allocated, which
wire format is in play, where I/O and scheduling live — all of it stays
visible at the boundary that owns it.

## Quick start

pancake is a Zig package:

```sh
zig fetch --save git+https://codeberg.org/jimisaacs/pancake
```

```zig
const pancake = b.dependency("pancake", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("pancake", pancake.module("pancake"));
```

A client is one object and a handful of verbs: connect, fetch a capability
by name, call it, switch on the settled outcome, close.

```zig
const pancake = @import("pancake");

const conn = try pancake.driver.connect(io, allocator, address, .{});
defer conn.close();

const board = try conn.fetch("board"); // a capability, by name
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const settled = try conn.call(board, .{
    .verb = "add",
    .args = &.{.{ .string = "buy groceries" }},
}, arena.allocator());
switch (settled) {
    .fulfilled => |arg| std.debug.print("added task #{d}\n", .{arg.integer}),
    .broken => |reason| std.debug.print("the board refused: {s}\n", .{reason}),
}
```

That snippet is machine-checked:
[`examples/zig/readme_quick_start.zig`](examples/zig/readme_quick_start.zig)
carries the same code verbatim and runs under `zig build examples`. The
hosting half is the same shape;
[`examples/zig/01_connect_and_serve.zig`](examples/zig/01_connect_and_serve.zig)
is the runnable version of both halves.

Not writing Zig? The same library is a C ABI with bindings:
[`docs/consuming-from-c.md`](docs/consuming-from-c.md) is the route for C and
FFI consumers, and [`bindings/`](bindings/README.md) holds the Rust, Deno,
Python, and Racket surfaces — each speaking the same nine application verbs.

## Learn by example

The [example chapters](examples/README.md) read top-down, from the
application surface to the raw engine: connect and serve, actors and
far-sends, lookup by name, then explicit frames one `step` at a time. Three
full applications then run the same code across every binding on one wire:
a capability-secure chat room (`zig build demo-rooms`), a shared task board
(`zig build demo-tasks`), and an AI-agent tool harness with delegation,
attenuation, and revocation (`zig build demo-tools`).

## Design posture

The portable core is deterministic, sync, and no-I/O; adapters own sockets,
scheduling, and host integration. Session state is authoritative; codecs
parse and render but decide nothing. Every wire-path allocation and copy is
forbidden, named, or measured, and the budgets are build gates, not
intentions. Conformance is load-bearing: OCapN behavior as a real Spritely
Goblins peer speaks it, proven live in both directions, plus the upstream
OCapN test suite. The whole argument lives in
[`docs/architecture.md`](docs/architecture.md) and
[`docs/vision.md`](docs/vision.md).

## Status

What ships today — the full wire surface, both codecs, three netlayers, the
actor layer, third-party handoffs, live Goblins interop from every binding —
is inventoried in [`docs/shipped.md`](docs/shipped.md). The honest edges
(cleartext TCP, process-lifetime bootstrap registrations, the fail-closed
OCapN Null, the unbuilt `griddle` simulator) live in
[`docs/boundaries.md`](docs/boundaries.md), and the ordered route to 1.0 in
[`docs/ladder.md`](docs/ladder.md).

## Build

```sh
zig build          # libpancake.a, libpancake.so, pancake.h under zig-out/
zig build check    # the full hermetic gate: tests, examples, oracles, budgets
```

The complete step catalog, including the live interop and conformance gates,
lives in [`.agents/rules/cli.md`](.agents/rules/cli.md). Contributors start
at [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Documentation

- [`docs/capabilities.md`](docs/capabilities.md) — capabilities, CapTP, and
  OCapN from zero, plus the glossary.
- [`docs/consuming-from-c.md`](docs/consuming-from-c.md) — build, link,
  ownership rules, first complete C program.
- [`docs/architecture.md`](docs/architecture.md) — layers, memory, and the
  C ABI contract.
- [`docs/protocol-diagrams/`](docs/protocol-diagrams/README.md) — the living
  CapTP diagrams.
- [`docs/shipped.md`](docs/shipped.md) and
  [`docs/boundaries.md`](docs/boundaries.md) — what exists and where it ends.
- [`docs/decisions/`](docs/decisions/README.md) — the accepted decision
  records.
- [`SECURITY.md`](SECURITY.md) — vulnerability reporting and the invariants a
  report may cite.

## License

Licensed under [Apache-2.0](LICENSE-APACHE). Contributions are accepted under the same terms.
````

End of draft. Open decisions the draft takes a position on, called out for
review: the Devcontainer section leaves the README entirely (its new home is
CONTRIBUTING.md); the 500k number leaves the README entirely (ladder owns
it); the "On The Wire Today" content survives in full as `docs/shipped.md`
rather than being compressed, because the inventory's specificity is a
strength — only its location and voice change.
