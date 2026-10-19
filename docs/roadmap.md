---
type: living
description: The unfinished work, each item linked to its plan.
sources: []
---

# Remaining work

Unfinished work, each item linked to its plan, or to the
[plan to plan](planning/plan-to-plan.md) until it has one. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. [Upstream
watch](upstream-watch.md) tracks open OCapN and Goblins questions.

## Platforms and reachability

OS portability and platform acceptance, including Windows with IOCP and
macOS validation, are release obligations the maintainer runs.

- **Windows and IOCP.** There is no Windows runtime check and no IOCP backend.
  Windows support needs an IOCP backend that meets the existing
  completion-loop contract in full (`validateBackend` checks it), then live
  tests and release artifacts. It waits on Windows hardware for the checks
  ([plan to plan](planning/plan-to-plan.md)).
- **Public-certificate relay URLs.** Local WSS with a fixture authority is
  checked. A public certificate at a real relay hostname is still unproven
  across every execution form outside the browser
  ([known limitations](boundaries.md#browser-reachability)). It waits on a
  real relay hostname ([plan to plan](planning/plan-to-plan.md)).
- **Primary TypeScript runtime.** Cloudflare ends its development of the Deno
  runtime after a one-year maintenance window that began in October 2026, and
  Bun cannot host the binding's driver loop because its FFI runs on the
  JavaScript thread.
  [ADR-0066](decisions/adr/ADR-0066-proposed-typescript-runtime.md)
  is the proposed record: Bun becomes the primary runtime through one
  Node-API addon that serves Bun and Node, and Deno leaves the toolchain.
  Nothing moves before the record is accepted. The pinned Deno release stays
  the environment of record until then
  ([plan to plan](planning/plan-to-plan.md)).

## OCapN direction

The `1.0` profile preserves pinned Goblins interoperability, and
`glowcap-next` tracks the merged draft. The
[conformance manifest](ocapn-conformance.md) records adopted, deferred, and
pending sections independently of the specification reference. [Upstream watch](upstream-watch.md) holds
what glowcap cannot settle alone.

- **Five-field `op:start-session`.** The merged draft moves `crypto-version`
  into the hello and replaces the structured key and signature records with
  raw bytes. The hello is the one message both profiles share, because a peer
  sends it before it knows the partner's profile
  ([ADR-0001](decisions/adr/ADR-0001-codec-profiles-and-negotiation.md)), so
  this cannot land in `glowcap-next` alone. Nothing moves until the text names
  one version and a Goblins release speaks it
  ([upstream watch](upstream-watch.md#session-cryptography-shape)).
  The [transition plan](planning/ocapn-crypto-version-handshake.md) lists what
  must be ready and the steps after that.

## Release dependencies

The first-publication steps in the
[open obligations](#open-obligations-from-retired-plans) wait on maintainer
account actions. These checks follow that publication or a release decision,
and the engineering work above does not depend on them.

- **Public release evidence.** Before an invite or release, run the exact
  release commit through the checks and macOS jobs, then verify the repository,
  badge, and run are visible without authentication. Maintainer action
  ([plan to plan](planning/plan-to-plan.md)).
- **Published C archives.** No versioned assets are live. Publication needs
  green packages for every target, a tagged exact-SHA release, verified live
  assets, then the `releases_published` consumer switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json) and a
  cold-cache smoke against the real release URL. The order is fixed by the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives).
  It waits on publication ([plan to plan](planning/plan-to-plan.md)).

- **Bindings own their symbol omissions.** Each C archive's symbol inventory
  (`symbols.zig`) carries a per-binding omit flag, so the C ABI layer names
  its consumers and a new binding adds a field to a shared row type. Each
  binding should hold its own short list of the symbols it skips and why,
  beside its generated table, and the generators join the two
  ([plan to plan](planning/plan-to-plan.md)).

## Durable applications

The [Loam guide](loam.md) covers the Loam foundation, its managed access
module, and persistence research. Nothing above blocks this work.

1. **Integrate Rooms content and access.** Use the settled interaction
   contract. Integrate recursive rooms, directory access, branching
   conversations and reorganization in the
   [Rooms plan](planning/rooms.md).
   Deliver the shared access editor with each integration.
2. **Power-loss assumptions.** Establish which power-loss assumptions each
   disk engine's flush supports before claiming them, SQLite first because it
   is the default
   ([plan to plan](planning/plan-to-plan.md)).
3. **Measure the remaining access workloads.** The
   [access storage guide](loam/access-storage.md#performance-contract-and-measurements)
   names each workload and what it must observe. Warm reads by depth, scope
   selection, descendant growth, hot reads under slow writes, churn, and browser
   latency and responsiveness are not measured. Measure each on the
   default engine, SQLite. One that locates a limit in it reopens that choice
   ([ADR-0062](decisions/adr/ADR-0062-sqlite-default-storage.md),
   [plan to plan](planning/plan-to-plan.md)).
4. **Typed hosted access API.** Build typed resource and control clients over
   the existing Host, and expose bounded resource-tree operations and the
   owner lifecycle through the C ABI and Rust. The
   [implementation plan](planning/typed-hosted-access.md) waits for maintainer
   review before execution. Existing Zig admission, receipts, and recovery
   remain authoritative.
5. **Residency slot lookup.** The resident record cache finds a slot by
   scanning them in order, 7 percent of a hot read at both profile shapes
   and stable as the population grows. An indexed lookup waits for a bench
   shape in which that share matters
   ([plan to plan](planning/plan-to-plan.md)).

The C/Rust and browser fixed-resource lifecycles are described in the
[C/Rust scope](loam/c-and-rust.md) and the
[browser scope and evidence](loam/browser.md). The exercised fixed-resource
profile does not freeze the broader foreign ABI.

The [Rooms design contract](planning/rooms-design.md) specifies the remaining
resource work. The [session guide](rooms/session.md) and
[effect contract](rooms/session-effects.md) describe the session that exists.
[ADR-0048](decisions/adr/ADR-0048-loam-persistence-foundation.md) records
ownership.

## Open obligations from retired plans

Each row is done when its evidence sentence is true. Then delete the row.

| Area | Remaining obligation | Evidence that closes it |
| --- | --- | --- |
| Sealed scale | Repeat the 500,000 live session run on `noise-tcp`. The load half drives raw peers through completion loops, and the product refuses a second session between one pair of durable identities. So the sealed run needs a load half that opens one Noise channel per connection under its own fresh key, with the sealed channel between the socket and the raw peer ([plan to plan](planning/plan-to-plan.md)). | `bench/README.md` records a sealed 500,000 figure beside the cleartext one. |
| Session open cost | Opening a `tcp` session measures 2.3× its named floors and a `noise-tcp` one 2.1×, with the per-session key derivation, the socket setup, the accept wake, and the fetch's own round trip outside the floors. Profile one open and either name those as floors or fix the layer that owns the cost ([plan to plan](planning/plan-to-plan.md)). | Both session-open rows in `bench/README.md` sit under 2×, or the page says why they stay. |
| Nightly fuzz | The scheduled fuzz job in `check.yml` runs only on the default branch, so it has not run while `main` trails `dev` ([plan to plan](planning/plan-to-plan.md)). | One scheduled run on `main` is green. |
| Loam acceptance | One successful macOS run of `zig build test loam-lmdb-test loam-sqlite-test` plus the Loam crash probes the macOS job runs, recorded with revision and commands. Maintainer-owned. Needs runners the private repository does not get ([plan to plan](planning/plan-to-plan.md)). | `docs/stability.md` records the run. The macOS sentences in [stability](stability.md) and [shipped](shipped.md#resource-models) change to present tense. |
| Visualizer | Re-measure playback on the reporting machine's real GPU with the committed stress corpus. Maintainer action ([plan to plan](planning/plan-to-plan.md)). | No visible playhead jump with the work-budget tests green. The table in `apps/ocapnviz/test-data/README.md` gains the new row. |
| Publication | Remain private and use [local integration](maintaining.md#integrating-locally) until the maintainer authorizes publication. Then verify hosted runner availability, make the repository public, activate and verify [main protection](maintaining.md#repository-protection), confirm the promotion PR and resulting `main` push pass their required checks, enable private vulnerability reporting, set Pages to deploy from Actions and run `pages`. Maintainer-owned ([plan to plan](planning/plan-to-plan.md)). | The badge, run, and site are visible without authentication. An unchecked promotion cannot merge. The release section of the [release dependencies](#release-dependencies) takes over. |

## Further application work

- **A2A facade.** Deferred by
  [ADR-0032](decisions/adr/ADR-0032-cli-and-product-boundaries.md). A
  [design sketch](planning/glowcap-a2a-on-captp-design.md) records the
  design. It waits on a maintainer decision to undefer it
  ([plan to plan](planning/plan-to-plan.md)).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module. It waits on a maintainer decision
  ([plan to plan](planning/plan-to-plan.md)).
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist. It waits on a maintainer
  decision ([plan to plan](planning/plan-to-plan.md)).
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0040](decisions/adr/ADR-0040-trace-observation-authority.md)). No endpoint
  offers a control capability yet. It waits on a maintainer decision
  ([plan to plan](planning/plan-to-plan.md)).
- **Admission and accountability.** A front-door pattern for applications:
  check a cheap pass before any session, exchange one proof for a scoped,
  budgeted, revocable facet, and follow responsibility across delegation
  hops. [What about identity?](https://jimisaacs.github.io/glowcap/identity/)
  explains the model. It waits on a maintainer decision
  ([plan to plan](planning/plan-to-plan.md)).
