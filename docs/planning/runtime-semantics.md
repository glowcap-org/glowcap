# Runtime and capability semantics

Status: active plan. The [roadmap](../roadmap.md#runtime-and-capability-semantics)
owns its priority. An outside review of the library by an OCapN and Goblins
practitioner found these gaps between the current design and the one a reader
would expect. The stages run in order: the semantic gaps first, then the
structural change. Each step lands green on its own.

Stages 1 and 2 are built. Stage 3 is the open work.

## 1. A failed turn's far sends

[ADR-0194](../decisions/adr/ADR-0194-far-sends-retract-with-a-failed-turn.md)
gives a failed turn's far sends the rollback its local sends have
(ADR-0191). Its steps, all built:

1. **Turn participants.** The Vat enrolls each layer that records a turn
   effect and tells it to commit or abort, once. Abort restores state before
   observer notification. An optional `abort_notify` hook publishes the outcome
   after all participants have finished cleanup.
2. **Peer retraction.** The Port opens its Peer's provisional window; abort
   removes each marked deliver, releases its export retains, retires its
   answer and, on `next`, its resolver export, and breaks its vow.
3. **Host receipts.** Lowerings for sends inside a turn keep their receipts
   until the outcome, and abort rolls back projections no surviving message
   names.
4. **Node rollback.** A send staged for gift ids retracts through the queue
   row it reserved (stage 2), and the Node fails its batch. A send that
   projects only promises commits its proxy while it stages; the Node keeps a
   receipt per recipient and withdraws them, with any proxy the window created
   and its queued home listen, when the window retracts.

## 2. Send order across Node staging

[ADR-0201](../decisions/adr/ADR-0201-staged-sends-hold-their-queue-position.md)
keeps a session's messages in the order it sent them when one of them waits in
Node staging for gift ids. The staged send reserves its row in the recipient's
queue when it is sent, a step stops at that row, and the batch fills it when it
finishes or removes it when it fails. A relayed promise settlement staged for a
proxy recipient reserves no row; its order against the recipient's other
traffic is undecided.

## 3. One I/O runtime

[ADR-0193](../decisions/adr/ADR-0193-one-io-runtime.md) puts every front on one
runtime, and
[ADR-0202](../decisions/adr/ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)
settles how stream transports reach it: a completion backend joins
`HostRuntime` as a multiplexed resident (`net.completion_resident`). Plain TCP
runs that way today, lending each received chunk from the backend's pool and
holding no buffer on an idle wire. The scale benchmark's server runs
`HostRuntime` shards that way, at less memory per session than the completion-loop
server it replaced ([the ladder](../ladder.md#2-performance-at-scale) has the
side-by-side figures); the 500,000-session rerun on `HostRuntime` needs the
large host the original run used. The remaining work, in order:

1. **Every completion backend as a resident.** Every TCP profile, `inproc`,
   both relay symbols, onion, and foreign stream providers already run as
   residents with per-call listen targets; the Host seals `noise-tcp` and
   `noise-relay` on their carriers' sockets, and `net.StreamStack` composes
   them all on one backend. An onion listen publishes its service as a
   pending resident listen instead of a synchronous setup, and WebRTC runs as
   a resident over `webrtc.Backend`. Adapters that retry on a timer bound
   `HostRuntime`'s wait through the resident contract. What remains is the
   pending onion listen.
2. **Stream netlayers leave the runtime.** Done. `Session`, `Server`, and
   `HostRuntime`'s constructors take one `driver.Transports` value: the
   enabled symbols with their deployment state, run on one runtime-owned
   `net.StreamStack`, plus caller-owned residents. C stream tables run on the
   external resident. Every wire is a resident connection, so the runtime's
   one readiness descriptor, which the stepped C driver hands out, polls
   resident descriptors and never a per-connection socket.
3. **Consumers onto the product fronts.** Done. The TCP and iroh loop
   drivers, the Goblins interop drivers, the WebRTC and iroh redeem drivers,
   the conformance peer, the benches, and
   `examples/zig/many_sessions_one_loop.zig` run on `Session`, `Server`, or
   `HostRuntime`, serving many sessions on one thread. `Bridge`, the sealing
   completion adapter, and `NoiseRelayLoop` are deleted.
4. **`BlockingSession` replaced** by a one-wire Host, with its callers moved.
5. **One home per policy.** Dial retry runs in the runtime and the bindings drop
   their loops. A stock Zig Loam worker sits beside it. Release on drop becomes
   a Host option in Zig and C.

Further ADR candidates, not scheduled: Loam actors that share the Vat actor
shape and upgrade older records lazily; durable swiss numbers derived from the
Host seed rather than stored raw.
