# Remaining work

The list below is unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0. Open OCapN and Goblins
questions are [watched separately](upstream-watch.md).

## Platforms and reachability

- **Managed native adapters.** Native Zig's owning Session and Server accept
  stream netlayers; iroh uses the completion backend or the C provider instead.
  Extending that native convenience API requires multiplexed provider setup
  and listener ownership, not a stream wrapper. For WebRTC, TypeScript owns
  a signaling connector; Rust, Python, and Racket expose the raw companion
  without that managed adapter.
  Native Zig owns a completion backend, but the Session first-call example is
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
  across every native execution form
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

## Beyond the library

- **Rooms discovery and invitations.** Public directory listing stops at 256
  publications without a continuation cursor; only the operator can page a
  complete inventory. One-shot room invitations do not survive a server
  restart as individually revocable sturdyrefs. These are separate product
  extensions with their current contracts in
  [known limitations](boundaries.md#api-gaps).
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
