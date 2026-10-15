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

glowcap sits between a program and peers it does not trust. Below are the
adversaries it is built against, the assets they would want, and for each
untrusted input the code that meets it, the limit that bounds it, the search
that looks for a crash or a leak in it, and the test that proves the refusal.
[SECURITY.md](../SECURITY.md) says what counts as a vulnerability and how to
report one. The [transports page](https://jimisaacs.github.io/glowcap/transports/)
says what proves who answered on each netlayer, and
[known limitations](boundaries.md#transports-and-peer-identity) says where
identity and scale stop.

## Adversaries

- **Someone on the path.** Reads, alters, replays, or drops bytes between two
  peers. On `noise-tcp`, `noise-relay`, iroh, WebRTC, and onion the channel is
  sealed end to end, so they see ciphertext and an altered record closes the
  session ([ADR-0107](decisions/adr/ADR-0107-sealed-byte-channel.md)). On
  `tcp`, `keyed-tcp`, and `keyed-relay` they read and can alter every frame,
  and the signed hello proves only the session key.
- **A peer that speaks CapTP.** Holds a real session and sends any message the
  protocol allows, in any order, at any rate, with any value. Its goal is a
  reference it was never given, a table that grows without bound, or a process
  that stops answering its other peers.
- **A program behind a capability it was given.** Code in the same process,
  or a peer holding a legitimate reference, that uses it to reach past what
  the reference names: a deeper value than the host allows, a settle from the
  wrong thread, a capability smuggled through a plain-data channel. An agent
  steered by text it read is this adversary with a well-meaning owner
  ([What about identity?](https://jimisaacs.github.io/glowcap/identity/)).
- **A flood of connections.** Many sockets opened and left half-open, or many
  sessions each sending as fast as the pipe allows, to exhaust descriptors,
  memory, or the one thread an ordinary session needs.
- **An automated adversary at machine speed.** Searches the parsers and state
  machines with generated inputs faster than a person could, for the crash,
  the leak, or the table that grows past its cap. The mutation fuzzers in the
  table below are this adversary, run first.

## Assets

- **Durable identity keys.** The Ed25519 key a peer is known by. glowcap keeps
  no key store: the program supplies the seed and keeps the secret. A sealed
  channel proves possession of the dialed key, converted for Noise
  ([ADR-0107](decisions/adr/ADR-0107-sealed-byte-channel.md)).
- **Session keys.** The per-session Ed25519 key each hello signs, and the
  Noise transport keys split at the end of a handshake. Both die with the
  session.
- **Swissnums and sturdyrefs.** A sturdyref is a bearer credential: whoever
  presents its swissnum fetches the object. A durable name is
  <!-- value ../src/ocapn/session/references/bootstrap.zig durable_swiss_entropy_len -->16<!-- /value -->
  random bytes behind a reserved prefix. The publication table compares a
  presented name in constant time over the stored name (`bearer_table`), and
  the discovery waiters compare the same way, so a near miss costs what a far
  miss costs. The host that published a sturdyref
  decides which peer may redeem it
  ([ADR-0098](decisions/adr/ADR-0098-sturdyref-peer-authority.md)).
- **The export, import, and answer tables.** Every reference a peer holds is a
  row in these, and session state alone decides whether a row exists. A codec
  decodes positions and never creates a reference. A table keyed by positions the
  peer chooses hashes them under a per-session secret, so chosen collisions
  cannot turn a lookup into a scan
  ([ADR-0218](decisions/adr/ADR-0218-a-table-keyed-by-the-peer-hashes-under-a-session-secret.md)).
- **The process.** Its memory, its descriptors, and the thread that runs every
  turn. Input, I/O, resource pressure, and a callback's refusal never end it,
  and a wire-fatal refusal retires exactly one session.

## Untrusted inputs

One row per input a peer or a program supplies. "Read by" is the code that
meets the bytes. "Bounded by" is the limit it refuses past, from
`SessionLimits` unless another file is named. "Searched by" is the mutation
fuzzer under `test/` that drives it, a search [stability](stability.md#which-checks-recur)
says when it runs. "Refusal proved by" is the test that pins the refusal.

| Input | Read by | Bounded by | Searched by | Refusal proved by |
| --- | --- | --- | --- | --- |
| Stream bytes, cut at any read boundary | `stream_framing.parsePrefix`, through `net.recvOuterPrefix` and `Host.feedBytes` | `max_frame_bytes`, default <!-- value ../src/ocapn/session/limits.zig default_max_frame_bytes bytes -->1 MiB<!-- /value -->, checked on the length prefix before the body is read | `engine/fuzz_test.zig`, `driver/fuzz_test.zig`, and `net/fuzz_test.zig` for a frame that spills past the read buffer | `driver/core_host/redeem_test.zig` (an outer length over the cap is refused before its body), `engine/completion_seam_test.zig` (both codecs, the exact cap, and a declared length over the cap refused before its body) |
| A Syrup frame | the Syrup decoder under `codec/syrup/` | `max_decode_nesting` in `codec/limits.zig`, the frame cap, and `max_nesting_depth` on the argument tree at validation | `codec/fuzz_test.zig` (the whole-frame decode and the owned materializer), and `zig build goblins-differential` (the same mutated frames fed to a live Goblins vat and to glowcap, for a person to triage) | `codec/syrup/decode_test.zig` (a collection wider than the element cap), `session/traffic_test.zig`. An inbound deliver nested past `max_nesting_depth` is refused with `NestingTooDeep`. A send-side deliver or fulfill nested past it is refused with the export refcount unchanged, before any export is retained. `codec/prefix_decode_test.zig` refuses at `max_decode_nesting` exactly, an empty innermost collection included, and a frame thousands deep fails without touching the stack limit. |
| A Cap'n Proto frame | the Cap'n Proto decoder under `codec/capnp/` | a traversal budget of `traversal_budget_words_per_segment_word` words per segment word with a floor, so an aliasing graph cannot amplify | `codec/fuzz_test.zig` (borrowed decode and owned projection) | `codec/capnp_malformed_test.zig` (an aliasing DAG exhausts the budget, an aliasing hint list is charged, a multi-segment frame is refused) |
| A message against live session state: deliver, resolve, listen, release, GC, abort | `session.validate`, then the engine's dispatch into the tables | `max_imports`, `max_inbound_answers`, `queue_cap`, `max_listeners_per_target`, `max_resolution_chain`, `max_local_deliveries`, `max_retained_sent_answer_bytes`, `max_compare_visits` | `engine/fuzz_test.zig` and `driver/fuzz_test.zig`, which drive a program to build live tables and then hold `max_imports`, `max_inbound_answers`, `queue_cap`, `max_listeners_per_target`, the nesting depth, and the frame cap after each step (`support/session_bounds.zig`). The other four bounds are not searched | `max_resolution_chain`: `engine/projection_test.zig` (a distinct chain past the bound breaks the answer with the bound named). `max_local_deliveries`: `engine/peer/pipeline/fail_closed_test.zig` and `engine/resolve_window_test.zig` (`LocalDeliveryCapExceeded` closes the session with an abort). `max_retained_sent_answer_bytes`: `engine/node/answer_settlement_test.zig` (`RetainedAnswerCapExceeded`). `max_compare_visits`: `session/set_uniqueness_test.zig` (`CompareBudgetExhausted`). The abort path: `engine/abort_projection_test.zig`, `driver/host_runtime_step/refused_partner_release_test.zig` (releasing the session one partner's refused frame ended leaves the runtime serving everyone else) |
| A hello (`op:start-session`) | `validateStartSession`, then the signature check in `engine/hello.zig` | the CapTP version must match, `max_count` locator hints in `model/hints.zig`, and the handshake deadline the caller sets | `session/fuzz_test.zig` (route lists), `model/fuzz_test.zig` (locator text) | `engine/pairing/signature_test.zig` (a signature that does not match the claimed key, tampered hint bytes), `session/lifecycle_test.zig` (a version mismatch) |
| A locator or sturdyref as text, in a hello, a handoff, or from a program | the `ocapn://` parser in `model/` | `max_route_list_count` and `max_route_list_bytes` in `model/route_bundle.zig`, and `max_count` hints | `model/fuzz_test.zig` | `model/uri_test.zig`, `net/keyed_tcp_test.zig` and `net/noise_tcp_test.zig` (a designator of the wrong kind is refused before any I/O) |
| A third-party handoff: a give, a receive, a withdrawal | `validateInboundHandoffArgument`, then the gift registry and signatures under `engine/bootstrap/` | `max_deposited_gifts`, `max_deposited_gift_bytes`, `max_pending_withdraws`, and a handoff count that never repeats | `driver/fuzz_test.zig` (the receive a recipient really sent, fed to the exporter verbatim, with bytes of the certificate flipped, or with bytes of one signature flipped, each under a fresh answer) | `engine/cross_peer/authority_test.zig` (a give signed by the wrong key, a replayed count, a withdrawal whose signature fails), `engine/gift_registry_test.zig` |
| A sturdyref fetch, by swissnum | the publication lookup in `driver/core/` and the session's bootstrap table | names this process minted, compared in constant time (`bearer_table`), and an unknown name breaks the fetch | not searched | `engine/fetch_test.zig` (a partner-side break settles the fetch as broken with its reason "unknown swissnum", in the `op:resolve` form and in the symbol-shaped resolver-callback form), `session/bootstrap_test.zig` (an unregistered name finds no export), `foundation/bearer_table_test.zig` (the exact key is found, and a changed last byte, a prefix, an appended byte, and the empty name are not). Constant time holds by construction through `std.crypto.timing_safe` and is not measured |
| A Noise handshake message | `HandshakeState.readMessage` | each message's exact size by shape, and `MAX_MESSAGE_BYTES` | `foundation/fuzz_test.zig` (a damaged message at either role never advances the transcript) | `foundation/noise_test.zig` (tampered, replayed, truncated, oversized, split too early), `driver/sealed_channel_test.zig` (a replay at a fresh responder, a responder holding a different key, a sign-bit alias) |
| A sealed record | `SealedChannel.ingest` | `MAX_RECORD_BYTES` per record, the frame cap on the plaintext, and a nonce that refuses its reserved value | `foundation/fuzz_test.zig` (a damaged record never opens, and a split lands anywhere) | `foundation/noise_test.zig` (a plaintext one byte over the record maximum is refused when sealing, and the reserved nonce is refused in both directions), `driver/sealed_channel_test.zig` (a plaintext frame cannot bypass the channel, a split header, an allocation failure mid-record) |
| Session traffic as a flood | the host's per-turn budget and the completion loop's deadlines | the outbound high-water mark per connection, `park_kill_ms`, and the turn budget per session | none, not bytes | `driver/core_host_budget_test.zig` (a flood fed on one connection and landing on a sibling condemns the sibling with a close action and `LocalTurnLimitExceeded`, while the feeding connection survives), `net/completion_loop_deadlines_test.zig` (a connection whose queue crosses the outbound mark gets a `park_kill` deadline, and draining the queue clears it), `driver/host_runtime_multiplexed/provider_test.zig` (an always-ready resident cannot starve a sibling), `net/completion_loop_backpressure_test.zig` |
| Half-open handshakes in bulk | `HostRuntime` accepting connections, behind the completion resident's listener | `max_pending_opens`, default <!-- value ../src/driver/host_runtime.zig default_max_pending_opens -->256<!-- /value -->, and the handshake deadline, default <!-- value ../src/driver/core/vocab.zig default_handshake_timeout_ms milliseconds -->10 seconds<!-- /value -->. A listener holds at most `max_unclaimed_accepts` accepted sockets the runtime has not claimed and stops accepting past that, so arrivals wait in the kernel's listen backlog | none, not bytes | `net/completion_resident_test.zig` (a listener stops accepting at the unclaimed bound and resumes on a claim), `driver/host_runtime_step/flood_test.zig` (the slots all held by handshakes that never finish, the next arrival refused, the accepted count held, and an honest session opening once the deadline frees them) and `driver/host_runtime_step/serve_test.zig` (an arrival while a slot is held closes with no session) |
| Tor control and SOCKS replies, text from a daemon the operator runs | `parseLine` in `net/transport/onion/control.zig` and the SOCKS5 reader | one bounded line per reply, and a request that does not fit its buffer is refused rather than truncated | `net/fuzz_test.zig` (every reply line up to `max_line_bytes` and every SOCKS5 head the parsers can be handed, so the over-long line refusal is out of its reach) | `net/onion_control_test.zig` (a request too long for its buffer is refused with `LineTooLong`, a unit test of the control request writer only), `net/onion_socks5_test.zig` (malformed heads and service ids), and no SOCKS5 over-long test |
| Values a program passes into a call or a settle | the host's lift and lower, and the settle mailbox | `max_value_depth` in `model/mod.zig`, and the mailbox's size and plain-data rule | none, not bytes | `driver/core_host/capability_projection_test.zig` (exactly the depth limit), `driver/off_turn_settle_test.zig` (full, oversized, and capability-bearing posts refuse) |

## What glowcap does not defend

- **Authorization and rate.** Holding a capability is the permission. Who receives
  one, how often a holder may call, and how long a call may take are the
  program's to decide, above the library.
- **A person's identity, and the front door.** A proved peer is a key, not a
  person. Who gets a key, and what proof the door asks for, is the
  application's ([What about identity?](https://jimisaacs.github.io/glowcap/identity/)).
- **An agent talked into using its key.** A narrow key limits what the
  words can reach, and glowcap carries the narrow key. The agent's judgment is
  outside the library.
- **Confidentiality on a cleartext netlayer.** `tcp`, `keyed-tcp`, and
  `keyed-relay` carry CapTP in the clear.
- **Memory inside the process.** A program linked with glowcap shares its
  address space. The capability discipline governs references, not memory.
- **Traffic analysis.** The sizes and timing of sealed records are visible on
  the path.
- **The program's secrets and entropy.** glowcap signs with the seed it is
  given and never judges where it came from.
- **A few bits of a swissnum's hash.** The publication table's lookup can show
  which bucket and fingerprint the stored name has (`bearer_table`).
