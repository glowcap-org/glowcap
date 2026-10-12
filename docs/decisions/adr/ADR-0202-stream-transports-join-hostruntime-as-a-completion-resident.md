---
id: ADR-0202
status: accepted
date: 2026-10-04
tags: [driver, runtime, performance, memory, net]
decision: "HostRuntime runs stream transports by presenting a completion backend as a multiplexed resident (net.completion_resident), not by owning a completion.Loop. The backend's descriptor is the resident's readiness descriptor, received bytes are lent from the backend's pool, and send staging lives in a resident-wide spare list, so an idle stream wire holds no buffer."
supersedes: []
superseded_by: []
amends: [ADR-0193]
amended_by: []
---

# ADR-0202 Stream transports join HostRuntime as a completion resident

## Context

ADR-0193 moves stream wires onto pooled completion I/O and names the shape:
HostRuntime owns one `completion.Loop` over the composed backend, with `Bridge`
as its internal adapter. A `completion.Loop` owns connection slots, admission,
outbound queues and close. HostRuntime already owns those for every wire it
runs, and for iroh and WebRTC it does so through the multiplexed resident
contract (`net/multiplexed_resident.zig`): one readiness descriptor, drained
ready records over stable connection ids, and nonblocking per-connection
reads and writes. Running a Loop inside HostRuntime would give a stream wire
two lifecycle owners, and every fix to admission or close would have two homes.

A completion backend already has the resident shape. Its operations complete on
one descriptor, connections are rows it names, and its receives land in a shared
pool.

## Decision

`net.completion_resident.Resident(Backend, Policy)` adapts a completion
backend to `MultiplexedResident`, and HostRuntime registers it like any other
resident. Stream wires become resident wires. HostRuntime gains no link kind.

- **Readiness.** The backend's `readinessFd` is the resident's descriptor.
  Each backend states that it reports every completion `poll` would return
  once `flush` has handed queued submissions to the kernel. io_uring's flush
  submits, epoll and kqueue register as they go. The resident ends each verb
  with a nonblocking poll, because an adapter can complete into its own ready
  queue where no descriptor reports it, and a wake channel armed as a
  backend readiness poll (`submitPoll`) keeps the descriptor readable while
  records wait. The poll consumes no pool buffer, and any backend that can
  answer it can host a resident.
- **Reads lend.** The contract gains an optional borrowed-read group
  (`multiplexed_resident/borrowed_read.zig`). The resident lends the one pool
  receive it holds per connection, and HostRuntime feeds the core from the
  loan, so a stream read costs the kernel's copy into the pool and nothing
  more. A runtime whose residents all lend allocates no read scratch.
  `try_read` stays for residents whose bytes cross a foreign boundary.
- **Writes stage, and idle wires hold nothing.** The contract consumes bytes
  on return while the backend borrows a send until it completes, so the
  resident copies into a per-connection staging queue bounded by
  `send_window_bytes`. HostRuntime ends each outbound drain with
  `flush_writes`, and the resident starts its send there, so a frame and its
  length prefix leave in one send rather than one per write. A drained buffer returns to a resident-wide spare list
  bounded by `spare_send_buffers` and `spare_send_bytes`, which the next
  writer reuses.
- **Transport policy is a type parameter, composed like the backends.**
  `Policy` resolves dial locators, turns a listen designator into the
  backend's `ListenTarget`, and materializes and canonicalizes listener
  locators. Each adapter supplies a policy over its inner one
  (`inproc_completion.ResidentPolicy`, `relay.ResidentPolicy`,
  `external_completion.ResidentPolicy`), and `tcp.CompletionPolicy` is the
  base. It refuses a listen host other than the interface the backend binds,
  rather than rebinding.
- **Sealing stays with the Host.** HostRuntime's byte-fed Host seals every
  `noise-tcp` and `noise-relay` session on both halves (ADR-0107), so a
  resident carries those symbols on their carriers' sockets unchanged:
  `tcp.CompletionPolicy` serves `tcp`, `keyed-tcp` and `noise-tcp`, and
  `relay.ResidentPolicy` serves `keyed-relay` and `noise-relay`.
  `onion.completion.ResidentPolicy` publishes an onion listener's bound
  loopback endpoint, advertises the service id Tor names, and reports the
  service key as the listener's restoration state. The sealing
  completion adapter (`net.noise_completion`) belongs to the loop tier, which
  has no `HostSession`, and is not part of a resident's composition.
- **A listen carries the Host's identity.** The multiplexed listen takes the
  stream listen's `netlayer.ListenConfig`: the requested designator and the
  durable key of the Host the listener serves. A key-designated profile
  publishes that key, with the bound address as a hint on TCP, and a relay
  listener registers it: the backend's registration names only the relay
  endpoint, so a runtime whose key is ephemeral can still listen there. The C multiplexed and stream listens carry
  it as `identity_designator`.
- **Listen targets are per call.** Every backend owns a `ListenTarget`, the
  listening counterpart of `ConnectTarget`: a platform backend's is the port
  it binds on its construction-time interface, and an adapter's wraps its
  platform's beside its own listener (an `inproc` designator, the relay
  registration, a provider listener). An adapter holds one listener of its
  own. `completion.Loop` names the listener its `listen` option opens through
  `loopListenTarget`.
- **One value names a runtime's transports.** `driver.Transports` lists the
  enabled first-party symbols with their deployment state (relay, Tor
  endpoints, the `inproc` exchange, foreign providers) and any caller-owned
  residents. The runtime builds one `net.StreamStack` for the symbols and
  owns it as a provider package, released after every wire and listener.
