---
type: static
description: Who glowcap defends against, what it protects, and the parser, bound, search, and proof behind every untrusted input.
audience: human
sources:
  - resource: /src/foundation/bearer_table.zig
  - resource: /src/ocapn/session/limits.zig
  - resource: /test/fuzz_check.zig
  - resource: /test/support/session_bounds.zig
  - resource: /src/ocapn/session/audit.zig
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
  A browser using an iroh gateway trusts that gateway with plaintext and the
  peer's identity. QUIC terminates there, as
  [browser reachability](boundaries.md#browser-reachability) explains.
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
- Refusal proved by: `driver/core_host/redeem_test.zig` (an outer length over `max_frame_bytes` is refused before its body), `engine/completion_seam_test.zig` (both codecs, the exact cap, and a declared length over the cap refused before its body)

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

- Read by: `session.validate`, one arm per operation (`op:deliver`, `op:resolve`, `op:listen`, `op:get`, `op:index`, `op:untag`, `op:gc-export`, `op:gc-answer`, `op:abort`), then the engine's dispatch into the tables. The three projection operations hold their receiver to the same rule as a deliver's target and share the listener cap
- Bounded by: `max_imports`, `max_inbound_answers`, `queue_cap`, `max_listeners_per_target`, `max_resolution_chain`, `max_local_deliveries`, `max_retained_sent_answer_bytes`, `max_queued_call_bytes`, `max_compare_visits`. `max_lifted_answers` bounds the partner's open questions the Host holds as capability promises, each one retain on the answer and one row until it settles. A release also runs the local promise collector, whose trace walks every retained value, so it traces once per interval of releases and the interval grows with that walk (`local_promise_gc.zig`): a flood of one-line GC messages cannot buy a scan per message
- Searched by: `engine/fuzz_test.zig` and `driver/fuzz_test.zig`, which drive a program to build live tables and then hold `max_imports`, `max_inbound_answers`, `queue_cap`, `max_queued_call_bytes`, `max_retained_sent_answer_bytes`, and `max_listeners_per_target` after each step (`support/session_bounds.zig`), along with the local accounting relations checked by `session.audit`, under a frame cap and a nesting depth small enough for a short program to cross. `max_resolution_chain`, `max_local_deliveries`, and `max_compare_visits` are budgets one operation spends with no table to hold, so only their refusals below are proved. The second `engine/fuzz_test.zig` target runs the same program between two conforming peers and, once the wire settles, holds the two sessions to each other: every import is a mention the partner made that many times, every open question an answer the partner still owes, and every settled answer has drained its work
- Refusal proved by:
  - `max_imports`: `session/grant_test.zig` (the registration past the cap is refused)
  - `max_inbound_answers`: `session/answer_test.zig` (the question past the cap is refused)
  - `queue_cap` and `max_listeners_per_target`: `session/resolver_test.zig` (the pipelined call and the listener past their caps fail loud), `engine/projection_test.zig` (the `op:get` past the shared cap is refused loud)
  - `max_resolution_chain`: `engine/projection_test.zig` (a distinct chain past the bound breaks the answer with the bound named), `session/imported_promise_test.zig` (a shortening callback whose target walk exhausts the budget is refused `ShorteningChainTooLong`, and a rewrite stops within the budget even when later callbacks extend its path, while release drains the entire retained chain)
  - `max_local_deliveries`: `engine/peer/pipeline/fail_closed_test.zig` and `engine/resolve_window_test.zig` (`LocalDeliveryCapExceeded` closes the session with an abort)
  - `max_retained_sent_answer_bytes`: `engine/node/answer_settlement_test.zig` (`RetainedAnswerCapExceeded`)
  - `max_queued_call_bytes`: `session/resolver_test.zig` (`QueuedCallBytesExceeded` refuses the call that would carry the session's queued pipelined calls past the budget, and draining an answer's queue returns its charge)
  - `max_compare_visits`: `session/set_uniqueness_test.zig` (`CompareBudgetExhausted`)
  - The collector's pacing: `engine/peer/pipeline_local_promise_test.zig` (a release flood traces once per interval, and a projection nothing holds is reclaimed by the next trace)
  - A `near` the partner never received or has released: `session/grant_test.zig`, `engine/resolver_export_test.zig` and `engine/peer/v1_translation/gc_test.zig` (every door holds it to the partner's wire hold, so a resolver callback at a guessed or released export is refused `InvalidReference` like any other reference)
  - A `desc:answer` with no live question, or an unheld `near`: `session/answer_test.zig` (held to the asker's live questions as a target, an argument, or a payload, in every nesting shape on every carrier, with no table row changed by the refusal)
  - A promise received as a call argument: `driver/promise_argument_test.zig` (it lifts to a capability promise that settles with the answer, one row per question, past `max_lifted_answers` the one call fails and the session stays open, and the partner releasing the question or closing the session settles or breaks it without a leak)
  - The abort path: `engine/abort_projection_test.zig` and `driver/host_runtime_step/refused_partner_release_test.zig` (releasing the session one partner's refused frame ended leaves the runtime serving everyone else)

**A hello (`op:start-session`)**

- Read by: `validateStartSession`, then the signature check in `engine/hello.zig`
- Bounded by: the CapTP version must match, `max_count` locator hints in `model/hints.zig`, and the handshake deadline the caller sets. A verifying peer also refuses a hello that claims its own session key, which is its hello reflected back by a cleartext path and verifies under that key
- Searched by: `session/fuzz_test.zig` (route lists), `model/fuzz_test.zig` (locator text)
- Refusal proved by: `engine/pairing/signature_test.zig` (a signature that does not match the claimed key, tampered hint bytes, the peer's own hello reflected back), `session/lifecycle_test.zig` (a version mismatch)

**A locator or sturdyref as text, in a hello, a handoff, or from a program**

- Read by: the `ocapn://` parser in `model/`
- Bounded by: `max_route_list_count` and `max_route_list_bytes` in `model/route_bundle.zig`, and `max_count` hints. A sturdyref a partner resolves is enlivened once and remembered, and `max_sturdyref_cache_entries` bounds that memory by evicting the oldest, since a miss costs one fetch and no correctness
- Searched by: `model/fuzz_test.zig`
- Refusal proved by: `model/uri_test.zig`, `net/keyed_tcp_test.zig` and `net/noise_tcp_test.zig` (a designator of the wrong kind is refused before any I/O), `engine/sturdyref_test.zig` (`max_sturdyref_cache_entries` evicts the oldest entry past the cap)

**A third-party handoff: a give, a receive, a withdrawal**

- Read by: `validateInboundHandoffArgument`, then the gift registry and signatures under `engine/bootstrap/`
- Bounded by: `max_deposited_gifts`, `max_deposited_gift_bytes`, `max_pending_withdraws`, and a handoff count that never repeats. A give the Host redeems inline holds a promise row until the exporter answers, and those rows count against the giving session's `max_pending_withdraws` beside its parked withdraws
- Searched by: `driver/fuzz_test.zig` (the receive a recipient really sent, fed to the exporter verbatim, with bytes of the certificate flipped, or with bytes of one signature flipped, each under a fresh answer)
- Refusal proved by: `engine/cross_peer/authority_test.zig` (a give signed by the wrong key, a replayed count, a withdrawal whose signature fails), `engine/gift_registry_test.zig` (`max_deposited_gifts`), `engine/gift_registry_budget_test.zig` (`max_deposited_gift_bytes` saturates on a whole new row, and a replacement that would grow past it leaves the row it would replace in place), `engine/cross_peer/parked_admission_test.zig` (a second early withdraw past `max_pending_withdraws` refuses loud and projects `resource_exhausted`), `driver/core_host/give/pending_cap_test.zig` (an inline give past the same bound is refused before it retains a capability or stores a row, and a settled redemption frees its seat)

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

**Allocation failure while a frame is applied**

- Read by: every allocating door of `Peer`, which are `recvBorrowed`, `feedOwned`, `step`, and the sends (`recvPacket` and `stepToIdle` are the first and third called in a loop, and the Host's `feed` verbs reach the same doors)
- Bounded by: the allocator alone. The contract is two states and no third. The borrowed door commits nothing, and the Host offers the same bytes again. The owned door and the dispatch close the session, recording `OutOfMemory`. A send or a step leaves its message queued for a retry. No path applies half a frame or forgets one
- Searched by: `engine/allocation_failure_test.zig` (a program between two conforming peers run once per allocation site with that one allocation refused, and once per site with every allocation from it on refused, under both profiles). Each run ends with the pair agreeing about every row or with the refused peer closed for memory, and with every byte it took returned
- Refusal proved by: the same test, and `driver/sealed_channel_test.zig` (an allocation failure mid-record)

**Session traffic as a flood**

- Read by: the host's per-turn budget and the completion loop's deadlines
- Bounded by: the outbound high-water mark per connection, `park_kill_ms` when the embedder sets one (off by default), the turn budget per session, and the close deadline after which a completion resident drops a closed connection the partner never reads, with its read buffer returned (a C provider's asynchronous close is its own, reported through its closed record)
- Searched by: none (the input is not bytes)
- Refusal proved by: `driver/core_host_budget_test.zig` (a flood fed on one connection and landing on a sibling condemns the sibling with a close action and `LocalTurnLimitExceeded`, while the feeding connection survives), `net/completion_loop_deadlines_test.zig` (a connection whose queue crosses the outbound mark gets a `park_kill` deadline, and draining the queue clears it), `driver/host_runtime_multiplexed/provider_test.zig` (an always-ready resident cannot starve a sibling), `net/completion_loop_backpressure_test.zig`, `net/completion_resident_test.zig` (a close the partner never reads holds no read buffer, and the abort ends it)

**Half-open handshakes in bulk**

- Read by: `HostRuntime` accepting connections, behind the completion resident's listener
- Bounded by: `max_pending_opens`, default <!-- value ../src/driver/host_runtime.zig default_max_pending_opens -->256<!-- /value -->, and the handshake deadline, which a Zig `HostRuntime` caller names and the C driver defaults to <!-- value ../src/driver/core/vocab.zig default_handshake_timeout_ms milliseconds -->10 seconds<!-- /value -->. The deadline is stamped once when an open starts and covers its transport connect and CapTP handshake, and sessions that finished opening are held to `max_sessions`, default <!-- value ../src/driver/core/host/configuration.zig default_max_sessions -->1,024<!-- /value --> per Host, refused `SessionLimitReached` at mint with nothing reserved. Redeem dials a partner's handoffs induce hold at most `max_pending_redeem_dials` of the pool, a quarter of it unless the caller says otherwise, so gives naming silent exporters leave accepts and the application's own dials room. A listener holds at most `max_unclaimed_accepts` accepted sockets the runtime has not claimed and stops accepting past that, so arrivals wait in the kernel's listen backlog. A frame that arrives before the handshake completes is held to the same `max_frame_bytes` as every other, so `max_pending_opens` times that cap is the most a flood of half-open peers can make the host hold. An accept the kernel refuses for descriptor quota is not retried against the same quota: the resident hands the refusal to the runtime, which closes that listener and reports it to the embedder, and the completion loop returns it from `run`. An accept that failed on its own arrival (a reset before accept took it, a refused socket option) is dropped and the listener keeps serving
- Searched by: none (the input is not bytes)
- Refusal proved by:
  - `net/completion_resident_test.zig` (a listener stops accepting at the unclaimed bound and resumes on a claim, and an accept refused for descriptor quota reaches the claim as a failure and does not re-arm)
  - `net/completion_loop_backpressure_test.zig` (an arrival-local accept failure leaves the loop serving and the next arrival is admitted, and a descriptor-quota failure returns from `run`)
  - `driver/host_runtime_step/flood_test.zig` (the slots all held by handshakes that never finish, the next arrival refused, the accepted count held, and an honest session opening once the deadline frees them). The same file holds redeem dials to their share while an accept and an application dial still admit
  - `driver/host_runtime_handoff_test.zig` (a zero share or one above the pool is refused at construction)
  - `driver/host_runtime_step/serve_test.zig` (an arrival while a slot is held closes with no session)
  - `driver/core_host/session_cap_test.zig` (the mint at the cap refused, a release freeing the seat, the setter moving the cap, zero refused at construction)

**A WebSocket frame or relay upgrade response**

- Read by: `parseHeaderBytes` and `UpgradeResponseValidator` in `net/websocket/client_protocol.zig`, through the keyed-relay blocking reader (`keyed_relay/blocking_frame.zig`, `keyed_relay/upgrade.zig`), the stream reader (`keyed_relay/stream.zig`), and `consumeUpgrade` in `keyed_relay/completion/dispatch.zig`. The relay URL and the `rendezvous-relay` hint are read by `RelayUrl.parse` and `relayHint` in `keyed_relay/route.zig`
- Bounded by:
  - The upgrade and the relay's address: `max_upgrade_response_bytes` caps the HTTP response, refused `UpgradeResponseTooLarge` by the completion reader and `UpgradeRefused` by the blocking one. A relay hostname's answer seats at most `max_resolved_addresses` addresses, and one more fails the dial `TooManyAddresses` at the resolve phase. Both carriers drain the answer while the lookup runs, so a long answer cannot park the resolver, and a lookup with no free unit of concurrency is refused instead of run inline
  - Frames: a header with a reserved bit, a mask, a text or unknown opcode, or a length not minimally encoded is refused `ProtocolViolation`, and so is a control frame past `max_control_payload` or split across fragments. A data payload is streamed and never sized from its header. `RelayInputOverflow` refuses raw bytes past `raw_in_limit`, the read buffer plus `steady_raw_in_bytes`. `max_frames_per_read` hands the turn back after that many frames in one read, so empty data frames and unsolicited pongs cannot hold the loop
  - Registration and the hint: `max_unaccepted_registrations` pauses registration at a full backlog instead of growing it. A hint is one string of at most `max_rendezvous_relay_hint_bytes` that parses as a relay URL, and a second hint is refused `InvalidRelayHint`
- Searched by: the `frameHeader`, `closePayload`, and `upgrade` targets in `net/fuzz/websocket_client.zig`, run from `net/fuzz_test.zig`, which reach upgrade responses up to `max_upgrade_response_bytes` and not the refusal past it. The relay URL and hint parsers are not searched
- Refusal proved by:
  - Frame headers, close payloads, and the upgrade response grammar: `net/keyed_relay_frame_test.zig` (every malformed header shape, status codes and UTF-8 in a close reason, a response missing a required field or carrying an extension or subprotocol)
  - Frames after the upgrade: `net/keyed_relay_completion_wire_test.zig` (an invalid close payload from the relay, and a fragment out of order)
  - `max_upgrade_response_bytes`: `net/keyed_relay_completion_test.zig` proves the admitted side, where the cap counts HTTP bytes alone and a coalesced frame past it is kept. `net/keyed_relay_completion_bounds_test.zig` proves the refusal one byte past the cap, and `net/keyed_relay_bounds_test.zig` proves `UpgradeRefused` on the blocking carrier at the cap plus one
  - `RelayInputOverflow`: `net/keyed_relay_completion_bounds_test.zig` (the retained-input limit at its last byte and one past it, for a lent read and for a later read)
  - `max_frames_per_read`: `net/keyed_relay_bounds_test.zig` (the turn hands back once the budget is spent, and the buffered frames arrive on the next turn with no byte lost)
  - `max_resolved_addresses`: `net/keyed_relay_bounds_test.zig` on the blocking carrier and `net/keyed_relay_completion_dns_test.zig` on the completion carrier (an answer of exactly the cap dials, and one more fails at the resolve phase)
  - `max_unaccepted_registrations`: `net/keyed_relay_registration_bounds_test.zig`
  - Relay URL and hint: `net/keyed_relay_url_test.zig` (unsupported or ambiguous endpoints and the route corpus), `net/keyed_relay/rendezvous_test.zig` (a hint of the wrong kind, a fragment, an oversized hint, and a duplicate are refused before any I/O)

**A TLS record**

- Read by: the TLS engine in `net/tls/mbedtls.zig`, fed through `Transform.ciphertextDestination` and `Transform.commitCiphertext` in `net/tls/transform.zig`. `net/tls/pollable_stream.zig` and `keyed_relay/completion/tls.zig` both drive that transform
- Bounded by: `record_bytes`, the TLS 1.3 maximum record plus expansion, fixes each channel's ciphertext window, and neither carrier grows it with partner bytes. The window reclaims its consumed prefix first, and `TlsCiphertextLimit` refuses a record that still does not fit, surfacing as `TlsFailed`. mbedTLS holds one record's plaintext to `MBEDTLS_SSL_IN_CONTENT_LEN` in `net/tls/glowcap_mbedtls_config.h`. An engine that claims to have consumed more than it was offered is refused `EngineContractViolation`
- Searched by: the `window` target in `net/fuzz/tls_transform.zig`, a drawn engine against every commit geometry
- Refusal proved by:
  - `TlsCiphertextLimit`: `net/tls_transform_test.zig` (a window filled to its last byte admits, and the next record byte is refused), `net/tls_pollable_stream_test.zig` (a handshake whose full window the engine cannot parse fails through the carrier)
  - The window before the limit: `net/tls_pollable_stream_test.zig` (a stream one byte past `record_bytes` reads through because the consumed prefix is reclaimed before the window grows)
  - `EngineContractViolation`: `net/tls_engine_test.zig` (an engine that reports consuming more ciphertext than it was given), `net/tls_transform_test.zig` (the exact engine failure stays primary through transport cleanup)

**A result from the Rust library behind iroh or WebRTC**

- Read by: the imported verbs and the `Resident` and `Peer` wrappers in `net/transport/iroh/sidecar.zig` and `net/transport/webrtc/sidecar.zig`, then `TryIoOps.tryRead`, `TryIoOps.tryWrite`, `harvestSidecar`, and `stashAccepts` in `net/transport/iroh/backend.zig`. The library is first-party code the process links, so the Zig side checks its results as a contract and not as peer input
- Bounded by: `drainReady` and `drainDriverReady` on the WebRTC `Resident` refuse a count past the buffer with `ReadinessFailed`, as does the iroh `MultiplexedAdapter.drainReady`, while `harvestSidecar` refuses it `SidecarDrainFailed` and an iroh read or write count past its buffer fails the connection `IrohSidecarContract`. `max_signal_bytes` and `max_ice_candidate_bytes` bound signaling text. An inbound SDP or candidate past them is refused `SignalTooLarge` before the library sees it. `createOffer`, `createAnswer`, and `nextLocalCandidate` offer the library at most that many bytes, and a length reported past the buffer offered is refused `SignalFailed`. The iroh backend keeps at most `max_accept_stash` accepted connections, taken from `accept_queue_bound`, and frees arrivals past it, while the WebRTC backend refuses the same overflow `AcceptBacklogFull`. `max_direct_address_bytes` bounds the iroh direct-address list, refused `AddressListTooLarge`
- Searched by: none (the input is a call result, not bytes)
- Refusal proved by:
  - Signaling text: `net/webrtc_internal_test.zig` (an SDP or candidate one byte over `max_signal_bytes` never reaches the library, a generated signal over the cap is not a retryable buffer miss, an offer the library refuses closes its peer, and an ok result whose length passes the buffer offered is refused for every signal verb)
  - WebRTC accept stash: `net/webrtc_internal_test.zig` (`AcceptBacklogFull` at a full stash retires the adopted peer)
  - Direct addresses: `net/iroh_resident_internal_test.zig` (`AddressListTooLarge` past `max_direct_address_bytes`)
  - Readiness batch: `net/iroh_resident_internal_test.zig` (one turn drains one bounded batch and leaves the rest with the endpoint)
  - `ReadinessFailed`, `SidecarDrainFailed`, `IrohSidecarContract`, and the iroh accept stash: `net/iroh_resident_internal_test.zig`

**Tor control and SOCKS replies, text from a daemon the operator runs**

- Read by: `parseLine` in `net/transport/onion/control.zig` and the SOCKS5 reader
- Bounded by: one line of at most `max_line_bytes` per reply line, at most `max_reply_lines` lines per reply, and at most `service_key_cap` bytes in a returned service key. A request that does not fit its buffer is refused rather than truncated
- Searched by: `net/fuzz_test.zig` (every reply line up to `max_line_bytes` and every SOCKS5 head the parsers can be handed, so the over-long line refusal is out of its reach)
- Refusal proved by: `net/onion_control_test.zig` (a request too long for its buffer is refused with `LineTooLong`, a unit test of the control request writer only), `net/onion_control_session_test.zig` (a reply of `max_reply_lines` lines, a key of `service_key_cap` bytes, and a line of `max_line_bytes` bytes are admitted, and one more of each is refused `ReplyTooLong`), `net/onion_completion_test.zig` (the same three bounds on the completion listener, refused `ControlReplyTooLong`), `net/onion_socks5_test.zig` (malformed heads and service ids), and no SOCKS5 over-long test

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
  given and cannot tell whether it is sound.
- **How many gifts an introducer deposits.** A peer that answers a caller
  with an object homed on a third connection deposits one gift on that
  connection per answer. The exporter holds each gift until it is withdrawn,
  up to `max_deposited_gifts` and `max_deposited_gift_bytes` for that
  session, then condemns the session. A caller that never withdraws
  spends the introducer's room at the exporter. Whether to answer an
  untrusted caller with another connection's objects, and how often, is the
  program's to decide, like any rate.
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
  transports it negotiated, at most `max_pending_redeem_dials` at a time for
  handoffs and `max_pending_opens` across every open. A relay hint is
  followed only by a backend built with relay options, which carry the
  WebSocket entropy a relay leg draws from. Whether a program should reach
  that address is the program's to decide, above the host.
- **How much a peer with a grant may store.** Loam derives from a grant until
  the store reaches `map_bytes`, and it keeps no quota per peer. The
  controller sizes the store with `Lmdb.grow` and chooses the grant depth it
  hands out.
