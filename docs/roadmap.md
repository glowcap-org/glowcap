# Remaining work

The list below is unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. Open OCapN and Goblins
questions are [watched separately](upstream-watch.md).

## Platforms and reachability

- **Managed Zig adapters.** Zig's owning Session and Server accept
  stream netlayers; iroh uses the completion backend or the C provider instead.
  Extending that Zig convenience API requires multiplexed provider setup
  and listener ownership, not a stream wrapper. For WebRTC, TypeScript owns
  a signaling connector; Rust, Python, and Racket expose the raw companion
  without that managed adapter.
  Zig owns a completion backend, but the Session first-call example is
  still planned. Complete signaling, cancellation, close, and dial/accept
  ownership through the existing runtime seams, then replace every `PLANNED`
  WebRTC example with a checked program in
  [`site/examples/`](../site/examples/README.md).
- **Windows and IOCP.** There is no Windows runtime check or IOCP backend.
  Windows support needs the backend behind the existing completion-loop
  contract, which is total (`validateBackend`), then live tests and release
  artifacts.
- **Public-certificate relay URLs.** Local WSS with a fixture authority is
  checked. A public certificate at a real relay hostname is still unproven
  across every execution form outside the browser
  ([known limitations](boundaries.md#browser-reachability)).

## Visualizer measurements

The [performance plan](planning/ocapnviz-backlog.md) now waits only for a
re-measure on the reporting machine's real GPU. Playback restrokes and bulk
layout work have regression checks on the committed stress corpus; the
remaining measurement determines whether GPU tessellation needs further work.

## Release dependencies

The [first-publication checklist](planning/public-release-readiness.md) waits
on maintainer account actions. These checks follow that publication or a
release decision; they are not prerequisites for the engineering work above.

- **Public release evidence.** Before an invite or release, run the exact
  release commit through the checks and macOS jobs, then verify the repository,
  badge, and run are visible without authentication.
- **Published C archives.** No versioned assets are live. Publication needs
  green packages for every target, a tagged exact-SHA release, verified live
  assets, then the `releases_published` consumer switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json) and a
  cold-cache smoke against the real release URL. The order is fixed by the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-publication-and-enablement-checklist).

## Durable applications

The [planning guide](planning/README.md) maps the Loam foundation, its included
managed access module, Rooms, and the persistence research. Complete the shared
foundation before replacing Rooms' authority and persistence paths.
The [readiness checkpoint](planning/loam/architecture.md#readiness-before-the-c-abi)
must close before starting Loam's C ABI or Rust projection. It inventories the
required Zig API and storage contracts. The [completion queue](planning/loam/completion.md)
breaks the source-verified remainder into removable tasks with dependencies and
completion evidence, separating existing mechanisms from unfinished integration.

1. **Loam persistence breadth and scale.** Record-backed sleepy actors now
   restore local capability edges and publications through the existing Host/Vat,
   with process-kill evidence. Managed working sets and transaction
   participants now use that same attachment. Extend the profile with foreign/
   cross-vat capability fields. Local tracing reclamation
   is implemented. The [Loam workload](../bench/loam/README.md) measures local
   service costs and physical page geometry; extend it with sustained storage
   pressure and concurrent foreground work. Explicit map growth is implemented; compaction and
   replacement remain to build.
   Existing measurements cover retained actor endpoints, hot/cold latency,
   cache pressure and wakeup bursts. Extend them to managed access and
   whole-process memory before widening the foreign API; keep those costs
   separate from the live-session footprint.
   An alternative backend comparison is warranted when measurements identify a
   physical-engine constraint; it is not an integration prerequisite.
   The architecture owns the implementation order; research owns the
   experiments used to assess it.
2. **Managed access integration.** Resource and grant views now share evaluation
   and preparation with the resident model. Bounded codecs and LMDB
   tests cover atomic content/grant/event records, uncertain completion, and
   reopen. Durable owner headers, sparse indexes, and bounded demand continuation
   now use Loam's shared leases and transactions. Durable use/control descriptors
   and bounded Zig capability operations also restore through that path.
   Fixed-resource use and control calls now integrate with the existing Host
   adapter, ordinary publications, and confirmed content/grant writes. Tests
   cover stale cold/queued activation and lost control acknowledgements.
   Fixed-resource derivation now commits returned facets, hidden publication
   reservations, and bounded retry receipts together, with lost-reply
   recovery. Managed content replies now disclose a stored reference field only
   through a declared exact disclosure, and an undeclared capability value fails
   closed (ADR-0172). Dependent local disclosures now admit target methods through
   both the invoking and stored target grants, and content transactions can replace
   or remove local strong fields (ADR-0173). Independent child control management
   and scoped event retention remain
   before freezing the hosted API and foreign bindings. Add representative managed workloads and
   process-loss proofs alongside the existing LMDB reopen/recovery evidence.
   Scoped use inspection now shares the admission evaluator; subscription and
   replay work must build on its disclosure contract rather than expose owner
   revisions.
3. **Rooms content and access.** Replace session-specific authority and storage
   through the common foundation. Start with a complete C/Rust resource path
   covering create, share, edit, restart, and reopen, using the existing binding
   Host and capability ownership. Then integrate recursive rooms, directory
   access, branching conversations, and reorganization. Deliver the shared
   access editor with each integration. Exercise a second application to prove
   the foundation remains independent of chat.

| Contract or evidence | Detailed plans |
| --- | --- |
| Foundation and implementation sequence | [Architecture](planning/loam/architecture.md), [API](planning/loam/api.md), [sleepy actors](planning/loam/actors.md) |
| Resource authority and storage integration | [Architecture](planning/loam/access/architecture.md), [API](planning/loam/access/api.md), [storage contract](planning/loam/access/storage.md), [implementation and acceptance](planning/loam/access/acceptance.md) |
| Research and backend evaluation | [Memory and persistence](planning/loam/research/memory-persistence.md), [persistence reuse](planning/loam/research/native-reuse.md) |
| Rooms product and integration | [Content](planning/rooms/content.md), [sharing model](planning/rooms/resource-model.md), [editor](planning/rooms/access-editor.md), [integration sequence](planning/rooms/access-grants.md) |

[ADR-0161](decisions/adr/ADR-0161-loam-foundation-and-access-extension.md) records
ownership; [known limitations](boundaries.md#api-gaps) distinguishes these plans
from the available APIs.

## Further application work

- **Rooms public discovery.** Public directory listing stops at 256
  publications without a continuation cursor; only the operator can page a
  complete inventory. Public listing pagination is separate from the access
  grant inventories in the plan above.
- **A2A facade.** Design sketch in [`docs/planning/`](planning/); deferred by
  [ADR-0084](decisions/adr/ADR-0084-glowcap-cli-product-boundary.md).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module.
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist.
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0106](decisions/adr/ADR-0106-trace-observation-capability.md)); no endpoint
  offers a control capability yet.
