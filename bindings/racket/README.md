# reference/implementations/pancake-goblins/

> **Runtime.** Devcontainer-only. First task invocation lazy-installs
> Racket Minimal 8.16 + Spritely Goblins via
> [`tools/non-pixi-lazy-install/`](../../../tools/non-pixi-lazy-install/)
> AND builds `libpancake_ffi.so` via the workspace's `dev.sh`. Both
> products are cached in the named devcontainer volumes so subsequent
> runs are seconds, not minutes.

The Racket binding for [`pancake-ffi`](../../../crates/ffi/pancake-ffi-runtime/):
FFI bindings, byte-counting Syrup framer, TCP-bridge pump, and a
Goblins-API-compatible CapTP shim (`captp.rkt`) that lets Spritely
Goblins apps run on pancake-ffi for their OCapN wire protocol with
a single `(require)` swap.

The binding's scenarios live in
[`../../tests/pancake-ffi-bindings/`](../../tests/pancake-ffi-bindings/)
(the per-binding scenarios catalog); each scenario is dispatched via
[`racket/scenario-runner.rkt`](racket/scenario-runner.rkt). The
five end-to-end claims this directory makes are encoded as
scenarios there:

| Scenario (catalog id) | What it proves |
| --- | --- |
| `handshake-self-in-process` | The FFI bindings drive `pancake_runtime::Peer` end-to-end; two stub-keyed peers complete StartSession + a typed Abort over an in-process byte shuttle |
| `handshake-self-tcp` | The TCP-bridge pump drives the pancake↔pancake handshake over loopback TCP with real Ed25519 keys |
| `handshake-as-client-vs-spritely` | pancake-ffi-via-Racket dials Spritely Goblins's seven-caps-peer and reaches `PANCAKE_SESSION_OPEN` |
| `echo-as-host-vs-spritely` | The substrate-swap MVP — Goblins ^echo cap hosted on pancake-backed captp; stock Spritely Goblins client dials and invokes it round-trip |
| `graceful-abort-send` | The typed Abort path under A4's peek-before-consume idiom |

**End-to-end claim, empirically demonstrated**: a Goblins app
(`(spawn ^echo)`, registers, runs in a Goblins vat) hosted on
pancake-ffi (no Spritely captp.rkt anywhere in its process)
interoperates over the wire with a stock Spritely Goblins client
(`(require goblins/ocapn/captp)` unchanged) — including
bootstrap-fetch, sturdyref enliven, op:deliver invocation,
op:deliver-style V1.0 resolver-callback response. Pancake-ffi IS
the OCapN protocol engine under a Goblins app.

The MVP has known truncation limits — pancake-ffi v1 doesn't have
a typed `List` argument variant yet (ADR-0049 v2 promotion target;
ACTION_ITEMS C1), so multi-value returns get squashed to the first
element (echo returns `"hello"` instead of the list `("hello"
"world")`). That's an FFI-side limit, not a captp.rkt-side one;
landing the typed List variant in pancake-ffi will round-trip the
full list without further Racket changes.

## Files

### Library modules

