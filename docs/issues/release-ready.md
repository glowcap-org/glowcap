# Release-ready failure containment

This is the active checklist for the failure-mode sweep across pancake's core,
native runtimes, C ABI, bindings, and first-party consumers. It is temporary:
remove an item only in the same checked commit that fixes it or proves the
named path cannot fail. Delete this file when no items remain.

The project-wide contract is that a runtime failure leaves a definite state,
settles every unit of work it owns, and reaches an observable boundary with
its exact first cause. Cleanup and diagnostic failures remain attached without
replacing that cause. No failure after process initialization is fatal to the
process. Optional observers may be lossy, but their loss is explicit and never
changes protocol success into apparent success or failure.

The portable Zig core owns protocol and session semantics. Runtime adapters
own I/O, scheduling, synchronization, and host integration. The C ABI and
bindings project the core outcome into each runtime's error, task, and lifetime
idioms; they do not retry, recover, or invent protocol or application policy.

## Native core and runtime seams

- [ ] Audit every Session, actor, promise, resolver, import, and export state
  transition for failure before and after authority is committed. Refusal,
  cancellation, duplicate settlement, release, and peer abort must settle all
  affected work exactly once without orphaned table entries.
- [ ] Audit transport read, write, accept, dial, and close state machines for
  local cancellation, peer close, malformed frame, deadline, backpressure,
  provider failure, and runtime shutdown. Dial and accept and all transport
  implementations must agree on which owner records and returns each outcome.
  Active stream and multiplexed listener infrastructure failures now retire
  exactly that listener through a pre-reserved `LISTENER_FAILED` event; the
  loop remains usable and already yielded sessions remain owned by their
  consumers. Provider-defined accept and readiness failures now cross both
  stream and multiplexed archive boundaries as one bounded typed chain and
  arrive unchanged in that correlated terminal event. Read/write retention is
  still covered by the archive-boundary item below.
- [ ] Propagate fallible native listener and runtime teardown, including Onion
  Unix-socket removal. Cleanup after a primary failure must be retained as a
  secondary cause; cleanup without a primary failure must be returned.
- [ ] Audit allocation failure in close observers, failure sinks, and other
  diagnostic append paths. Preserving diagnostics may degrade without changing
  protocol state, but the implementation must retain a bounded indication that
  diagnostics were lost rather than silently claim a complete record.
- [ ] Prove or convert every production `catch unreachable`, `unreachable`,
  and panic-capable assertion in driver, actor, transport, and foundation code.
  Caller input, resource pressure, peer behavior, and shutdown races are never
  internal invariants.

## C ABI projection

- [ ] Audit every exported operation from argument validation through return
  code, `last_error`, `last_abort`, and output ownership. Every distinct core
  failure must have one stable projection, and stale diagnostic state must not
  leak across calls.
- [ ] Prove rollback and ownership for every partially initialized host,
  session, listener, transport, resolver, byte buffer, and callback context.
  No C-visible failure may leak an owned object or leave a live handle whose
  state is unknowable.
- [ ] Contain every foreign callback panic, exception, or invalid result at
  the callback boundary, settle its owning operation, and preserve the exact
  diagnostic without unwinding through Zig or C.
- [ ] Carry provider callback diagnostics across archive boundaries as data,
  not only a classified status. Stream-connection release now carries its
  concrete primary cause, first secondary cause, and total secondary count.
  Provider-package retain, rollback release, final release, stream-listener
  release/setup, and stream and multiplexed dial start/finish now use the same
  contract. Dial refusal is one reserved `OPEN_FAILED` outcome whether the
  provider refuses immediately or after readiness, and preserves its exact
  primary name, first consequence, portable categories, and total consequence
  count without making an ordinary refusal Host-wide fail-stop state. External
  connection adoption now uses that same reserved outcome and structured
  provider report instead of returning an uncorrelated status before minting
  an operation identity. Accept uses the same direct report. Status-shaped
  read/write callbacks retain their
  first exact failure in one connection-owned latch; HostRuntime atomically
  claims it at wire retirement and projects it through the existing
  `SESSION_CLOSED` recipient. The latch adds no allocation, global journal, or
  successful-wire-path copy. Forced stream and multiplexed fixtures prove the
  exact primary, first cleanup, total cleanup count, and one-shot claim at that
  event.
- [ ] Read the complete C ABI cold for retry, recovery, protocol, scheduling,
  or application policy. Move any such logic to its Zig or host-runtime owner;
  the ABI remains lifetime and data plumbing only.

## Rust binding and relay

- [x] Retain cleanup failures during `Runtime` construction. If opening or
  configuring a newly created Host fails, Host close failure must be attached
  to the exact primary error instead of discarded.
- [x] Retain detached dial, listener, and server teardown failures in
  `dial.rs`, `driver_loop.rs`, `onion.rs`, `tcp_listen.rs`, `iroh.rs`, and
  `server.rs`. The owning Runtime, Host, Session, or server close barrier must
  expose them.
