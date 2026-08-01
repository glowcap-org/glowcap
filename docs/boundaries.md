# Known limitations

These are the limits that can change a deployment or API choice. This page is
not a backlog or a design history. [What ships](shipped.md) is the feature
inventory, [stability](stability.md) says how each surface is tested, and the
[roadmap](roadmap.md) owns future work.

## Transports and peer identity

- **Plain TCP and `keyed-tcp` are cleartext.** A locator's designator is the
  value that names the peer the dialer intends to reach. `keyed-tcp` binds that
  advertised identity to the CapTP handshake key, but it does not encrypt
  frames. Use iroh or WebRTC when the channel must be confidential.
- **An address is not an identity.** On plain TCP, the crossed-connection
  tiebreak trusts the location each peer declares. A peer that can connect and
  claim an address you are dialing can make your outgoing session lose that
  tiebreak. `keyed-tcp` and iroh avoid this by requiring the designator to match
  the key that signed the handshake.
- **Address aliases can open two TCP sessions.** `127.0.0.1` and `[::1]` are
  different designators until the partner-key index joins them. `keyed-tcp`
  and iroh identify the partner by key from the start.
- **`inproc` is a test transport.** Its unbounded pipes block the reading
  thread, so it is not a production or load-test substitute.
- **iroh reachability is not fully exercised in CI.** The loop checks
  multiplexing, and opt-in checks cover discovery and relay use from one host.
  They do not cover hole-punching between separate NATs.
  `discovery_no_relay` has no green check because it needs a publishable direct
  address. Goblins ships no iroh netlayer, so there is no live
  Goblins-over-iroh check.
- **A bare `webrtc` locator cannot dial.** The peer must first obtain a
  signaling channel, either out of band or as a capability. Once signaling is
  submitted, the native endpoint drives establishment and bytes through one
  readiness fd and non-blocking try-I/O. Peer creation and signaling submissions
  are still synchronous control calls, and WebRTC has no generic Host completion
  adapter, so applications use the raw readiness family or the explicit blocking
  connection.

The iroh and WebRTC transports rely on their existing sidecars; pancake does
not ship a native Zig QUIC or WebRTC stack.

## Runtime and scale

- **A Host's actor runtime (its Vat) is single-threaded and non-preemptive.** A
  hosted behavior runs synchronously to the end of its turn. A slow or blocking
  handler therefore stalls every session adapter (Port) sharing that Host. Keep
  handlers bounded. Separate Hosts provide scheduling isolation by also
  separating network identity and actor graphs; when those must remain shared,
  move blocking work out of the behavior callback instead.
- **The 500,000-session target has not been proved under live socket load.**
  Checked budgets hold the warmed protocol core near 2 KiB per session, and the
  loop checks serve many connections, but neither is a 500,000-connection run.
  [The ladder](ladder.md) carries the measured budgets.
- **The simplest blocking pump serves one connection on one fiber.** Use the
  TCP or iroh completion loop for a partner that streams while waiting for you
  to drain output.
- **`driver.PollHost` accepts only its integrated pollable transports.** TCP
  fits directly. iroh uses its completion loop. WebRTC exposes a pollable
  endpoint but does not yet have the adapter which binds those peer events to a
  Host; `inproc` and the WebRTC blocking tier use `driver.BlockingSession`.
- **Callers can still choose an infinite wait.** Zig requires an explicit
  handshake and settle budget, but `.unbounded` remains available. The CLI and
  examples use finite deadlines; library callers must make the same choice.
- **Durable bootstrap storage is not implemented.** Asking `Host.init` for
  `durable_bootstrap` currently panics. The default is ephemeral, so a
  sturdyref does not survive the process that issued it.
- **Some binding pumps copy outbound frames.** TypeScript, Python, and Racket
  copy bytes before an asynchronous write because their FFI lifetimes cannot
  retain the Zig-owned frame. Rust retains the frame across the write.
- **macOS is compiled but not run in CI, and Windows is not implemented.**
  Linux is the only platform on which the full check set runs today.

## API gaps

- **The native owning `Session` facade still exposes actor/wire references.**
  The C ABI and bindings use opaque Host-scoped capability identities, while
  several native convenience verbs still accept `actors.Ref` or
  `model.Reference`. Completing that facade migration is tracked by
  [ADR-0096](decisions/adr/ADR-0096-host-scoped-capability-identity.md).
- **Session-level enlivenment does not select or dial a peer.** It now retains
  and verifies the complete sturdyref, refusing a mismatch before wire traffic.
  The caller still selects an existing session. An accepted plain-TCP session
  cannot prove its claimed listening address and is refused by default; only
  the native low-level `assertion_only` opt-in proceeds while reporting that
  provenance. Host-level select-or-dial remains ADR-0098 step 4.
