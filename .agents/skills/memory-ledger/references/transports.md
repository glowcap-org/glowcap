# Transport memory costs

The [memory ledger](../SKILL.md) owns the naming procedure. Derivations live
at each declaration, and this inventory names transport, loop, and stream
costs.

## The ledger

- **Inbound spill**: `foundation.Spill` (ADR-0012). Where stream bytes wait
  for a whole frame. **It is bytes and nothing else, which is what
  lets `net` and `driver_core` share it** when neither can import the other, and
  each tier names only what a drained spill keeps. Deleting it relocates the cost
  into `max_frame_bytes`-sized per-connection read buffers. `Spill.consume`
  moves bytes only after a nonzero prefix is consumed. An incomplete frame
  leaves its accumulated bytes untouched instead of copying them onto themselves.
- **Byte-fed stream tail**: `HostSession.feed_tail` via `Host.feedBytes`. The
  one owner of the tail four binding pumps each kept by hand. Zero copies with no
  pending tail, and one bounded coalesce per chunk while one is pending. A
  straddled chunk is ordinary here, so this tier retains
  `steady_feed_tail_bytes` instead of freeing outright.
- **Sealed byte channel**: `foundation.sealed.SealedChannel` (ADR-0041), one
  channel type with one owner: the byte-fed `HostSession` boxes one per sealed
  session (the unsealed shell pays one null pointer), so every transport
  resident carries sealed bytes unchanged.
  - The channel stages inbound wire in its own spill, bounded by one record plus
    a chunk tail, and opens each record into a plaintext scratch shrunk back to
    steady size by the next small record.
  - Sealing and opening pay the one AEAD pass per record ADR-0041 names.
    `sealFrame` allocates one owned wire frame per outbound frame, `sealBytes`
    seals a stream chunk into a caller-owned queue, and `takeWire` dupes the
    fixed-size pending handshake message.
  - Deleting the box moves key material onto every shell in the 500k budget.
    Deleting the record copy means encrypting over borrowed frame bytes the
    engine still owns.
- **Shared read-buffer pool**: `completion.BackendOptions.read_buffers` ×
  `completion.BackendOptions.read_buffer_bytes` (ADR-0019). An idle
  connection holds zero read-buffer bytes. Whole frames apply zero-copy from the
  pool view and a partial tail pays one bounded copy into the spill. **The
  zero-copy claim is scoped to spill-inactive.** Deleting the pool reopens the
  per-connection buffer floor, about 7.6 GiB at 500k, and deleting the tail copy
  means parsing across recycled storage.
- **Readiness pending-operation rows**: `epoll.Backend.pending` and
  `kqueue.Backend.pending`. One compact row joins each descriptor with its
  armed read and write completion identities. The map grows when concurrent
  armed descriptors reach a new peak, then retains that capacity so steady
  re-arm is allocation-free.
- **Outbound queue front and back**: `completion.Loop` (ADR-0017). One copy in,
  because the loop cannot block on a send. **Two buffers because a submitted
  write borrows `front` while the loop keeps running**, and appending could
  realloc that storage out from under the kernel. Steady retention is
  per-buffer (<!-- value ../../../../src/net/frame_stream.zig steady_outbound_bytes bytes -->16 KiB<!-- /value --> each), so the ceiling is two of them per connection. Bounded by read
  backpressure at `completion.Options.outbound_high_water_bytes`, whose
  independent <!-- value ../../../../src/net/completion/loop/configuration.zig default_outbound_high_water_bytes bytes -->64 KiB<!-- /value --> default is replaceable without changing admission or pool
  sizing.
- **Completion-adapter transport staging**: iroh `enqueue_outbound` and
  keyed-relay `queueFrame`. The Loop's submitted send is
  a borrow, while both foreign async engines must own bytes past the call.
  - iroh copies the admitted prefix into one queue whose queued plus in-flight
    bytes share `NB_BUFFER_BOUND`.
  - Keyed-relay keeps the external write borrowed through its one completion and
    copies and masks one bounded WebSocket chunk at a time into
    `RelayConn.ws_out`, as RFC 6455 requires. The unsent tail is a subslice of
    the Loop-owned borrow, including while a Pong owns the wrapped send seat: a
    second whole-write copy is forbidden.
  - Iroh's inbound twin, `nb_reader`, appends each QUIC chunk once into the
    connection's bounded inbound buffer. `conn_try_read` drains it by advancing
    an offset, compacting only when the consumed prefix reaches the pending
    bytes. The buffer tracks the bounded pending count, not the bytes ever
    received, and shrinks back to `NB_STEADY_BYTES` once drained. Iroh retains at
    most one `NB_STEADY_BYTES` spare after a drained burst.
  - Relay send staging retains at most `RelayOptions.send_staging_bytes`, <!-- value ../../../../src/net/transport/keyed_relay/completion/options.zig default_send_staging_bytes bytes -->4 KiB<!-- /value --> by default including
    the frame header. A larger override is a per-connection memory commitment,
    not a frame-admission limit.
  - WSS copies ciphertext once into its fixed TLS record window and writes
    decrypted bytes directly into that WebSocket staging path. Refused TLS sends
    retry from allocation-free intrusive links in bounded turns, without cloning
    the application payload or adding a per-connection thread.