- [x] Give `HostShared::drop` and other implicit destruction a non-panicking,
  diagnosable owner. An implicit destructor may delegate to a deterministic
  close path, but it may not silently leak a callback context after release
  fails.
- [x] Make Onion and relay explicit consuming close retain both an earlier
  child-close failure and the later native parent-release failure. Their Drop
  fallbacks must publish failure to a surviving diagnostic owner rather than
  assigning the checked result to `_` after the object is gone.
- [x] Make panicking `ActorCell` destruction in the trampoline diagnosable
  while still preventing unwind across C.
- [x] Remove runtime-reachable synchronization-poison panics from iroh and
  relay paths. Poisoning must become a contained terminal error or be recovered
  under a proved invariant; public calls and background tasks must not panic.
- [x] Audit failed channel sends, task joins, and detached task exits. A send
  failure is ignorable only after proving the receiver owner is already
  terminal and the same operation is settled elsewhere.
- [x] Propagate writer and WebSocket close failures in the Rust reference
  relay while preserving the relay's first failure.
- [ ] Run the complete binding against forced callback panic, runtime shutdown,
  listener close failure, dial cancellation, refusal saturation, and concurrent
  explicit/implicit close; assert exact error and stable post-failure state.

## TypeScript binding and relay

- [ ] Prove that WebSocket, TCP, iroh, and in-process transport adapters settle
  reads, writes, serving, and close exactly once under peer close, local close,
  callback throw, and shutdown races.
- [ ] Verify that generated ABI mappings and error wrappers preserve all C ABI
  distinctions without retry or protocol policy in TypeScript.
- [ ] Run the complete binding and reference relay against forced callback
  throw, transport close failure, detached serve rejection, refusal
  saturation, and concurrent close; assert exact error and stable state.

## Python binding and relay

- [x] Make `Session._join_close_barrier` preserve the exact first error while
  retaining later transport, `wait_closed`, and serve-task failures instead of
  dropping them.
- [ ] Audit Host and loop close aggregation for concurrent operation, serve,
  transport, resolver, and native release failures. Every accepted task must
  settle and every secondary failure must remain inspectable.
- [x] Separate explicit native-handle retirement from `weakref.finalize` for
  Onion and relay. Explicit close now checks the returned native status;
  finalizer-only release records its exact refusal in a bounded, nonfatal
  process diagnostic journal with observable saturation.
- [ ] Prove WebSocket, relay, and other asynchronous adapters join all owned
  tasks and preserve failure order during peer close, local close, cancellation,
  and event-loop shutdown.
- [ ] Verify that exception translation preserves all C ABI distinctions and
  carries no retry or protocol policy in Python.
- [ ] Run the complete binding and relay against forced callback exception,
  transport close failure, detached serve exception, refusal saturation, and
  concurrent close; assert exact exception and stable state.

## Racket binding and relay

- [x] Preserve failed-dial rollback cleanup failures in `private/dial.rkt`
  without replacing the primary dial refusal. Cleanup and Host-owned
  background `session-serve` failures reach the Host close barrier.
- [x] Propagate listener, loop, and shutdown failures in `private/loop.rkt`.
  Background loop termination settles admitted operations and surfaces at the
  owning Host close barrier.
- [x] Propagate detached WebSocket task and close failures in
  `private/ws-transport.rkt`; only a proved peer close becomes EOF. WebSocket
  and iroh background work retain their first failure at the owning close
  barrier.
- [x] Audit every exception handler in `private/session.rkt` and adjacent
  trampolines. Behavior exceptions projected as broken vows are expected;
  cleanup, scheduling, and native errors must not be misclassified or dropped.
- [x] Keep tracing and optional observer callbacks non-load-bearing while
  giving callback failure an explicit diagnostic owner.
- [x] Prove that Onion and relay finalizers cannot become the only observer of
  a failing native release. Explicit release checks status; finalizer fallback
  must record failure outside the object being collected without raising
  across the collector.
- [x] Preserve first and secondary byte-channel and WebSocket close failures in
  the Racket reference relay.
- [x] Verify that exception translation preserves all C ABI distinctions and
  carries no retry or protocol policy in Racket.
- [x] Run the complete binding and relay against forced callback exception,
  transport close failure, detached serve exception, refusal saturation, and
  concurrent close; assert exact exception and stable state.

## First-party consumers and diagnostics

- [ ] Replace the discarded accountability Host future failure with an owned
  task/barrier whose exact result is observed during operation or shutdown.
- [ ] Remove silent allocation failure from rooms-peer phase and peer tables.
  Optional presence may be dropped by explicit bounded policy; authoritative
  connection and phase state may not disappear under OOM.
- [ ] Audit rooms-peer and other CLI harness background writes, handler tasks,
  and shutdown. Every failure must either reach the command result or a named
  diagnostic sink before the owner terminates.
- [ ] Replace discarded session stepping and close errors in the interactive
  CLI and REPL with a definite connection state and visible command result.
  Optional completion history, tips, and display updates may degrade under OOM
  only under an explicit local-UX policy that cannot hide networking failure.
