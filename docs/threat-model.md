---
type: static
description: Who glowcap defends against, what it protects, and the parser, bound, search, and proof behind every untrusted input.
audience: human
sources:
  - resource: /src/foundation/bearer_table.zig
  - resource: /src/ocapn/session/limits.zig
  - resource: /test/fuzz_check.zig
  - resource: /test/support/session_bounds.zig
---

# Threat model

glowcap sits between a program and peers it does not trust.
[SECURITY.md](../SECURITY.md) says what counts as a vulnerability and how to
report one. The [transports page](https://glowcap.org/transports/)
says what proves who answered on each transport (OCapN calls one a netlayer),
and
[known limitations](boundaries.md#transports-and-peer-identity) says where
identity and scale stop.

## Adversaries

- **Someone on the path.** Reads, alters, replays, or drops bytes between two
  peers. On `noise-tcp`, `noise-relay`, iroh, WebRTC, and onion the channel is
  sealed end to end, so they see ciphertext. On the two Noise transports an
  altered record closes the session
  ([ADR-0041](decisions/adr/ADR-0041-sealed-byte-channels.md)). On
  `tcp`, `keyed-tcp`, and `keyed-relay` they read and can alter every frame,
  and the signed hello proves only that a session key signed the location,
  which an observer can replay.
- **A peer that speaks CapTP.** Holds a real session and sends any message the
  protocol allows, in any order, at any rate, with any value. Its goal is a
  reference it was never given, a table that grows without bound, or a process
  that stops answering its other peers.
- **A program behind a capability it was given.** Code in the same process,
  or a peer holding a legitimate reference, that uses it to reach past what
  the reference names: a deeper value than the host allows, a settle from the
  wrong thread, a capability smuggled through a plain-data channel. An AI
  agent misled by text it read acts as this adversary, even when its owner
  means well ([What about identity?](https://glowcap.org/identity/)).
- **A flood of connections.** Many sockets opened and left half-open, or many
  sessions each sending as fast as the pipe allows, to exhaust descriptors,
  memory, or the one thread an ordinary session needs.
- **An automated adversary at machine speed.** Searches the parsers and state
  machines with generated inputs faster than a person could, for the crash,
  the leak, or the table that grows past its cap. glowcap plays this
  adversary itself with the mutation fuzzers listed under
  [Untrusted inputs](#untrusted-inputs).

## Assets

- **Durable identity keys.** The Ed25519 key a peer is known by. glowcap keeps
  no key store: the program supplies the seed and keeps the secret. A sealed
  channel proves possession of the dialed key, converted for Noise
  ([ADR-0041](decisions/adr/ADR-0041-sealed-byte-channels.md)).
- **Session keys.** The per-session Ed25519 key each hello signs, and the
  Noise transport keys split at the end of a handshake. Both die with the
  session.
- **Swissnums and sturdyrefs.** A sturdyref is a bearer credential: whoever
  presents its swissnum (the secret name of one published object) fetches the
  object. A durable name is
  <!-- value ../src/ocapn/session/references/bootstrap.zig durable_swiss_entropy_len -->16<!-- /value -->
  random bytes behind a reserved prefix. The publication table compares a
  presented name in constant time over the stored name (`bearer_table`), and
  the discovery waiters compare the same way, so a near miss costs what a far
  miss costs. The table hashes under a secret the host derives from its seed,
  so which bucket a name probes says nothing about the stored name
  ([ADR-0037](decisions/adr/ADR-0037-peer-chosen-table-keys.md)). The host that published a sturdyref
  decides which peer may redeem it
  ([ADR-0007](decisions/adr/ADR-0007-sturdyrefs-and-publication.md)).
- **The export, import, and answer tables.** Every reference a peer holds is a
  row in these, and session state alone decides whether a row exists. A codec
  only decodes positions. A table keyed by positions the
  peer chooses hashes them under a per-session secret, so chosen collisions
  cannot turn a lookup into a scan
  ([ADR-0037](decisions/adr/ADR-0037-peer-chosen-table-keys.md)).
- **The process.** Its memory, its descriptors, and the thread that runs every
  turn. glowcap ends the process only for its own broken invariants. Bad
  input, I/O failure, resource pressure, and a callback's refusal return
  errors, and a wire-fatal refusal retires exactly one session.

## Untrusted inputs

One entry per input a peer or a program supplies. "Read by" is the code that
meets the bytes. "Bounded by" is the limit it refuses past, from
`SessionLimits` unless another file is named. "Searched by" is the mutation
fuzzer under `test/` that drives it, a search [stability](stability.md#which-checks-recur)
says when it runs. "Refusal proved by" is the test that pins the refusal.

**Stream bytes, cut at any read boundary**

- Read by: `stream_framing.parsePrefix`, through `net.recvOuterPrefix` and `Host.feedBytes`
- Bounded by: `max_frame_bytes`, default <!-- value ../src/ocapn/session/limits.zig default_max_frame_bytes bytes -->1 MiB<!-- /value -->, checked on the length prefix before the body is read
- Searched by: `engine/fuzz_test.zig`, `driver/fuzz_test.zig`, and `net/fuzz_test.zig` for a frame that spills past the read buffer
- Refusal proved by: `driver/core_host/redeem_test.zig` (an outer length over the cap is refused before its body), `engine/completion_seam_test.zig` (both codecs, the exact cap, and a declared length over the cap refused before its body)

**A Syrup frame**

- Read by: the Syrup decoder under `codec/syrup/`
- Bounded by: `max_decode_nesting` in `codec/limits.zig`, the frame cap, and `max_nesting_depth` on the argument tree at validation
- Searched by: `codec/fuzz_test.zig` (the whole-frame decode and the owned materializer), and `zig build goblins-differential` (the same mutated frames fed to a live Goblins vat and to glowcap, for a person to triage)
- Refusal proved by: `codec/syrup/decode_test.zig` (a collection wider than the element cap), `session/traffic_test.zig`. An inbound deliver nested past `max_nesting_depth` is refused with `NestingTooDeep`. A send-side deliver or fulfill nested past it is refused with the export refcount unchanged, before any export is retained. `codec/whole_frame_test.zig` refuses at `max_decode_nesting` exactly, an empty innermost collection included, and a frame thousands deep fails without touching the stack limit.

**A Cap'n Proto frame**

- Read by: the Cap'n Proto decoder under `codec/capnp/`
- Bounded by: a traversal budget of `traversal_budget_words_per_segment_word` words per segment word with a floor, so an aliasing graph cannot amplify
- Searched by: `codec/fuzz_test.zig` (borrowed decode and owned projection)
- Refusal proved by: `codec/capnp_malformed_test.zig` (an aliasing DAG exhausts the budget, an aliasing hint list is charged, a multi-segment frame is refused)

**A message against live session state: deliver, resolve, listen, release, GC, abort**

- Read by: `session.validate`, then the engine's dispatch into the tables
- Bounded by: `max_imports`, `max_inbound_answers`, `queue_cap`, `max_listeners_per_target`, `max_resolution_chain`, `max_local_deliveries`, `max_retained_sent_answer_bytes`, `max_queued_call_bytes`, `max_compare_visits`
- Searched by: `engine/fuzz_test.zig` and `driver/fuzz_test.zig`, which drive a program to build live tables and then hold `max_imports`, `max_inbound_answers`, `queue_cap`, `max_listeners_per_target`, the nesting depth, and the frame cap after each step (`support/session_bounds.zig`). The other four bounds are not searched
- Refusal proved by:
  - `max_resolution_chain`: `engine/projection_test.zig` (a distinct chain past the bound breaks the answer with the bound named)
  - `max_local_deliveries`: `engine/peer/pipeline/fail_closed_test.zig` and `engine/resolve_window_test.zig` (`LocalDeliveryCapExceeded` closes the session with an abort)
  - `max_retained_sent_answer_bytes`: `engine/node/answer_settlement_test.zig` (`RetainedAnswerCapExceeded`)
  - `max_queued_call_bytes`: `session/resolver_test.zig` (`QueuedCallBytesExceeded` refuses the call that would carry the session's queued pipelined calls past the budget, and draining an answer's queue returns its charge)
  - `max_compare_visits`: `session/set_uniqueness_test.zig` (`CompareBudgetExhausted`)
  - A `near` the partner never received or has released: `session/grant_test.zig`, `engine/resolver_export_test.zig` and `engine/peer/v1_translation/gc_test.zig` (every door holds it to the partner's wire hold, so a resolver callback at a guessed or released export is refused `InvalidReference` like any other reference)
  - A `desc:answer` with no live question: `session/answer_test.zig` (held to the asker's live questions as a target, an argument, or a payload)
  - The abort path: `engine/abort_projection_test.zig` and `driver/host_runtime_step/refused_partner_release_test.zig` (releasing the session one partner's refused frame ended leaves the runtime serving everyone else)

**A hello (`op:start-session`)**

- Read by: `validateStartSession`, then the signature check in `engine/hello.zig`
- Bounded by: the CapTP version must match, `max_count` locator hints in `model/hints.zig`, and the handshake deadline the caller sets
- Searched by: `session/fuzz_test.zig` (route lists), `model/fuzz_test.zig` (locator text)
- Refusal proved by: `engine/pairing/signature_test.zig` (a signature that does not match the claimed key, tampered hint bytes), `session/lifecycle_test.zig` (a version mismatch)

**A locator or sturdyref as text, in a hello, a handoff, or from a program**

- Read by: the `ocapn://` parser in `model/`
- Bounded by: `max_route_list_count` and `max_route_list_bytes` in `model/route_bundle.zig`, and `max_count` hints
- Searched by: `model/fuzz_test.zig`
- Refusal proved by: `model/uri_test.zig`, `net/keyed_tcp_test.zig` and `net/noise_tcp_test.zig` (a designator of the wrong kind is refused before any I/O)

**A third-party handoff: a give, a receive, a withdrawal**

- Read by: `validateInboundHandoffArgument`, then the gift registry and signatures under `engine/bootstrap/`
- Bounded by: `max_deposited_gifts`, `max_deposited_gift_bytes`, `max_pending_withdraws`, and a handoff count that never repeats
- Searched by: `driver/fuzz_test.zig` (the receive a recipient really sent, fed to the exporter verbatim, with bytes of the certificate flipped, or with bytes of one signature flipped, each under a fresh answer)
- Refusal proved by: `engine/cross_peer/authority_test.zig` (a give signed by the wrong key, a replayed count, a withdrawal whose signature fails), `engine/gift_registry_test.zig`

**A sturdyref fetch, by swissnum**

- Read by: the publication lookup in `driver/core/` and the session's bootstrap table
- Bounded by: names this process minted, compared in constant time (`bearer_table`), and an unknown name breaks the fetch
- Searched by: not searched
- Refusal proved by: `engine/fetch_test.zig` (a partner-side break settles the fetch as broken with its reason "unknown swissnum", in the `op:resolve` form and in the symbol-shaped resolver-callback form), `session/bootstrap_test.zig` (an unregistered name finds no export), `foundation/bearer_table_test.zig` (the exact key is found, and a changed last byte, a prefix, an appended byte, and the empty name are not). Constant time holds by construction through `std.crypto.timing_safe` and is not measured

**A Noise handshake message**

- Read by: `HandshakeState.readMessage`
- Bounded by: each message's exact size by shape, and `max_message_bytes`
- Searched by: `foundation/fuzz_test.zig` (a damaged message at either role never advances the transcript)
- Refusal proved by: `foundation/noise_test.zig` (tampered, replayed, truncated, oversized, split too early), `driver/sealed_channel_test.zig` (a replay at a fresh responder, a responder holding a different key, a sign-bit alias)

**A sealed record**

- Read by: `SealedChannel.ingest`
- Bounded by: `max_record_bytes` per record, the frame cap on the plaintext, and a nonce that refuses its reserved value
- Searched by: `foundation/fuzz_test.zig` (a damaged record never opens, and a split lands anywhere)
- Refusal proved by: `foundation/noise_test.zig` (a plaintext one byte over the record maximum is refused when sealing, and the reserved nonce is refused in both directions), `driver/sealed_channel_test.zig` (a plaintext frame cannot bypass the channel, a split header, an allocation failure mid-record)

**Session traffic as a flood**

- Read by: the host's per-turn budget and the completion loop's deadlines
- Bounded by: the outbound high-water mark per connection, `park_kill_ms` when the embedder sets one (off by default), the turn budget per session, and the close deadline after which a completion resident drops a closed connection the partner never reads, with its read buffer returned (a C provider's asynchronous close is its own, reported through its closed record)
- Searched by: none (the input is not bytes)
- Refusal proved by: `driver/core_host_budget_test.zig` (a flood fed on one connection and landing on a sibling condemns the sibling with a close action and `LocalTurnLimitExceeded`, while the feeding connection survives), `net/completion_loop_deadlines_test.zig` (a connection whose queue crosses the outbound mark gets a `park_kill` deadline, and draining the queue clears it), `driver/host_runtime_multiplexed/provider_test.zig` (an always-ready resident cannot starve a sibling), `net/completion_loop_backpressure_test.zig`, `net/completion_resident_test.zig` (a close the partner never reads holds no read buffer, and the abort ends it)

**Half-open handshakes in bulk**

- Read by: `HostRuntime` accepting connections, behind the completion resident's listener
- Bounded by: `max_pending_opens`, default <!-- value ../src/driver/host_runtime.zig default_max_pending_opens -->256<!-- /value -->, and the handshake deadline, default <!-- value ../src/driver/core/vocab.zig default_handshake_timeout_ms milliseconds -->10 seconds<!-- /value -->. A listener holds at most `max_unclaimed_accepts` accepted sockets the runtime has not claimed and stops accepting past that, so arrivals wait in the kernel's listen backlog. A frame that arrives before the handshake completes is held to the same `max_frame_bytes` as every other, so `max_pending_opens` times that cap is the most a flood of half-open peers can make the host hold. An accept the kernel refuses for descriptor quota is not retried against the same quota: the resident hands the refusal to the runtime, which closes that listener and reports it to the embedder
- Searched by: none (the input is not bytes)
- Refusal proved by: `net/completion_resident_test.zig` (a listener stops accepting at the unclaimed bound and resumes on a claim, and an accept refused for descriptor quota reaches the claim as a failure and does not re-arm), `driver/host_runtime_step/flood_test.zig` (the slots all held by handshakes that never finish, the next arrival refused, the accepted count held, and an honest session opening once the deadline frees them) and `driver/host_runtime_step/serve_test.zig` (an arrival while a slot is held closes with no session)

**Tor control and SOCKS replies, text from a daemon the operator runs**

- Read by: `parseLine` in `net/transport/onion/control.zig` and the SOCKS5 reader
- Bounded by: one bounded line per reply, and a request that does not fit its buffer is refused rather than truncated
- Searched by: `net/fuzz_test.zig` (every reply line up to `max_line_bytes` and every SOCKS5 head the parsers can be handed, so the over-long line refusal is out of its reach)
- Refusal proved by: `net/onion_control_test.zig` (a request too long for its buffer is refused with `LineTooLong`, a unit test of the control request writer only), `net/onion_socks5_test.zig` (malformed heads and service ids), and no SOCKS5 over-long test

**Values a program passes into a call or a settle**

- Read by: the host's lift and lower, and the settle mailbox
- Bounded by: `max_value_depth` in `model/mod.zig`, and the mailbox's size and plain-data rule
- Searched by: none (the input is not bytes)
- Refusal proved by: `driver/core_host/capability_projection_test.zig` (exactly the depth limit), `driver/off_turn_settle_test.zig` (full, oversized, and capability-bearing posts refuse)

## What glowcap does not defend

- **Authorization and rate.** glowcap checks only that a caller holds the
  capability it calls. Who receives one, how often a holder may call, and how
  long a call may take are the program's to decide, above the library.
- **A person's identity, and the front door.** glowcap proves which key a
  peer holds on a sealed transport, and only the session key on a cleartext
  one. Who gets a key, and what proof the door asks for, is the
  application's ([What about identity?](https://glowcap.org/identity/)).
- **An agent talked into using its key.** A narrow capability limits what a
  misled agent can reach. Whether the agent uses it well is up to the agent
  and its owner.
- **Confidentiality on a cleartext netlayer.** `tcp`, `keyed-tcp`, and
  `keyed-relay` carry CapTP in the clear.
- **Memory inside the process.** A program linked with glowcap shares its
  address space. Capabilities limit what a peer can reach, and they cannot
  stop code in the same process from reading its memory.
- **Traffic analysis.** The sizes and timing of sealed records are visible on
  the path.
- **The program's secrets and entropy.** glowcap signs with the seed it is
  given and cannot tell whether it is sound. On a cleartext netlayer a hello
  reflected back to its sender verifies under its own key, and only a sealed
  transport rules that out.
- **Calls off the owner thread.** One thread drives a Host at a time. A verb
  from another thread is refused `WrongThread` before it touches Host state,
  and a wake (`glowcap_driver_wake`) is the one call any thread may make while
  the driver lives. Ordering a wake against the driver's release is the
  embedder's, like any free.
- **A storage directory it did not write.** Loam reads its own files and
  stays running on a short or failed read, and it recovers from the restore
  locators its controller names. A data directory another program crafted is
  not an input it defends against, and the controller chooses which locators
  a restore may trust.
- **Why a fetch was refused.** A fetch the host refuses breaks with the
  refusal's name (capacity, recovery, corruption), so a peer can tell a
  retryable refusal from a missing name, and so it learns which one it was.
- **Where a peer tells it to dial.** A relay hint in a hello and the exporter
  locator in a handoff name an address, and the host dials it on the
  transports it negotiated, at most `max_pending_opens` at a time. Whether a
  program should reach that address is the program's to decide, above the
  host.
- **How much a peer with a grant may store.** Loam derives from a grant until
  the store reaches `map_bytes`, and it keeps no quota per peer. The
  controller sizes the store with `Lmdb.grow` and chooses the grant depth it
  hands out.