- **In-process link rings**: `Link.create` sized by `Exchange.ring_bytes`
  (ADR-0018). One allocation per `inproc` link holds a bounded ring per
  direction, the in-process counterpart of a socket's kernel buffers: a write
  copies into the ring and a read copies out into the reader's pool buffer.
  Peers on two loops cannot borrow each other's send buffers past the call, so
  the ring is the one owner between them, and its bound turns a fast writer
  into would-block.
- **Foreign-provider receive copy**: `external_completion.CompletionBackend`
  (ADR-0018). A provider owns its connection's bytes, so each `try_read` copies
  into one buffer from the backend's shared pool, the same shape as iroh's
  `conn_try_read`. Writes stay borrowed through the provider's `try_write`,
  which copies only what it accepts. Rows hold handles and readiness
  descriptors, no bytes.
- **Completion-resident send staging**: `completion_resident.Resident`
  (ADR-0018). `try_write` hands bytes over on return while the backend borrows
  a send until it completes, so each connection copies into staging bounded by
  `send_window_bytes`. Drained buffers return to one resident-wide spare list
  bounded by `spare_send_buffers` and `spare_send_bytes`, so an idle
  connection holds none. Reads cost no copy here: the resident lends its held
  pool receive through the borrowed-read group.
- **Wrapped-backend ready-queue reservation**: the onion, noise, and
  keyed-relay completion adapters (`ReadyQueue.ensureUnusedCapacity` before
  each poll turn).
  - Consuming one inner completion may terminate a connection whose external
    connect, recv, and send seats each owe a record, and onion's close
    handshake owes one more. Each adapter reserves that whole fan-out (three or
    four records per inner completion, times the <!-- value ../../../../src/net/completion/loop/driver.zig poll_batch -->256<!-- /value -->-record turn)
    before it takes any inner completion from the backend it wraps. An
    already-earned record is never lost to a refused reservation.
  - The queue keeps that peak, about 36 KiB (48 KiB for onion) per adapter, for
    the backend's life: `appendAssumeCapacity` is what makes fan-out infallible
    mid-turn, and a shrinking queue would give that back. Stacked adapters each
    hold their own.
- **Onion listener publish setup**: `onion/completion/listener.zig`. While
  the publish conversation runs, the one listener row holds about 2 KiB of
  setup state (two <!-- value ../../../../src/net/transport/onion/control.zig max_line_bytes bytes -->1 KiB<!-- /value --> line buffers for the outbound control line and the reply-line assembly, plus
  the reply harvest), freed when the service publishes or the setup fails.
  The steady-state listener row holds only the descriptor and the published
  service. The setup state is per backend (one backend publishes one service),
  so no per-connection cost exists.
- **iroh provider connection-id table**: `MultiplexedAdapter`
  (`src/net/transport/iroh/multiplexed.zig`, ADR-0018). One POD row per live
  loop connection, mapping the sidecar's stable id to its handle, because
  drained records carry ids while the sidecar verbs take handles. Rows enter
  at `finishConnect` or `finishAccept`, free at `closeConnection`, and adapter
  teardown sweeps stragglers. No byte payload crosses the table.
- **Keyed-relay configuration and carrier lease**: `keyed_relay.Resident`
  copies its relay, registration and optional dial alias URLs into one block
  because parsed `RelayUrl` fields are retained views. The completion backend's
  registration (`registration.State`) copies its URL the same way and keeps a
  fixed ring of promoted, unaccepted legs per backend, so a full backlog pauses
  registration instead of growing. One heap `carrier_runtime.Lease` state owns
  I/O per resident. Each listener and admitted channel retains one
  pointer-sized lease, so the last release follows their close barriers. There
  is no per-dial config copy.
