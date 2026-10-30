---
type: living
description: The unfinished work in the order it starts, each item linked to its plan.
sources: []
---

# Remaining work

Unfinished work, each item linked to its plan, or to the
[plan to plan](planning/plan-to-plan.md) until it has one. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. [Upstream
watch](upstream-watch.md) tracks open OCapN and Goblins questions.

Work that can start sits first, in the order it starts. Work that waits on
something outside the code follows, grouped by what it waits on. An item moves
up when its wait ends.

## Opening the repository

Public source and contribution do not require a finished roadmap or stable
APIs. Publish the implemented scope with its known limits. The publication
item under [waiting on you](#waiting-on-you) owns repository activation, and
public release evidence owns checks on the exact candidate commit. A tagged
package additionally needs the published-archive checks. None of these
milestones means 1.0.

Fix known correctness defects in advertised behavior and broken contributor
paths before inviting use. Planned features, broader platform support and
unmeasured deployment sizes can remain open when the public docs do not
promise them. A passing documentation check alone does not establish release
readiness.

Known limitations describe consequences, not acceptance. A gap against the
vision needs work here with a completion criterion, or an explicit decision
narrowing the supported scope. Intentional contracts stay in their guides.
Stability owns missing evidence. Keep a limitation visible until its fix is
verified. Plans own implementation steps and acceptance.

## What starts next

The order follows [the ladder](ladder.md): protocol behavior, then
performance, then hosted applications, then the C surface and its bindings.
Items run side by side when their plans' lanes allow, so a later item waits
for an earlier one to start, not to finish. A plan marked as waiting for
review needs that review before its first step.

1. **Promise projection and forwarding.** Resolve pending local answer
   forwarding, local-only vow capabilities, and remote pipelines whose target
   settles on another session. Establish the required behavior from OCapN and
   independent messages before changing the owning runtime. Done when calls
   preserve their target, outcome, and required ordering through settlement,
   with cancellation and release coverage. A wire restriction needs its
   external rule and upstream dependency, not just an expected refusal in a
   local test ([plan to plan](planning/plan-to-plan.md)).
2. **Adapter contract gaps.** Make Rust shutdown finish finalizer recovery or
   return an owned failure before its executor exits. Prove refused C releases
   cannot silently strand recovery. Project the existing backend-selection
   report through `driver.HostRuntime` and support Unix-socket Tor endpoints
   through Zig's public runtime. Done when public API tests cover those
   existing provider contracts and both successful and refused shutdown
   ([plan to plan](planning/plan-to-plan.md)).
3. **Interop coverage.** Extend live binding checks to automatic capability
   finalization, and live Goblins relay checks to Python, Rust and Racket.
   Keep the exact role and transport coverage in community review. Work that
   requires unsupported Goblins operations waits on upstream support, and the
   rest starts here ([plan to plan](planning/plan-to-plan.md)).
4. **Sealed scale.** Repeat the 500,000 live session run on `noise-tcp`. The
   load half drives raw peers through completion loops, and the product
   refuses a second session between one pair of durable identities. So the
   sealed run needs a load half that opens one Noise channel per connection
   under its own fresh key, with the sealed channel between the socket and
   the raw peer. Done when the generated
   [live-session report](https://glowcap.org/performance/#live-sessions)
   records a completed sealed run beside the cleartext one
   ([plan to plan](planning/plan-to-plan.md)).
5. **Session open cost.** The
   [session-opening report](https://glowcap.org/performance/#live-sessions)
   measures connect, handshake, fetch, and close. Its cost model needs
   per-session key derivation, socket setup, accept wake, and the fetch round
   trip. Profile one open and either name those as floors or fix the layer
   that owns the cost. Done when the report includes measured component
   floors for both transports, with each total under 2× its named floors or
   an explanation of the remaining cost
   ([plan to plan](planning/plan-to-plan.md)).
6. **Measure the remaining access workloads.** The
   [access storage guide](loam/access-storage.md#performance-contract-and-measurements)
   names each workload and what it must observe. Warm reads by depth, scope
   selection, descendant growth, hot reads under slow writes, churn, and
   browser latency and responsiveness are not measured. Measure each on the
   default engine, SQLite, including the
   [missing load and cache conditions](stability.md#measurement-coverage).
   One that locates a limit in it reopens that choice
   ([ADR-0062](decisions/adr/ADR-0062-sqlite-default-storage.md),
   [plan to plan](planning/plan-to-plan.md)).
7. **Managed-access failure isolation.** Add commit-panic and
   owner-retirement coverage while unrelated actors remain active. Prove
   recovery or explicit refusal, no premature publication, and progress for
   unrelated owners. The existing process-kill suite does not prove these
   cases. Coordinate with the hosted access C surface item below
   ([plan to plan](planning/plan-to-plan.md)).
8. **Power-loss assumptions.** Establish which power-loss assumptions each
   disk engine's flush supports before claiming them, SQLite first because it
   is the default. [Stability](stability.md) says power loss is untested, so
   this extends evidence rather than repairing a claim
   ([plan to plan](planning/plan-to-plan.md)).
9. **Integrate Rooms content and access.** Use the settled interaction
   contract. Integrate recursive rooms, directory access, branching
   conversations and reorganization in the
   [Rooms plan](planning/rooms.md).
   Deliver the shared access editor with each integration. The
   [design contract](planning/rooms-design.md) specifies the remaining
   resource work, and the [session guide](rooms/session.md) and
   [effect contract](rooms/session-effects.md) describe the session that
   exists.
10. **Interface definitions.** Prove one complete authored contract and useful
   generated clients and server checks, including capabilities, promises,
   ownership, and retained mutations. The
   [interface plan](planning/interface-definitions.md) owns acceptance.
   [ADR-0069](decisions/adr/ADR-0069-proposed-interface-language.md) recommends
   one model, canonical Syrup descriptions, and a small authoring language.
   Generation from Syrup precedes the frontend comparison and cost decision,
   which must pass before complete Tasks migration.
   Adoption requires the plan's Rooms-management, TypeScript,
   and no-Zig consumer proofs before distribution and broader migrations.

   The bounded proof can run beside Rooms work, with protocol correctness
   retaining priority.

   [Discovery](planning/interface-discovery.md) needs a concrete consumer and
   separate review. Neither generation nor publication depends on it.
11. **Hosted access C surface.** Bounded resource-tree operations and the
    owner lifecycle, create, open, retire, are reachable only from Zig. Project
    them through the C ABI over the existing Host, with Zig admission,
    receipts, and recovery staying authoritative. Ready to plan once the
    [shared hosting plan](planning/rooms-hosting.md) names the owner API it
    needs ([plan to plan](planning/plan-to-plan.md)).
12. **Shared Rooms hosting and sign-in.** Host independent Rooms sessions
    over shared transport, storage and execution, with bounded per-session
    costs, and add optional identity-provider login that restores explicitly
    held access. The [hosting plan](planning/rooms-hosting.md) defines
    ownership, multiplexed membership and scale acceptance, and its optional
    [account contract](planning/rooms-hosting-accounts.md) defines sign-in
    custody and recovery. Hosting builds on the Rooms plan's policy catalog
    and room-owned grants, so it starts after those land. Both contracts wait
    for maintainer review before implementation.
13. **Bindings own their symbol omissions.** Each C archive's symbol
    inventory (`symbols.zig`) carries a per-binding omit flag, so the C ABI
    layer names its consumers and a new binding adds a field to a shared row
    type. Each binding should hold its own short list of the symbols it skips
    and why, beside its generated table, and the generators join the two
    ([plan to plan](planning/plan-to-plan.md)).

The [Loam guide](loam.md) covers the Loam foundation, its managed access
module, and persistence research. The C/Rust and browser fixed-resource
lifecycles are described in the [C/Rust scope](loam/c-and-rust.md) and the
[browser scope and evidence](loam/browser.md). The exercised fixed-resource
profile does not freeze the broader foreign ABI.
[ADR-0048](decisions/adr/ADR-0048-loam-persistence-foundation.md) records
ownership.

## Waiting on you

Each item is a maintainer action or a decision only the maintainer can make.
None of them needs a plan until the decision is made.

- **Publication.** Configure the [promotion app](maintaining.md#promotion-app)
  and verify a checked `dev` push advances `main`.
  Confirm on GitHub that an unsigned or unchecked push to
  `main` is refused ([repository protection](maintaining.md#repository-protection)).
  Done when the refusal is observed. The items under
  [waiting on publication](#waiting-on-publication) then take over
  ([plan to plan](planning/plan-to-plan.md)).
- **Public release evidence.** Before an invite or release, run the exact
  release commit through the checks and macOS jobs, then verify the
  repository, badge, and run are visible without authentication
  ([plan to plan](planning/plan-to-plan.md)).
- **Visualizer playback.** Re-measure playback on the reporting machine's
  real GPU with the committed stress corpus. Done when there is no visible
  playhead jump with the work-budget tests green, and the table in
  `apps/ocapnviz/test-data/README.md` gains the new row
  ([plan to plan](planning/plan-to-plan.md)).
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
- **A2A facade.** Deferred by
  [ADR-0032](decisions/adr/ADR-0032-cli-and-product-boundaries.md). A
  [design sketch](planning/glowcap-a2a-on-captp-design.md) records the
  design. It waits on a decision to undefer it
  ([plan to plan](planning/plan-to-plan.md)).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module. It waits on a decision to take it up
  ([plan to plan](planning/plan-to-plan.md)).
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist. It waits on a decision to take
  it up ([plan to plan](planning/plan-to-plan.md)).
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0040](decisions/adr/ADR-0040-trace-observation-authority.md)). No
  endpoint offers a control capability. It waits on a decision to take it up
  ([plan to plan](planning/plan-to-plan.md)).
- **Admission and accountability.** A front-door pattern for applications:
  check a cheap pass before any session, exchange one proof for a scoped,
  budgeted, revocable facet, and follow responsibility across delegation
  hops. [What about identity?](https://glowcap.org/identity/)
  explains the model. It waits on a decision to take it up
  ([plan to plan](planning/plan-to-plan.md)).

## Waiting on publication

These follow the publication item above or a release decision. The
engineering work under [what starts next](#what-starts-next) does not depend
on them.

- **Evidence that travels with the change.** Each run of `ci/gates.sh`
  writes a record, a clean run notes it on the commit, and the integrator
  signs what lands on `dev`. A landing check has to refuse a `dev` commit
  with no record for its tree. The record needs a signed attestation form, so
  a release ships as an evidence bundle, and a ledger page generated from the
  records. Change stacks on Jujutsu and a community front door on Rooms
  follow ([plan to plan](planning/plan-to-plan.md)).
- **Published C archives.** No versioned assets are live. Publication needs
  green packages for every target, a tagged exact-SHA release, verified live
  assets, then the `releases_published` consumer switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json) and a
  cold-cache smoke against the real release URL. The order is fixed by the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives)
  ([plan to plan](planning/plan-to-plan.md)).
- **Language package publication.** Local package rehearsals run through
  `zig build bindings-package-check`. Registry ownership, first publication,
  and cold-cache installs against hosted C archives remain release work.
  The [packaging guide](../bindings/PACKAGING.md) owns the order and intended
  names. Direct npm publication needs its own package and consumer proof
  ([plan to plan](planning/plan-to-plan.md)).

## Waiting on upstream

The `1.0` profile preserves pinned Goblins interoperability, and
`glowcap-next` tracks the merged draft. The
[conformance manifest](ocapn-conformance.md) records adopted, deferred, and
pending sections independently of the specification reference.
[Upstream watch](upstream-watch.md) holds what glowcap cannot settle alone.

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

## Waiting on hardware or a hostname

Windows support and the remaining platform and deployment checks need
target machines and recorded runs.

- **Windows and IOCP.** There is no Windows runtime check and no IOCP backend.
  Windows support needs an IOCP backend that meets the existing
  completion-loop contract in full (`validateBackend` checks it), then live
  tests and release artifacts. It waits on Windows hardware for the checks
  ([plan to plan](planning/plan-to-plan.md)).
- **Public-certificate relay URLs.** Local WSS with a fixture authority is
  checked. A public certificate at a real relay hostname is unproven across
  every execution form outside the browser
  ([known limitations](boundaries.md#browser-reachability)). It waits on a
  real relay hostname ([plan to plan](planning/plan-to-plan.md)).
- **Transport deployment coverage.** Exercise iroh between separate NATs,
  including a publishable direct address without a relay. Record the network
  setup and observed route. Record live onion load with its Tor setup,
  session count, and failure behavior. Extend non-Linux relay and runtime
  coverage, including macOS library pinning, when runners are available.
  Public-certificate work is the item above
  ([plan to plan](planning/plan-to-plan.md)).
