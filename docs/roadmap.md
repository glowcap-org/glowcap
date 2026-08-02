# Remaining work

This page contains unfinished work only. [What ships](shipped.md) covers the
present, [known limitations](boundaries.md) covers their consequences, and
[the ladder](ladder.md) tracks progress toward 1.0.

Nothing here waits on anyone else. Open questions in OCapN and Goblins are
[watched separately](upstream-watch.md).

## Platforms and reachability

- **Windows and IOCP.** There is no Windows runtime check or IOCP backend.
  Windows support needs the backend behind the existing completion-loop
  contract, which is total (`validateBackend`), then live tests and release
  artifacts.
- **macOS runtime CI.** The kqueue path is cross-compiled on every push but
  never executed. A macOS runner closes this gap.
- **Cold-dialing browsers across relays.** Browser-to-browser and
  native-to-browser cold dial both work through one shared relay, and the
  rendezvous dial is implemented in every consumer
  (`zig build bindings-keyed-relay-rendezvous`). A cross-relay
  dial needs locators that carry a usable route as well as the peer identity
  ([ADR-0088](decisions/adr/ADR-0088-fully-functioning-browser-peer.md)).

## Scale and release

- **A live 500,000-session measurement.** The core and host have checked memory
  budgets, and the TCP and iroh loops serve many connections. The target is not
  achieved until a live run at that scale records its machine, command, memory,
  and result in [the ladder](ladder.md).
- **Published C archives.** `zig build release-pack` and the release workflow
  exist, but no versioned assets are live. Publication requires green packages
  for every target, the `releases_published` switch in
  [`bindings/c-abi-resolve.json`](../bindings/c-abi-resolve.json), and a
  cold-cache smoke against the real release URL. The full checklist is in the
  [packaging guide](../bindings/PACKAGING.md#publishing-c-archives-flip-checklist).

## Beyond the library

The deterministic simulator (`pancake griddle`), the ocapnviz protocol viewer,
and the A2A agent-to-agent facade are products built on pancake. None adds wire
semantics. Their designs live in [`docs/planning/`](planning/).
