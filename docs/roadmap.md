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
- **macOS runtime CI.** The recurring workflow cross-compiles the kqueue path
  but never executes it. A macOS runner closes this gap.
- **Production relay URLs.** A real Chromium peer now registers a
  `noise-relay` locator through the managed WebSocket connector, and the native
  CLI cold-dials and calls it in `web-peer-test`. The native relay resident
  resolves validated DNS names and its optional pollable carrier owns WSS,
  immutable trust, SNI, and hostname verification. A recurring local gate now
  proves a real certificate chain and exact hostname refusal through that
  resident. The completion backend drives the shared TLS transform below its
  existing WebSocket machine. The same recurring real-chain matrix covers its
  lifecycle and exact TLS refusals. Its asynchronous resolver feeds a bounded
  eight-seat address race. The URL hostname remains the TLS identity.
  The recurring Chromium scenario uses local WSS and a copied fixture
  authority. Public-certificate evidence remains before the same hostname
  locator is proved across every native execution form at a public secure relay
  ([known limitations](boundaries.md#browser-reachability)).

## Scale and release

- **A live 500,000-session measurement.** Record machine, command, memory, and
  result in [the ladder](ladder.md).
- **Published C archives.** No versioned assets are live. Publication needs
  green packages for every target, the `releases_published` switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json), and a
  cold-cache smoke against the real release URL. The checklist is in the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-flip-checklist).

## Beyond the library

- **First-party failure containment.** The CLI, MCP server, rooms peer,
  relays, examples, and applications still need the same deterministic
  shutdown discipline as the library. Accepted tasks must be joined or
  canceled, networking failures must reach their command or close result, and
  optional presence, telemetry, and interface updates need explicit bounded
  loss rather than discarded errors.
- **A2A facade.** Design sketch in [`docs/planning/`](planning/); deferred by
  [ADR-0084](decisions/adr/ADR-0084-pancake-cli-product-boundary.md).
- **OpenTelemetry export.** Adapter-only OTLP off the Host and session event
  spine, enabled by `OTEL_*` or a flag, off by default, never in a
  `core = true` module.
- **The object layer.** Facts the trace tap does not report: what a session
  carries, rather than which sessions exist.
- **Control capabilities.** Observation and control stay separate grants
  ([ADR-0106](decisions/adr/ADR-0106-viz-control-capability.md)); no endpoint
  offers a control capability yet.
