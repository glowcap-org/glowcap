---
id: ADR-0066
status: proposed
date: 2026-10-13
tags: ["bindings", "c-abi", "driver", "runtime"]
decision: "Bun becomes the primary TypeScript runtime."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0066 Proposed TypeScript runtime

## Context

The TypeScript binding runs one API on Deno and Bun with a WebAssembly entry
for browsers. Deno is the primary runtime. It runs the stepping driver loop,
the live Goblins client and listener checks, the relay, the iroh checks, the
Rooms and visualizer test harnesses, and the formatter, linter, type checker,
and test runner for every TypeScript file in the tree. Each package and app
carries its own `deno.json`, and the workspace scopes carry frozen lockfiles.

The driver loop parks in one off-thread `poll(2)` on a copy of the kernel
readiness descriptor, through the `nonblocking` flag of Deno's FFI
(`bindings/ts/runtime/driver_loop.ts`). Bun's FFI runs every call on the
JavaScript thread, so Bun refuses listeners and blocking transport
lifecycles before allocating them (`bindings/ts/dogfood/smoke/bun_refusals.ts`).
[Stability](../../stability.md) and [known limitations](../../boundaries.md)
record that exclusion, and `bun-dogfood` proves the refusals.

On 2026-10-09 Deno announced that it is [joining
Cloudflare](https://deno.com/blog/cloudflare). The runtime gets one more year
of monthly bug-fix and security releases, after which Cloudflare ends its
development and leaves the code open source. Deno Deploy closes after six
months. JSR keeps operating on Cloudflare's infrastructure. The Deno release
glowcap pins is a checksummed GitHub asset (`.devcontainer/pins.sh`), so the
environment of record stays reproducible for the whole window and nothing
forces a change this year. The packages Deno hosts for glowcap (Vite, React,
Playwright, zod, and the Deno Vite plugin) move on their own schedules, and
any one of them may pass Deno's npm compatibility before the window ends.

What Deno provides that Bun 1.4.2 does not:

- **Off-thread FFI.** The inproc, iroh, and onion packages mark their parking
  symbols `nonblocking` in their FFI tables, and the driver loop's park
  depends on the same mechanism. Bun has no equivalent.
- **Deny-by-default permissions.** A build step that runs Deno names the
  authority it takes. Most steps take all of it with `-A`, a smaller set
  names read, FFI, net, env, and run one flag each, and a few scope net and
  env to exact values. Bun runs with ambient authority, so the mechanism
  goes, along with the posture the tree uses it for in places.
- **A built-in toolchain.** Deno formats, lints, type-checks, and tests, and
  its test runner fails any test that leaks an operation or a resource. Bun
  ships run, test, build, install, and publish. Type-checking, formatting, and
  linting become pinned npm dependencies, and the leak check has to be
  rebuilt.
- **Per-scope import maps with frozen lockfiles.** Bun resolves through
  `package.json` and one `bun.lock`.

What Bun provides that Deno does not:

- **npm-shaped resolution.** Vite, React, Playwright, and zod resolve without
  `npm:` specifiers or the Deno Vite plugin. One workspace `package.json` and
  one lockfile replace the per-package `deno.json` files and their lockfiles,
  and the check that keeps two copies of one npm pin in step goes away.
- **Install, startup, and test runner speed** across a test suite spread over
  hundreds of files.
- **A consumer runtime more people already run,** and npm publishing for
  `@glowcap/*`.

Node is not a supported runtime today. The adapter seam resolves Deno or Bun
and refuses any other runtime (`bindings/ts/runtime/internal/ffi/runtime.ts`),
and no build step runs the binding on Node. Node 26.1 added an experimental
`node:ffi` module, and the pinned Node 26.10 ships it, but its calls and its
callbacks stay on the JavaScript thread, so Node shares Bun's parking gap
rather than Deno's answer to it. Deno and Bun are each a single-vendor
runtime, and the announcement shows what that costs when the vendor's
direction changes.

## Decision

Bun becomes the primary TypeScript runtime. The binding reaches Bun and Node
through one Node-API addon that Zig renders from the C ABI symbol
inventories, and Deno leaves the toolchain before Cloudflare's last
maintenance release.

1. **One Node-API addon.** A generator under `tools/gen/binding/`, in the
   pattern of the Rust, Python, Racket, and TypeScript FFI tiers, renders a
   Node-API addon from each archive's symbols inventory, with the same
   comptime check that every export has a row. Node and Bun both implement
   Node-API, so one artifact per platform serves both. It ships in the C ABI
   release tarball that the resolve cascade already locates. The addon runs
   the park off the JavaScript thread through Node-API's own mechanisms,
   either async work or an addon-owned thread with a thread-safe wake. The
   symbol inventories stay the one authority over the exported symbols.
2. **The addon is gated before anything else moves.** `bun-dogfood` grows
   until Bun runs the live Goblins listener matrix, the relay, and the iroh
   checks that Deno runs today, and a Node step runs the same programs. No
   other part of the swap starts before that passes, because the addon is the
   only part that can fail on design grounds.
3. **Lifecycle evidence is rebuilt before a test converts.** A shared test
   teardown on the binding's cleanup registry (`@glowcap/runtime/cleanup`)
   fails any test that leaves a live socket, child process, or timer. It
   replaces Deno's operation and resource sanitizers and lands first.
4. **One toolchain, pinned like the runtimes.** The TypeScript compiler, a
   formatter, and a linter become exact pins in the workspace lockfile, and
   `source-check` holds them the way it holds the Playwright pin today. The
   TypeScript tree is reformatted once, in its own commit.
5. **The sweep follows rules per surface.** `Deno.test` moves to `bun:test`.
   Process, file, signal, and socket calls move to the `node:` modules Bun
   implements. `deno.json` and its lockfiles become the workspace
   `package.json` and `bun.lock`. Build steps, source checks, the devcontainer
   image, the editor settings, and the docs change in the same batches as the
   code they describe. The `@glowcap/*` packages publish to npm. The Rust
   example that shells out to `deno fmt` takes the new formatter.
6. **Deno is removed, not demoted.** No secondary dogfood target survives, and
   the `DENO_VERSION` pin leaves the devcontainer image. Two runtimes for one
   job is the state this record ends.

The order is this record, then the addon, then the sweep, landed well inside
the maintenance window rather than at its edge.

## Scope (what this does not decide)

- Whether Node gets its own row in [stability](../../stability.md) with
  recurring steps, or is proven only by the addon's dogfood.
- Whether `bun build` replaces Vite for the Rooms and visualizer browser
  bundles.
- Whether Cloudflare Workers becomes a deployment target for the byte-fed
  relay and `@glowcap/web` paths. That is upside after the swap, not part of
  it.
- The addon's thread model. Async work and an addon-owned thread are both
  open until the addon's own design settles it.
- When the work starts. The window is a year of maintenance releases, and
  the record names no date inside it.

## Alternatives Considered

- **Keep Deno primary and build a Bun executor for parity.** Rejected because
  Deno's development ends in a year, so parity would keep every Deno-only
  cost and add the executor on top.
- **Bun primary through `bun:ffi` with a Worker-owned executor.** A Worker
  holds the dlopen handle and the parking calls, and the main thread talks to
  it over messages. Rejected because it serves Bun alone, pays a message hop
  per park, and repeats the single-vendor bet this record is responding to.
- **Node and Bun through their built-in FFI modules.** `node:ffi` and
  `bun:ffi` would each get an adapter and share the Worker executor above.
  Rejected for the same reasons as the Worker executor, and because `node:ffi`
  is experimental and may change under the binding. Node's
  `ffi.getCurrentEventLoop()` would let a shim poll the readiness descriptor
  from Node's own libuv loop instead of parking, but that path exists on Node
  alone, so it does not replace the addon.
- **Swap roles and keep Deno as the secondary dogfood target.** Rejected
  because it holds two runtimes for one job until a removal date the window
  already sets.
- **Node primary with Bun secondary.** The addon serves both, so the choice is
  which runtime runs the tests and tools. Rejected because Bun runs
  TypeScript without a build step and ships its own test runner, so the
  contributor loop is shorter on Bun.
- **Pin the last Deno release indefinitely.** Rejected because a runtime
  without security releases cannot be the environment of record.

## Consequences

- `src/` is unchanged. The addon consumes the same archives through the same
  C ABI, so the sans-io core and the C surface gain nothing.
- `tools/gen/` gains the addon generator and `tools/build/` gains the addon
  build and the steps that run it. The `source-check` rules that encode Deno
  (formatting, npm pins, test wiring, the Playwright pin) are rewritten for
  the new toolchain. The devcontainer image drops Deno and its cache volume.
- The permission flags leave the build graph. The record accepts that loss.
- Every `Deno.test` and every Deno API call in tests, harnesses, scripts, the
  relay, and the apps moves. The teardown check from decision 3 is what
  keeps a leak visible after the sanitizers are gone.
- [Stability](../../stability.md), [known limitations](../../boundaries.md),
  the binding READMEs, and [build steps](../../build-steps.md) change in the
  same batches as the code they describe.

## Evidence and gate

A proposed record has no in-tree evidence. On acceptance, the gate is:
`bun-dogfood` runs the listener matrix on Bun through the addon and a Node
step runs the same programs, a test that leaks a socket on purpose fails
under the teardown check, and `check` and `runtime-check` pass with Deno
absent from the image.

## Notes

[ADR-0034](ADR-0034-browser-peers.md) names the adapter seam
the addon joins. [ADR-0023](ADR-0023-binding-archive-resolution.md) owns the
cascade that locates the archives and, with them, the addon.
[ADR-0024](ADR-0024-transport-provider-and-abi-contracts.md) owns the driver archive the
loop parks on.
