---
id: ADR-0193
status: accepted
date: 2026-10-04
tags: [driver, runtime, performance, bindings, memory]
decision: "Every front that runs I/O for a Host (driver.Session and Server, the C driver, and every binding) runs HostRuntime, and HostRuntime moves stream wires onto the completion loop's pooled buffers. Bridge becomes HostRuntime's internal loop adapter, and BlockingSession is replaced by a one-wire Host on the same runtime."
supersedes: [ADR-0053]
superseded_by: []
amends: [ADR-0062, ADR-0082, ADR-0192]
amended_by: [ADR-0202]
---

# ADR-0193 One I/O runtime

## Context

glowcap has three ways to run I/O around the byte-fed `driver_core.Host`:

- `driver.Bridge(LoopT)` adapts a `completion.Loop` to a Host. Reads come from
  the loop's bounded shared pool (`net/completion/buffer_pool.zig`). The
  500,000-session scale run (`bench/peer_scaling/live_worker.zig`) uses it:
  32 `Bridge(net.TcpLoop)` Hosts sharing one identity.
- `driver.HostRuntime` runs every product front: `driver.Session` and `Server`,
  the C driver (`c_abi/driver/loop.zig`), and through it every binding. Each
  stream wire owns a read and a write buffer of `default_wire_buffer_bytes`
  (16 KiB each, `host_runtime/stream_wire.zig`), whether or not the wire is
  idle. Multiplexed transports (iroh, WebRTC) already join it through the
  resident contract in `net/multiplexed_resident.zig`.
- `driver.BlockingSession` folds one connection over a `Served` on the
  caller's thread (ADR-0053). It has its own constructors and its own blocking
  `call`/`fetch`, and it hands gifts to the caller instead of redeeming them.

The measured runtime is not the one applications run. An application on a
binding pays 32 KiB per idle stream wire that the scale run never paid, and a
fix to one runtime does not reach the others. Some policy also has no runtime
home: `driver.DialRetry` has one Zig caller (`interop/iroh_reachability`)
while the Rust, TypeScript and Python bindings each run their own retry loop
over shared constants. Zig has no stock Loam worker though C has
`c_abi/loam/work.zig`, and the GC setting moved to the Rust Host only
(ADR-0192).

One runtime and one set of policies give one authority per fact, the per-wire
buffers are a named wire-path allocation, and the examples should measure what
users run.

## Decision

1. **HostRuntime is the one runtime.** Stream wires move onto the completion
   loop. Reads borrow from the loop's shared pool. Writes go through the
   loop's outbound path, so an idle wire holds no buffer.
   `wire_buffer_bytes` becomes the pool's sizing input, not a per-wire
   allocation.
   - A stream transport is a completion adapter, not a `net.netlayer.Netlayer`.
     A stream netlayer's `std.Io` connection holds its reader and writer
     buffers for the connection's whole life, which is where the idle cost
     comes from, so pooling cannot be added inside HostRuntime while stream
     wires stay Netlayers.
   - HostRuntime runs one composed backend
     ([ADR-0202](ADR-0202-stream-transports-join-hostruntime-as-a-completion-resident.md)
     amends the mechanism: the backend joins as a multiplexed resident, not
     inside a `completion.Loop`, and the Host seals the Noise symbols, so no
     sealing adapter joins it):
     relay over onion over `inproc` over foreign providers over the
     platform backend, with the matching chained dial resolver. Each adapter
     passes plain operations to the one it wraps
     (`net/transport/inproc/completion.zig`), so one backend serves
     every first-party stream symbol and foreign stream providers.
   - `inproc` becomes a userspace completion adapter: bounded in-memory pipes
     with backpressure, readiness through the backend's wake channel, and
     synthesized completions on shutdown. It keeps its designator addressing,
     its C archive and its binding projections.
   - Foreign stream providers (ADR-0112) join through an adapter that reads a
     provider connection into a pool buffer on readiness. The provider table
     moves from blocking `read`/`write_all` to the multiplexed table's
     `try_read`/`try_write`, so both provider kinds share one I/O contract.
   - Session and Server stop taking stream netlayers. They enable stream
     symbols and take each one's deployment state (relay URL, Tor
     endpoints). A listener publishes the Host's own identity. Multiplexed
     residents (iroh, WebRTC) are unchanged.
   - The blocking face runs the loop until its wait completes. The stepped C
     driver hands out the backend's own descriptor.
   - Before HostRuntime moves, each missing adapter capability lands green on
     `Bridge`. The `noise-tcp` sealed dial, `inproc`, relay listening, and
     foreign stream providers are built. The platform backends gained a
     one-shot readiness verb (`submitPoll`) for descriptors an adapter does
     not own.
2. **Bridge becomes internal.** It is the adapter by which HostRuntime drives a
   loop, not a second public front. The scale run and every bench use
   `HostRuntime`, so the measured path is the product path.
3. **BlockingSession is replaced by a one-wire Host** on HostRuntime. A
   caller that wants to block drives the runtime until its call settles. Gifts
   redeem the same way as on every other front. A transport with no pollable
   descriptor joins through the resident contract, as iroh does today.
4. **Policy gets one home on the runtime.**
   - Dial retry runs in HostRuntime under its `driver.DialPolicy` option, and
     reaches the bindings through the C driver. Bindings stop carrying their
     own loops.
   - A stock Zig Loam worker sits beside HostRuntime with the contract of
     `c_abi/loam/work.zig`, and the C worker is built on it.
   - The release-on-drop setting is a Host option in Zig and C, which the
     bindings project.

## Scope (what this does not decide)

- No code lands with this ADR. Each numbered step is its own change with its
  own evidence, in the order given, and step 1 alone is useful.
- It does not change CapTP semantics, the C Host tier (`libglowcap_host`), or
  the sans-io core. The byte-fed Host stays the embedding for hosts that own
  their own I/O.
- It does not decide whether `Session` listeners take `Value`.

## Alternatives Considered

- **Keep three runtimes and document the gap.** Rejected: every fix and every
  measurement would still have to be made three times, and the scale claim
  would stay a claim about a path users do not run.
- **Make Bridge the public front.** Rejected: HostRuntime already owns
  admission, listeners, providers, residents and shutdown for every binding.
  Moving all of that onto Bridge is the same work with a larger break.
- **Pool buffers inside HostRuntime's own stream wire.** Rejected: it builds a
  second pool beside the loop's and keeps two read paths to measure.

## Consequences

- `HostRuntime` grows a completion-loop backend for stream netlayers and loses
  `stream_wire.Buffers`.
- `driver.BlockingSession` and its constructors are deleted, with the tests,
  examples and interop drivers that use it moved to `driver.Session`.
- `bench/peer_scaling` measures through `HostRuntime`. The ladder's scale step
  and the performance page then describe the product path.
- Binding retry loops, their docs, and their tests are removed in step 4.

## Evidence and gate

- The 500,000-session scale run through `HostRuntime`, at no more memory per
  session than the `Bridge` run. Met on 2026-10-13: 3,804,768 KiB of
  incremental server RSS against the `Bridge` run's 3,974,548 KiB on the
  same machine class, recorded in `docs/ladder.md`.
- `bench-peer-scaling` shows zero buffer bytes per idle stream wire.
- `zig build check runtime-check check-external` and every binding check
  green on the shared runtime.