- [ ] Audit CLI operability and supervision: log and stderr write failure,
  signal polling, process termination, identity/state-file persistence, child
  wait, and shutdown sleeps. Startup policy may choose to exit; once running,
  an operational failure must be contained and leave supervised state definite.
- [ ] Audit the pancake MCP request loop for framing discard, response-write,
  task, sleep, and shutdown failures. One malformed request or failed client
  connection must not poison the server or strand accepted CapTP work.
- [ ] Audit every first-party relay for symmetric read, write, task, listener,
  and transport-close handling. A relay must preserve its exact first failure
  and join or cancel all work it accepted.
- [ ] Give lossy visualization telemetry and optional presence publication an
  explicit bounded-loss contract and diagnostic owner. Their failure must
  remain distinct from Host, Session, and protocol success.
- [ ] Classify every remaining ignored browser storage, UI focus, tracing,
  metrics, and finalizer error as either optional local policy or a real
  runtime defect. Keep only the former, name its bound, and make its loss
  diagnosable where useful.
- [ ] Build and exercise the rooms iroh path, including reconnect and supervised
  restart, with no `pancake-iroh: connect failed: timed out` regression and no
  replacement log that merely hides the same stalled authority.
- [ ] Audit the tasks, tools, accountability, rooms, and visualization apps in
  every implemented language for unobserved calls, tells, fetches, tasks, and
  shutdown. Application policy chooses presentation, but must receive the
  complete library failure first.
- [ ] Make shipped examples demonstrate exact error and deterministic cleanup
  rather than suppressing futures, session drains, sleeps, or teardown. Test
  and proof harnesses may assert failure, but may not accidentally teach a
  production pattern that drops it.

## Cross-layer proof and architecture

- [ ] Add deterministic failure injection for broken wake descriptors,
  readiness removal/drain faults, notification-after-commit, allocation
  failure, queue saturation, listener close failure, callback panic/exception,
  transport shutdown, synchronization poison, and concurrent close.
- [ ] Exercise Onion and relay final package release after constructor and
  child leases retire in every legal order. Inject an asynchronous listener
  cleanup failure and a wake failure, and prove the unified chain reaches
  native close, C driver release, and each binding's explicit close barrier.
- [ ] For every injected failure, assert the exact public error, all accepted
  work settled exactly once, definite post-failure state, bounded resource
  ownership, and a non-fatal process. Exercise both dial and accept and every
  transport sharing the changed contract.
- [ ] Run cross-language proof scenarios through Zig, Rust, TypeScript, Python,
  and Racket for the same forced native failures. A binding-specific wrapper
  may differ, but error identity, authority transition, and resource ownership
  must be equivalent across languages.
- [ ] Audit all production `panic`, `unreachable`, Rust `unwrap`/`expect`,
  unobserved Promise/task, and broad exception catch sites. Each survivor must
  be a proved internal invariant, an explicit optional policy with a diagnostic
  owner, or test-only code.
- [ ] Audit every occurrence and synonym of `best-effort`, ignored, swallowed,
  detached, fire-and-forget, and lossy in source, docs, examples, and rules.
  Remove stale guidance after strengthening code; retain only explicit bounded
  product policy or inherently nondeterministic optimization that correctness
  does not depend on.
- [ ] Encode the generic failure-containment principles in project-wide rules,
  and the core/C ABI/binding projection details in focused architecture and
  binding rules. Add checks that catch the concrete defect classes learned in
  this sweep rather than relying on future agent memory.
- [ ] Read core, runtime hosts, C ABI, and all bindings cold for duplicated
  runtime-shaped state machines. Consolidate genuinely shared synchronous,
  sans-I/O lifecycle machinery at its narrow authority when that thins every
  binding without moving scheduling, I/O, or host policy into the core.
- [ ] Prove that C ABI and bindings contain no business or protocol logic after
  consolidation. Similar host-runtime plumbing may share a construct; host
  exception, task, scheduler, and transport idioms remain in their adapters.
- [ ] Reconcile `docs/vision.md`, architecture, ADRs, shipped inventory,
  boundaries, examples, generated inventories, and focused rules with the
  resulting contracts. No document may continue to promise or excuse the old
  behavior.

## Release gates

- [ ] Run focused unit and failure-injection tests after each repair, then
  commit that checked repair independently and remove only its proven row.
- [ ] Run formatting, source generation, C header generation, TypeScript ABI
  generation, core tests, oracle conformance, external/Goblins conformance,
  every binding dogfood suite, CLI tests, examples, relays, and rooms builds.
- [ ] Run `zig build check` from a clean tree and record any unavailable
  external authority separately rather than treating an unrun gate as green.
- [ ] Review the final diff and tree cold: no unrelated or concurrent-agent
  changes included, no unowned generated drift, no new failure sink introduced,
  and every checklist repair present in an incremental checked commit.
- [ ] Delete this file only after all preceding rows have been removed by their
  proving commits and the final clean-tree gates pass.