- **Failures keep their structure.** A failed completion may lend a
  structured failure chain, which the resident keeps until the runtime claims
  it, and a backend that keeps its own report (`takeConnFailure`, a foreign
  provider's `conn_take_failure`) is the exact authority at claim time.
- **Listens may finish later.** A backend that opens a listener whose setup
  finishes later declares `listenerPending` and `submitListenReady`. The
  resident returns the listen pending, emits `ev_listen` when setup ends, and
  claims the listener through the contract's `completion.finish`. The
  external adapter does this for provider listeners, so C stream tables run
  on the external resident (`provider_registry/stream_resident.zig`).
- **Fail-stop forces closing carriers.** After a runtime fail-stop no resident
  is polled, so a closing session's carrier could never report. The runtime
  forces each one closed with its terminal cause, as teardown does, and the
  resident's package release joins the physical operation.
- **Teardown is explicit.** `closeAndDrain` closes what the runtime left open
  and retires every owed operation within a deadline, fallible and
  retryable like `completion.Loop.closeAndDrain`. `deinit` requires it.
- **Platform backends serve many listeners.** The io_uring backend keeps one
  row per listener (`net/completion/uring_listeners.zig`), as epoll and
  kqueue already did.

Because HostRuntime reaches the backend directly, `Bridge` and the Loop's
connection layer serve no product front. ADR-0193's step 2 retires `Bridge`
once the scale run moves to HostRuntime, rather than keeping it as an
internal adapter.

## Scope (what this does not decide)

- The native onion adapter publishes its service in one bounded, synchronous
  Tor control conversation, so it holds the runtime's thread for up to its
  setup deadline. Declaring `submitListenReady` would let the runtime serve
  other wires meanwhile.
- The resident's onion endpoints are TCP addresses. A Unix-socket SOCKS or
  control endpoint is served only by the blocking onion netlayer.
- The resident polls once per verb. Whether that costs measurably more than a
  stream netlayer's direct syscalls is a `bench-peer-scaling` question for the
  migration step.

## Alternatives Considered

- **HostRuntime owns a completion.Loop (ADR-0193 as written).** Rejected: two
  lifecycle owners for one wire.
- **Copy reads into the runtime's scratch.** Rejected: one extra copy per read
  on every stream wire, where the pool receive is already in memory the
  resident owns.
- **Keep a steady staging buffer per connection.** Rejected: an idle wire would
  keep up to two buffers, which at the scale run's session count is the cost
  ADR-0193 removes.

## Consequences

- `MultiplexedResident` has a second read shape, chosen by capability: a
  resident lends when it owns its bytes and copies when it cannot.
- Every completion backend implements `ListenTarget`, `loopListenTarget`,
  `readinessFd`, and `flush`, and every platform backend `listenerIp4`.
- A resident read stops at the chunk that opens its session and finishes in
  `resumeFeedTails` once the open commits, so an accepting embedder publishes
  before the partner's first frames dispatch, as on a stream wire.
- A resident dial writes what its session holds as it adopts the
  connection. The connect await drains core actions, so the session's flush
  can fire before the wire exists, and a sealed dial's first handshake
  message waits in its channel, where no later flush finds it.
- `net.StreamStack` composes them: keyed-relay on the platform, onion over
  relay, `inproc` over onion, and foreign providers outermost, with the
  policies nested the same way, so one resident serves every first-party
  stream symbol. Relay sits lowest because it dials the platform's socket
  addresses. The adapters above it pass `submitPoll` through for the
  provider adapter. An unconfigured arm refuses its own symbols.
- `webrtc.ResidentPolicy` hosts `webrtc.Backend` the same way. The backend
  presents one readiness descriptor, a `net.readiness.ReadySet` over its
  signaling wake, the sidecar's readiness and the resident's wake poll. Its
  listener publishes the Host's key with no hints, since a dialer reaches
  it through its own signaling. `zig build webrtc-loop` serves its
  DataChannels from one HostRuntime thread this way.
- **Timed work bounds the wait.** A resident whose adapter retries on a
  timer (relay registration and closes, onion's owed submissions) reports
  how long the runtime may wait through `wait_bound_ms`, answered from the
  backend's `waitBoundMs`. HostRuntime waits no longer than the smallest
  bound and services the resident whose bound ended the wait, so a retry
  runs without traffic to wake it.

## Evidence and gate

- `test/driver/host_runtime_multiplexed/completion_resident_test.zig`: two
  HostRuntimes on completion residents accept, dial, call, and redeem a give
  over TCP against a stream-netlayer peer, with no runtime read scratch.
- `test/net/completion_resident_test.zig`: send-window refusal, the owed
  `ev_writable`, piecewise reads, zero staging on an idle connection, and
  `closeAndDrain` of open rows.
- `test/net/completion_listeners_test.zig` and
  `test/net/tcp_completion_policy_test.zig`, which holds each TCP profile's
  listen, dial and advertisement grammar.
- `noise_tcp_resident_test.zig` under `test/driver/host_runtime_multiplexed/`:
  `noise-tcp` listens and dials on TCP residents, and the dial proves the
  listener's key. `relay_resident_test.zig` runs `keyed-relay` and
  `noise-relay` the same way through the reference relay, and
  `onion_resident_test.zig` runs `onion` through the fake Tor daemon.
  `stream_stack_test.zig` dials `noise-tcp` and `inproc` through one
  `net.StreamStack` resident registered under both profiles.
- `inproc_resident_test.zig`, `relay_resident_test.zig`, and
  `external_resident_test.zig` under `test/driver/host_runtime_multiplexed/`,
  which replace the `Bridge` adapter tests.