- **Keyed-relay receive projection**: the completion adapter lends ordinary
  WebSocket payload directly from the wrapped backend's shared recv buffer,
  preserving its token so recycle returns to the actual owner.
  - Only a split header or control frame, upgrade residue, or the next-frame tail
    coalesced behind a payload crosses into `RelayConn.raw_in`.
  - A platform receive that completes after its caller seat was canceled also
    copies there so stream bytes survive recycling the shared buffer. A
    replacement seat installed before completion still takes the ordinary
    zero-copy path.
  - The spill is hard-bounded to one platform buffer plus the parser prefix, and
    capacity above `steady_raw_in_bytes` is released when drained.
  - The blocking resident still copies from its socket reader into the caller's
    CapTP reader.
- **WebRTC C-facing staging**: one bounded inbound deque and one bounded
  outbound staging buffer per peer (ADR-0035), because the C ABI exposes
  synchronous reads and nonblocking try-writes while the `webrtc` crate's data
  channel is async.
  - The inbound poller admits a message only when the whole message fits under
    `INBOUND_BUFFER_BOUND`, and it refuses a single message larger than that
    budget.
  - Try-writes copy into the outbound staging buffer and return without entering
    the runtime. An async drain task sends bounded chunks through
    `DataChannel::send`. The crate's SCTP receive window and send buffer are
    separately bounded at the same layer.
  - Readiness is endpoint-owned, and its self-pipe writes distinguish sent,
    safely coalesced, and failed outcomes. `WouldBlock` alone is coalesced
    success because unread bytes already make the fd readable. Every other write
    or drain fault is latched by the owning runtime and settles or terminalizes
    its admitted work.
  - Locally gathered ICE candidates are retained only in that peer's signaling
    queue, capped at <!-- value ../../../../src/net/transport/webrtc.zig max_pending_ice_candidates -->256<!-- /value -->
    records and <!-- value ../../../../src/net/transport/webrtc.zig pending_ice_candidate_queue_bytes bytes -->64 KiB<!-- /value --> total text. Overflow terminalizes the peer as a transport
    failure.
- **WebRTC signaling transfer**: `SignalPayloadPool` in the completion
  backend. `provideAnswer` and `provideRemoteCandidate` are callable from
  foreign threads, while a caller-supplied Zig allocator may be single-threaded.
  The backend therefore allocates one fixed endpoint-level pool of <!-- value ../../../../src/net/transport/webrtc/backend/signaling.zig max_signal_payloads -->256<!-- /value --> slots of <!-- value ../../../../src/net/transport/webrtc/sidecar.zig max_signal_bytes bytes -->16 KiB<!-- /value --> (4 MiB) on its
  owner thread and copies each bounded signaling payload into an exclusive slot
  before publishing the queue row. The loop returns the slot after applying the
  row. No foreign thread enters the allocator, no payload allocation reaches the
  session byte path, and overload is `WouldBlock`, not heap growth.
- **Browser WebRTC candidate staging**: `RtcPeer` snapshots the standard ICE
  fields before retaining a remote candidate, caps one candidate at <!-- value ../../../../src/net/transport/webrtc/sidecar.zig max_signal_bytes bytes -->16 KiB<!-- /value -->, and caps each pre-SDP or apply queue at <!-- value ../../../../src/net/transport/webrtc.zig max_pending_ice_candidates -->256<!-- /value --> candidates / <!-- value ../../../../src/net/transport/webrtc.zig pending_ice_candidate_queue_bytes bytes -->64 KiB<!-- /value --> of text. Local candidates waiting for a signaling sink carry the same bounds.
  - Once a sink is installed, `SignalingSendOwner` admits at most 256 unresolved
    signaling sends and aborts bring-up on overflow.
  - The rooms carrier creates one row per active dial before gathering starts,
    holds early local candidates behind the directory's admitted exchange id,
    expires routing rows after 30 seconds, and retires that exact id when
    bring-up ends.
  - These queues are signaling control state, not session bytes, but remain
    peer-influenced when the signaling capability crosses a network.
- **Pinned stream wrapper**: `netlayer_support.PinnedRawStream` for a raw
  socket connection (`tcp`, `onion`) and `netlayer_support.PinnedStream` for a
  shim-sourced one (`inproc`, `IrohStream`) (ADR-0019, ADR-0021).
  `std.Io.Reader`'s vtable recovers its concrete reader from `&interface` by
  field offset, so the reader and writer need a stable address outside the
  by-value `Connection`. Storing them inline dangles the moment the connection
  moves. Two shells because the sources differ in kind: a raw socket already
  owns std's reader and writer, and shimming it would add a second buffer and
  a copy. Blocking path only. The loop builds no `Connection`.