- **Listening to a promise received from a peer is native-Zig only.**
  `listenTo` exists on `driver.Session`, `driver.BlockingSession`, and the
  byte-fed Host. It is not exposed by the C ABI or the language bindings.
- **Distributed garbage collection covers fetched references only.** Near
  references, promises, sturdyrefs, bootstrap references, and redeemed
  handoffs are outside the opt-in finalizer path.
- **A host-wide published object cannot be unpublished.** Replacing a name
  changes future discovery, but there is not yet an alias-removal verb.
- **Local actors are retained for the Host lifetime.** Session closure and the
  final release of an opaque capability remove projections and registry rows,
  but do not yet collect the actor box. Earlier collection needs an explicit
  roots policy spanning aliases, gifts, queued turns, and issued capabilities.
- **CapTP `listen` is not an MCP tool.** It is available on the command line,
  where it can stay parked on accept without blocking the MCP stdio loop.
- **The public API and ABI are not stable.** There are no release tags or
  compatibility guarantees yet. Pin a commit when consuming the package.

Archive discovery and packaging are documented in the
[packaging guide](../bindings/PACKAGING.md#finding-the-archives). Windows release
assets are not published.

## Protocol and interop

- **CapTP session keys are currently reused across a Host.** This makes the
  host identity convenient for handoff verification but collapses durable node
  identity with the protocol's per-session identity. Fresh keys cannot simply
  replace them: keyed-TCP's current authentication pins the locator's durable
  key directly to `session_pubkey`, and keyed-relay shares that pin. Their byte
  channels supply no lower peer proof. iroh has a QUIC-authenticated peer key,
  and WebRTC has a capability-authorized DTLS binding, but their current
  adapters do not expose those facts to Host verification.
  [ADR-0097](decisions/adr/ADR-0097-captp-session-identity-attestation.md)
  assigns every key-designator transport an explicit binding before reuse can
  be removed. Reconnect/session-name isolation is not yet proved: an old signed
  handoff receive can resolve against a replacement session with the same names
  and consume a later deposit that reuses its session-local gift id.
- **OCapN Null is absent.** Goblins does not marshal it and the upstream
  encoding is unsettled. Unknown Syrup records remain tagged values instead.
- **Only the negotiated features are accepted.** pancake supports
  `pipelining`, `handoff`, `wire_delta`, and `sturdyref`. It does not advertise
  the draft `stream` or `equality` features, and CapTP has no `draining`
  lifecycle state here.
- **Foreign promises have a narrower path than foreign objects.** Passing a
  promise from one session as a `send` or `tell` argument on another is
  refused. A relayed settlement can carry a plain value, a break, a sturdyref,
  or a capability introduced by handoff. A promise, a locally exported object,
  or a capability nested inside a container settles broken instead.
- **Handoff is return-based.** A capability from another session can be
  returned as an answer, but it cannot be pushed as an argument. An application
  that needs to push one must pass a promise for the eventual answer instead.
- **Handoff signatures always use Syrup.** That signing domain does not change
  when the surrounding session uses Cap'n Proto.
- **Remote equality across independently established sessions is not proved.**
  Local actors keep one Host identity across Port projection and closure, and
  repeated observations of one import on one session are canonical. No
  scenario proves that the same remote target reached through another session,
  especially through handoff, reuses that identity.
- **Projection responder coverage is partly in-tree.** Field, index, and tag
  projections are implemented. The upstream suite does not cover them, and
  Goblins cannot yet marshal `op:untag`, so not every direction has a live
  outside-peer check.
- **One-way send uses `op:deliver` without an answer.** pancake does not
  implement `op:deliver-only`; neither the pinned draft, the upstream suite,
  nor Goblins defines that operation. No live Goblins check sends a `tell`
  today.
- **Two position ranges are reserved internally.** A peer-supplied import at or
  above 2^60, or answer position at or above 2^63, is refused so it cannot
  collide with pancake's internal handoff and virtual-answer ranges. Proven
  peers count upward from zero, so this fails closed before affecting them.

Cap'n Proto is a pancake-to-pancake format. The project does not publish a
fixed speed ratio between the codecs; `zig build bench-codec` measures the
current workload.

[Community review](community-review.md) is the precise outside-peer coverage
and specification-gap record.

## Browser reachability

A browser is a full peer after it has a channel, but it cannot open a listening
socket. Browser-to-browser cold dial works when both use the same relay: the
relay holds an inbound socket under the browser's keyed identity, and the CapTP
handshake still authenticates the peers end to end.

Two reachability paths are not built:

- a native peer cold-dialing a browser, because native bindings have no
  rendezvous adapter;
- a browser cold-dial across different relays, because the locator names the
  peer identity rather than a relay route.

The [roadmap](roadmap.md) owns those tasks and the unbuilt product work,
including the griddle simulator, protocol visualization, and A2A facade.
