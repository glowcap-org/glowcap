# Plan — iroh at scale: the event-driven sidecar bridge

Status: active plan. Proposed work, not started — this is the companion
implementation plan for
[ADR-0057](../decisions/adr/ADR-0057-iroh-completion-loop-bridge.md). It
exists so a future agent knows exactly what "full iroh hole-punching and P2P
discovery **at scale**" costs, in order, before opening the first file.

## What is already done (so this plan starts honest)

The iroh transport is, today, encrypted, discoverable, and identity-unified —
pancake-to-pancake, deterministically proven by `zig build iroh-interop`:

- **A — discovery / relays**: the netlayer takes a configurable, no-default
  `Reachability` (`direct`, `discovery`, `discovery_no_relay`, `local_discovery`)
  across the sidecar, the resident, the public C ABI, and all four bindings. The
  interop gate dials by node id **alone** through the `local_discovery` address
  book — the lookup half of the transport, proven with no relay or public
  infrastructure.
- **B — key unification**: one Ed25519 key per peer is at once the iroh node id,
  the OCapN locator designator, and the session signing key. The interop gate
  verifies this on both handshake halves over the live wire
  (`driver.connectViaWithSecret` / `acceptViaWithSecret`).
- **F — durable identity**: a sturdyref (node id + swiss-number) survives an
  endpoint restart — same seed, same node id at a fresh address, same published
  cap reached through the locator recorded before the restart.

What is **not** done is concurrency at pancake's target scale. Every binding
serves an iroh connection with a thread (or two) per connection or a
non-blocking-FFI threadpool. Correct, but it caps at thousands of connections,
not the ~500k the `bench-peer-scaling` report targets.

## The one idea

The sidecar already runs **one** tokio runtime multiplexing every QUIC stream
over one UDP socket. Surface that runtime's readiness to pancake's completion
loop through **one** wakeup fd and a drained ready-queue, and make frame I/O
non-blocking. Then N iroh connections cost one loop source plus the sidecar's
fixed threads — not N×2 blocking threads.

## Stages

Each stage ends green on its own gate; do not start the next until the prior
gate holds.

### Stage 1 — Readiness primitive in the sidecar (Rust)

- Add to `transports/iroh/src/lib.rs`: a process-global readiness handle
  (`eventfd` on Linux behind a `cfg`, self-pipe fallback) created with the first
  endpoint. Pick the primitive here; record it in the ADR's "exact wakeup
  primitive" line.
- Spawn, on the existing runtime, per-connection tasks that mark a connection
  readable/writable/closed and write the wakeup fd.
- Expose `pancake_iroh_sidecar_readiness_fd() -> i32` and
  `pancake_iroh_sidecar_drain_ready(out_ptr, out_cap, out_len) -> i32`
  returning packed `(conn_handle, events)` records (`ptr + len`, caller-owned
  buffer, no per-call allocation).
- Gate: extend the `pancake_iroh_sidecar_` ABI parity check in
  `tools/meta_check.zig` to cover the new functions; `zig build meta-check`
  green. Add a Rust-side unit test that the fd fires on a self-connected pair.

### Stage 2 — Non-blocking frame I/O in the sidecar (Rust)

- Add `pancake_iroh_sidecar_try_read_frame` / `_try_write_frame` returning a
  `WOULD_BLOCK` code instead of parking.
- Keep the blocking calls — they remain the shipped path (ADR-0053). The new
  calls are a superset, not a replacement.
- Gate: a Rust test that a `try_read_frame` on an idle connection returns
  `WOULD_BLOCK`, then returns a frame after the peer writes and the fd fires.

### Stage 3 — A completion-loop source in the driver (Zig)

- Add a new source under `src/driver/` (sibling of the kernel-fd source) that
  registers `readiness_fd()` once with the ADR-0051 loop, drains the ready-queue
  on wake, and resumes the fibers waiting on each `(conn, direction)`.
- Add a non-blocking variant of the resident's stream wrappers in
  `src/net_adapter/iroh.zig` that drive `try_read_frame` / `try_write_frame`
  and yield on `WOULD_BLOCK`.
- The `Netlayer` (ADR-0043) and `ConnectedVat` (ADR-0053) contracts above do
  not change. A loop-driven consumer selects the non-blocking resident; the
  blocking `connectVia` / `acceptVia` path stays for simple consumers.
- Gate: a new Zig scenario — many concurrent iroh connections served from one
  loop on one thread — green under `zig build` (a sibling step like
  `iroh-interop`, since it links the sidecar).

### Stage 4 — Measure, don't project (Zig)

- Add an iroh scenario to `bench-peer-scaling` and write a real
  `bytes_per_conn` / `mem_at_500k_gib` number for the loop-driven path.
- Decide back-pressure policy with the number in hand: bound the sidecar's
  per-connection inbound queue, surface overflow as a typed abort, document the
  bound.
- Update ADR-0057 status `proposed → accepted` and move the "at scale" line in
  `docs/boundaries.md` / `docs/shipped.md` from projection to measured.

## What this plan deliberately does not do

- **No native Zig QUIC.** ADR-0055's flip condition is unchanged; this plan
  removes the main reason to chase one.
- **No new transport semantics.** Discovery, relays, hole-punching, and identity
  are done (A/B/F). This is purely a concurrency/footprint bridge.
- **No change to the blocking consumer path.** Thread-per-connection stays
  correct and supported for small deployments.

## Known adjacent debt (not this plan, but record it here)

The cross-language `demo-rooms-iroh` and the Deno iroh tests in
`examples/apps/rooms/deno/server_test.ts` are flaky under load: an occasional
`Bus error` / `SIGSEGV` during Deno non-blocking-FFI **teardown** (a connection
released while a worker thread is still parked in a blocking read), plus message
loss / malformed frames under 5-way concurrent dials. This is a binding/demo
**teardown and harness** robustness issue — orthogonal to transport semantics,
which `iroh-interop` proves deterministically. The right home for the fix is the
non-blocking surface above (Stage 2/3 removes the parked-read-during-release
race by construction). Until then, `iroh-interop` is the authoritative iroh
gate; treat the demo as illustrative, not load-bearing.
