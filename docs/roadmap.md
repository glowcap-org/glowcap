# Remaining work

The list below is unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. Open OCapN and Goblins
questions are [watched separately](upstream-watch.md).

## Platforms and reachability

OS portability and platform acceptance, including Windows with IOCP and
macOS validation, are release obligations the maintainer runs. The items
below are the integration work for language bindings and browser execution
and storage, in order.

- **Managed WebRTC adapters.** TypeScript has a managed signaling connector.
  Rust, Python and Racket expose the raw companion without that adapter.
  Zig has a completion backend, but its Session first-call example is planned.
  Finish signaling, cancellation, close, and dial and accept ownership through
  the existing provider interfaces. Then replace every `PLANNED` WebRTC example
  in [`site/examples/`](../site/examples/README.md) with a checked program.
- **Windows and IOCP.** There is no Windows runtime check and no IOCP backend.
  Windows support needs an IOCP backend that meets the existing
  completion-loop contract in full (`validateBackend` checks it), then live
  tests and release artifacts.
- **Public-certificate relay URLs.** Local WSS with a fixture authority is
  checked. A public certificate at a real relay hostname is still unproven
  across every execution form outside the browser
  ([known limitations](boundaries.md#browser-reachability)).

## Runtime and capability semantics

The [runtime semantics plan](planning/runtime-semantics.md) holds the gaps an
outside OCapN review found. Far sends retract with a failed turn and keep
their order through Node staging; one I/O runtime behind every front remains.

## Visualizer measurements

The [performance plan](planning/ocapnviz-backlog.md) waits on one thing: a new
measurement on the reporting machine's real GPU. Playback restrokes and bulk
layout work already have regression checks on the committed stress corpus.
That measurement will show whether GPU tessellation needs more work.

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
managed access module, Rooms, and persistence research. The platform and
reachability work above is independent of them. GPU measurement, upstream agreement, and the maintainer's
publication steps each wait on their own conditions and do not block these.

1. **Integrate Rooms content and access.** Use the settled interaction
   contract. Fixed-resource registration and managed-control helpers are proved
   on C/Rust and browser consumer paths. Rooms session schema, requirement,
   preset and typed custody declarations have application proofs and generated
   browser metadata. Shared saved-reference fields and bounded record codecs
   have consumer and portable proofs. Persisted dependencies and session kind
   applicability are enforced; shared callbacks receive trusted resource context.
   Production startup and browser consumers use managed session authority and storage.
   The [managed session](rooms/session.md)
   passes production browser and runtime acceptance. The
   [session measurements](../bench/rooms/session-costs.md) record allocation and traversal costs.
   Integrate recursive
   rooms, directory access, branching conversations and reorganization in the
   [Rooms phase order](planning/rooms/access-grants.md#ordered-implementation-and-exit-criteria).
   Deliver the shared access editor with each integration. Exercise a second
   application to prove the foundation remains independent of chat.

The C/Rust and browser fixed-resource lifecycle and bounded managed-control helpers are implemented
([C/Rust scope](loam/c-and-rust.md), [browser scope and evidence](loam/browser.md)).
The [completion queue](planning/loam/completion.md) retains the
maintainer's macOS acceptance. The exercised fixed-resource profile does not freeze the broader foreign ABI.
The remaining general graph and owner-lifecycle projections
are tracked by the [access API contract](planning/loam/access/api.md#the-foreign-language-boundary).

The Rooms contract is split by owner: [operation authority](planning/rooms/authority.md),
[storage and budgets](planning/rooms/persistence.md),
[consumer and recovery inventory](planning/rooms/integration.md),
and [sharing walkthroughs](planning/rooms/scenarios.md). These specify the remaining
recursive resource work. The [session guide](rooms/session.md) and
[effect contract](rooms/session-effects.md) describe the implemented session.

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