| File | What it does |
|---|---|
| [`racket/pancake-ffi.rkt`](racket/pancake-ffi.rkt) | `racket/foreign` bindings for the typed pancake-ffi C ABI: peer lifecycle (A2/A3 redesign — typed `pancake-peer-new` takes a keypair + collapsed `pancake-peer-send-start-session`), step + queues, typed value types (`pcakeref` / `pcakearg` / `pcakeres`), typed send + event accessors (A4 peek-before-consume idiom), Ed25519 key-pair, cross-peer entry points, last-error retrieval. The load-bearing FFI primitive everything else builds on. |
| [`racket/syrup-framing.rkt`](racket/syrup-framing.rkt) | Byte-counting Syrup framer ported from `crates/net/pancake-net-tcp/src/framing.rs`. Required because pancake's `pancake_peer_feed_inbound` takes one complete codec-frame per call; pancake's TCP wire format has no length prefix, so the bridge identifies frame boundaries by walking the Syrup grammar. |
| [`racket/tcp-bridge.rkt`](racket/tcp-bridge.rkt) | Pumps bytes between a TCP socket and a `PancakePeer`. One reader thread (socket → inbound channel), one pump thread (owns exclusive access to the pancake mutex; drives `step` + drains outbound + kicks the handshake via the collapsed `pancake-peer-send-start-session`). |
| [`racket/captp.rkt`](racket/captp.rkt) | Drop-in replacement for `goblins/ocapn/captp` — exposes the same `spawn-mycapn` entry point with a MVP-subset surface (`register`, `register-at-swiss`, `get-registry`, `get-locator`). For each accepted TCP connection, spawns a pancake-ffi peer + pump thread; routes typed Deliver events back to local Goblins actors. |
| [`racket/pancake-tcp-netlayer.rkt`](racket/pancake-tcp-netlayer.rkt) | Minimal byte-oriented netlayer for `captp.rkt` (Spritely's stock netlayer gives parsed Syrup values; pancake-ffi needs raw bytes). |

### Scenario runner

| File | What it does |
|---|---|
| [`racket/scenario-runner.rkt`](racket/scenario-runner.rkt) | Single Racket entry point for the pancake-ffi-bindings catalog. Dispatches by `<scenario-id> [--side <side>]`. Most scenarios' logic lives inline in the main module; the `echo-as-host-vs-spritely` host + client sides live in submodules to keep the pancake-backed captp.rkt imports isolated from the stock `goblins/ocapn/captp` imports of the client side (require-conflict avoidance via submodules). |

### Infrastructure

| File | What it does |
|---|---|
| [`stack/run.sh`](stack/run.sh) | Single-command launcher; thin wrapper around `pixi run` against `stack/pixi.toml`. |
| [`stack/pixi.toml`](stack/pixi.toml) | pixi project manifest declaring the binding's tasks. Lazy-installs Racket + Goblins; builds pancake-ffi via the workspace's `dev.sh`; exports `PANCAKE_LIB` automatically. The public `scenario` task dispatches into `scenario-runner.rkt`. |
| [`LESSONS.md`](LESSONS.md) | What the dogfood revealed about pancake-ffi's architecture — concrete FFI improvement opportunities, each ranked with what it unblocks. Includes the V1.0/GOBLINS_CANONICAL split research + 10x architectural view (four recurring patterns). |
| [`ACTION_ITEMS.md`](ACTION_ITEMS.md) | Audit-with-action-items companion to LESSONS.md. Concrete: what to do, in what file, with what acceptance criteria. Addresses the Racket-interfaces / Goblins-engine-factory question + audits each 10x pattern with line-of-code references. |
| [`HANDOFF.md`](HANDOFF.md) | **Read before doing any new work in this directory.** Captures the philosophical lens (idealistic APIs, forward-looking designs — NOT migration-cost-driven) + the load-bearing context + anti-patterns to avoid. Specifically warns against the "smallest-correct-change" and "don't break tests" defaults that fresh-context agents fall into. |

## Running

Scenarios run via the [pancake-ffi-bindings catalog's pixi
tasks](../../tests/pancake-ffi-bindings/pixi.toml):

```bash
# Sanity-check the FFI bindings (no TCP, no Goblins; single command):
bash reference/tests/pancake-ffi-bindings/run.sh handshake-self-in-process-racket

# Pancake↔pancake handshake over loopback TCP (two terminals):
bash reference/tests/pancake-ffi-bindings/run.sh handshake-self-tcp-racket-server
bash reference/tests/pancake-ffi-bindings/run.sh handshake-self-tcp-racket-client

# Pancake↔Spritely Goblins wire interop (two terminals):
bash reference/tests/pancake-ffi-bindings/run.sh target-spritely-seven-caps
bash reference/tests/pancake-ffi-bindings/run.sh handshake-as-client-vs-spritely-racket

# Goblins-on-pancake substrate-swap MVP — echo cap round-trip (two terminals):
bash reference/tests/pancake-ffi-bindings/run.sh echo-as-host-vs-spritely-racket-host
bash reference/tests/pancake-ffi-bindings/run.sh echo-as-host-vs-spritely-racket-client

# Isolated typed-Abort + A4 peek-before-consume (single command):
bash reference/tests/pancake-ffi-bindings/run.sh graceful-abort-send-racket
```

For direct dev iteration without the catalog wrapper, the binding's
`stack/run.sh scenario <id> [--side <side>]` invokes
`scenario-runner.rkt` directly:

```bash
bash reference/implementations/pancake-goblins/stack/run.sh scenario handshake-self-in-process
bash reference/implementations/pancake-goblins/stack/run.sh scenario echo-as-host-vs-spritely --side host
```

## Adjacent directories (don't confuse)

| Looking for... | Look here |
| --- | --- |
| Spritely Goblins acting AS an OCapN peer (the dial target above) | [`../goblins-peer/`](../goblins-peer/) |
| Spritely Goblins itself (the actor runtime + canonical CapTP impl the substrate-swap shim replaces) | [`../spritely-goblins/upstream/`](../spritely-goblins/upstream/) |
| pancake-ffi crate (the FFI surface this directory's Racket bindings load) | [`../../../crates/ffi/pancake-ffi-runtime/`](../../../crates/ffi/pancake-ffi-runtime/) |
| The scenarios catalog the runner here serves | [`../../tests/pancake-ffi-bindings/`](../../tests/pancake-ffi-bindings/) |
| The OCapN conformance suite the dial path is the proof-of-life for | [`../../tests/ocapn-conformance/`](../../tests/ocapn-conformance/) |

## How pancake uses this

- **As an FFI consumer dogfood.** Validates pancake-ffi's typed C
  ABI works end-to-end from a real consumer language. Every FFI
  change has a path to empirical verification here, not just at
  the Rust-side unit tests; the
  [`pancake-ffi-bindings` catalog](../../tests/pancake-ffi-bindings/)
  is the systemic safeguard against the wire-shape regression
  class.
- **As wire-interop evidence.** The
  `handshake-as-client-vs-spritely` scenario is the Racket-side
  companion to the OCapN conformance suite's
  `pancake-conformance-peer ↔ goblins-peer` validation; together
  they cover both vantage points (pancake-as-Rust-host and
  pancake-as-FFI-consumer-host) against upstream Spritely.
- **As the substrate-swap MVP.** Per LESSONS.md / HANDOFF.md, this
  directory proves a Goblins app can run on pancake-ffi via the
  `(require pancake-goblins/captp)` swap. The graduation criterion
  for spinning out a standalone `pancake-goblins` Racket package
  is in LESSONS.md.

## Posture

- **Devcontainer-only.** No CI gate today — this directory
  exercises Racket + Goblins which aren't on conda-forge in the
  shape we need. Promotion to a CI gate happens per the catalog's
  promotion criterion (5+ consecutive devcontainer passes
  per scenario).
- **Editable.** Per the parent
  [`reference/README.md`](../../README.md#posture) — pancake-authored
  subdirectories can be modified, deleted, replaced, or extended
  without ceremony. pancake's invariants don't extend here.
- **Not in pancake's Cargo workspace** — `reference/` is excluded
  by construction; the Rust side is unaffected by anything that
  happens here.

## Links

- [`stack/pixi.toml`](stack/pixi.toml) — pixi tasks (lazy-installs + `scenario` dispatch + `shell` / `repl` dev surface)
- [`racket/scenario-runner.rkt`](racket/scenario-runner.rkt) — the dispatcher for the pancake-ffi-bindings catalog
- [`LESSONS.md`](LESSONS.md) — FFI architectural opportunities surfaced
- [`../goblins-peer/`](../goblins-peer/) — the Goblins-side peer the dial scenarios target
- [`../../tests/pancake-ffi-bindings/`](../../tests/pancake-ffi-bindings/) — the scenarios catalog this binding implements
- [`../../../crates/ffi/pancake-ffi-runtime/`](../../../crates/ffi/pancake-ffi-runtime/) — the FFI crate these bindings load
