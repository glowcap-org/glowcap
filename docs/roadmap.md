# Remaining work

This page lists unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. Open OCapN and Goblins
questions are [watched separately](upstream-watch.md).

## Platforms and reachability

- **Windows and IOCP.** There is no Windows runtime check or IOCP backend.
  Windows support needs the backend behind the existing completion-loop
  contract, which is total (`validateBackend`), then live tests and release
  artifacts.
- **Public-certificate relay URLs.** Local WSS with a fixture authority is
  checked. A public certificate at a real relay hostname is still unproven
  across every native execution form
  ([known limitations](boundaries.md#browser-reachability)).

## Release

- **Public release evidence.** The repository is still private, and GitHub
  Actions currently refuses to start its jobs because of the account's
  payment/spending state. Before an invite or release, restore job execution,
  make the prepared repository public, run the exact release commit through the
  checks and macOS jobs, and verify the repository, badge, and run are visible
  without authentication.
- **Published C archives.** No versioned assets are live. Publication needs
  green packages for every target, a tagged exact-SHA release, verified live
  assets, then the `releases_published` consumer switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json) and a
  cold-cache smoke against the real release URL. The order is fixed by the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-publication-and-enablement-checklist).

## Rooms capability completion

- **Shareable archives.** The bounded member-owned `put`/`read` archive
  capability, the tab's IndexedDB implementation, and a durable standalone
  archive peer ship, with recorder source and conversation generation retained
  in every key. Advanced Settings selects that peer explicitly, optionally
  remembers its whole-archive bearer, and reports an unreachable selection
  without silently forking writes into the device store. The archive can mint
  monotonic scoped and read-only facets, and a direct-conversation card hands
  the other member only that line's read facet for an explicit one-shot read or
  give-back. The remaining work is room and standing handover, independently
  revocable or durable offers, multi-source views, and durable attachment homes
  addressed by hash. The design is in
  [`docs/planning/rooms-persistence.md`](planning/rooms-persistence.md).
## Beyond the library

- **A2A facade.** Design sketch in [`docs/planning/`](planning/); deferred by
  [ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module.
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist.
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0106](decisions/adr/ADR-0106-viz-observation-capability.md)); no endpoint
  offers a control capability yet.
