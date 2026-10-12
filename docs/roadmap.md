# Remaining work

This page lists unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. [Upstream
watch](upstream-watch.md) tracks open OCapN and Goblins questions.

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

One I/O runtime behind every front remains. The
[open obligations](#open-obligations-from-retired-plans) hold the three steps
left.

## Visualizer measurements

The [open obligations](#open-obligations-from-retired-plans) hold one action:
measure again on the reporting machine's real GPU to decide whether GPU
tessellation needs more work.

## Release dependencies

The first-publication steps in the
[open obligations](#open-obligations-from-retired-plans) wait on maintainer
account actions. These checks follow that publication or a release decision,
and the engineering work above does not depend on them.

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

The [planning guide](planning/README.md) covers the Loam foundation, its
managed access module, Rooms, and persistence research. Nothing above blocks this work.

1. **Integrate Rooms content and access.** Use the settled interaction
   contract. Integrate recursive rooms, directory access, branching
   conversations and reorganization in the
   [Rooms phase order](planning/rooms.md#ordered-implementation-and-exit-criteria).
   Deliver the shared access editor with each integration. Exercise a second
   application to prove the foundation remains independent of chat.

The C/Rust and browser fixed-resource lifecycles are described in the
[C/Rust scope](loam/c-and-rust.md) and the
[browser scope and evidence](loam/browser.md). The exercised fixed-resource
profile does not freeze the broader foreign ABI. The remaining general graph
and owner-lifecycle projections are tracked by the
[access API contract](loam/access-api.md#the-foreign-language-boundary).

The [Rooms plan](planning/rooms.md) specifies the remaining resource work. The
[session guide](rooms/session.md) and [effect contract](rooms/session-effects.md)
describe the session that exists.
[ADR-0161](decisions/adr/ADR-0161-loam-foundation-and-access-extension.md) records
ownership.

## Open obligations from retired plans

Each row is done when its evidence sentence is true. Then delete the row.

| Lane | Remaining obligation | Evidence that closes it |
| --- | --- | --- |
| Runtime semantics ([ADR-0193](decisions/adr/ADR-0193-one-io-runtime.md)) | Retire `BlockingSession` and give dial retry, the Loam worker, and release on drop one home each, by the batches in the [one I/O runtime plan](planning/one-io-runtime.md) and its lane files ([A](planning/one-io-runtime-blocking-session.md), [B](planning/one-io-runtime-policy-home.md), [C](planning/one-io-runtime-loam-worker.md)). | The plan file is deleted: `src/driver/blocking_session.zig` is gone, no binding carries a dial-retry loop, `src/loam/hosting/worker.zig` exists, and `glowcap_host_new` takes `release_on_drop`. |
| Loam acceptance | One successful macOS run of `zig build test loam-lmdb-test` plus the four crash probes (`loam-lmdb-crash-test`, `loam-actors-crash-test`, `loam-collection-crash-test`, `loam-managed-crash-test`), recorded with revision and commands. Maintainer-owned. Needs runners the private repository does not get. | `docs/stability.md` records the run. The macOS sentences in [stability](stability.md) and [shipped](shipped.md#resource-models) change to present tense. |
| Loam | Exercise an independent non-chat application beside Rooms: plain records next to managed resources, returned facets, ancestor edits, reorganization, and restored subscriptions. Then compare backend and layout costs under matching durability before an ADR names the production profile ([architecture](loam/architecture.md#implementation-order-and-acceptance), [research](loam/research/memory-persistence.md#experiment-sequence-and-decision-points)). | The application and the comparison are in the tree and an ADR records the profile. |
| Loam | Cross-resource content changes and a general operation journal ([managed access architecture](loam/access-architecture.md#atomic-content-and-access-changes)). | A scenario commits a content change across two resources in one transaction and the journal records it. |
| Loam | Verify or fix subtree moves: the descendant-depth rewrite walks the subtree, so move cost is not yet independent of subtree size ([storage](loam/access-storage.md)). | A bench row shows move cost flat across subtree sizes, or the storage page states the dependence as a bound. |
| Loam | Publish the two unmeasured workload rows (1 million cold resources under the 32 MiB cache, browser boundary crossing counts) or remove them from the [storage contract](loam/access-storage.md). | `bench/loam/README.md` records both, or the rows are gone. |
| Visualizer | Re-measure playback on the reporting machine's real GPU with the committed stress corpus. | No visible playhead jump with the work-budget tests green. The table in `apps/ocapnviz/test-data/README.md` gains the new row. |
| Publication | Make the repository public, re-run `check` on `main` and confirm the `gates` and `macos-runtime` jobs are green, enable private vulnerability reporting, set Pages to deploy from Actions and run `pages`. Maintainer-owned. | The badge, run, and site are visible without authentication. The release section of the [release dependencies](#release-dependencies) takes over. |

## Further application work

- **Rooms public discovery.** Public directory listing stops at 256
  publications without a continuation cursor. Only the operator can page a
  complete inventory. Public listing pagination is separate from the access
  grant inventories in the plan above.
- **A2A facade.** Design sketch in [`docs/planning/`](planning/). Deferred by
  [ADR-0084](decisions/adr/ADR-0084-glowcap-cli-product-boundary.md).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module.
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist.
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0106](decisions/adr/ADR-0106-trace-observation-capability.md)). No endpoint
  offers a control capability yet.
