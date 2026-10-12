# One I/O runtime, lane B: one policy home

Status: active plan. The [one I/O runtime plan](one-io-runtime.md) owns the
rules every batch follows, the survey, the baseline, and the description of
what already exists. Read it first. This lane moves dial retry into
`HostRuntime` and makes release on drop a Host option in Zig and C. This file
is deleted when its last batch is.

Order: B1 then B2. B3 then B4. The two pairs are independent of each other
and of lane A, except that B2 touches `interop/iroh_reachability/driver.zig`
only after A4 is on `dev`.

### B1 seam: `HostRuntime` retries a staged dial

Scope: `src/driver/dial_retry.zig`, `src/driver/mod.zig` (the five
`dial_retry` re-exports), `src/driver/host_runtime/{contract,opens,pending,step}.zig`,
`test/driver/dial_retry_test.zig`, `test/driver/host_runtime_multiplexed/residents.zig`,
a new `test/driver/host_runtime_step/dial_retry_test.zig`, `test/all_test.zig`,
`tools/check/source_check/bans/layers.zig` (the two `why` strings),
`docs/decisions/adr/ADR-0082-adapter-continuity-and-host-resource-honesty.md`
(an `amended_by` link only). Out of scope: bindings, interop, the C driver's
exported signatures.

Tier assumed: the planner's own tier. The mechanism is decided below. Its
placement inside the pump needs reading `resident_pump.zig` and `step.zig`.

Read first: `src/driver/host_runtime/opens.zig` (`startDial`, `stageDial`,
`advancePendingOpens`, `adoptPendingResidentDial`),
`src/driver/host_runtime/step.zig:231` (`clampTimeoutToPendingWork`), `src/driver/dial_retry.zig`,
`src/net/transport/iroh/resident.zig:373` (the transient classification the
sidecar projects).

The mechanism:

- `HostRuntime.Options` gains `dial_retry: driver.DialPolicy = .discovery()`
  and `on_dial_outcome: ?driver.OnDialOutcome = null` with its context. The
  defaults keep today's binding budget (24 attempts, 3000 ms) so the interop
  reachability proofs see the same wall clock.
- `PendingOpen.Stage` gains `retry_wait: struct { resident: usize, attempt: u32, due_ms: i64 }`.
- In `adoptPendingResidentDial`, a `.failed` outcome whose
  `failure.classification` is transient (`driver.isTransientDialError`), whose
  `attempt` is below `dial_retry.max_attempts`, and whose row `deadline_ms` is
  null or later than `now + retry_interval_ms`, moves the row to
  `retry_wait` with `due_ms = now + retry_interval_ms` and reports
  `.transient_retry`. Otherwise the row fails as today and reports
  `.permanent` or `.exhausted`. Success reports `.ok`.
- `clampTimeoutToPendingWork` treats a `retry_wait` row's `due_ms` like a
  deadline. `advancePendingOpens` re-issues the resident's `startDial` for a
  `retry_wait` row whose `due_ms` has passed, with a fresh request id, and
  moves it back to `resident_dial`. The row's
  `HostSession` and admission are kept across attempts. The hello is still
  queued and flushes on the first wire, as today.
- `DialRetry` (the struct with the blocking `dial` executor and its
  `sleep_ms` callback) is deleted. `dial_retry.zig` keeps `DialPolicy`,
  `DialOutcome`, `OnDialOutcome`, `isTransient`, and the two constants, and
  its header says the runtime executes the policy. `driver.DialRetry` and
  `driver.OnDialOutcome` re-exports follow.
- `test/driver/dial_retry_test.zig` keeps the classification and the
  constant-lockstep tests and loses the executor tests. The new
  `host_runtime_step/dial_retry_test.zig` drives a `HostRuntime` over the
  hermetic resident in `residents.zig`, which gains
  `fail_dial_transient: u32` (fail that many `finishDial`s with
  `error.NetworkUnreachable`, then connect) and `fail_dial_permanent: bool`
  (`error.ConnectionRefused`). Scenarios: a transient fault under the budget
  connects on the next attempt and the hook saw `transient_retry` then `ok`.
  A permanent fault fails at once. The attempt budget exhausts. A handshake
  deadline shorter than one interval fails without waiting.
- ADR-0082's frontmatter gains `amended_by: [ADR-0193]` and the `layers.zig`
  `why` strings say the runtime consumes the policy.

Preserve: `GLOWCAP_DISCOVERY_DIAL_RETRY_MS` and
`GLOWCAP_DISCOVERY_DIAL_MAX_ATTEMPTS` keep their values and generated
mirrors. The C driver's exported signatures do not change (it inherits the
Host default). Every existing `host_runtime_step` test passes.

Refusals: a retry that would resend the hello or rebuild `HostSession` state
(stop: the row keeps its session). A sleep or thread inside the runtime.

Verify: `zig build test -Dtest-layer=driver`, `zig build test`, then
`zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section.

### B2 sweep: delete the binding and interop retry loops

Scope: `bindings/rust/src/iroh.rs`, `bindings/python/glowcap/_iroh_async.py`,
`bindings/ts/iroh/{channel,impl}.ts`, `bindings/racket/private/iroh/runtime.rkt`,
`interop/iroh_reachability/driver.zig`, the docs of those four iroh packages
where they describe the loop, `docs/roadmap.md`. Out of scope: `src/`,
`bindings/ts/web/relay_budget.ts` (it derives an allowance from the
constants, which stay), `tools/gen/`.

Tier assumed: mid tier. `zig build bindings` and `zig build rust-dogfood`
hold the edits. `bindings-fmt-check` holds the formatting.

Predecessors: B1 on `dev`, and A4 on `dev` for the interop file. Read first:
B1's closing note, `bindings/rust/src/iroh.rs:438` to `456`.

Rule per site:

- Rust: delete `dial_resolving`. `connect_owned` calls `iloop.dial` once and
  returns its error. Delete the `DISCOVERY_DIAL_*` imports at `iroh.rs:31`
  if nothing else in the file reads them, and the comment block that
  describes the loop.
- Python: delete `_dial_resolving` and `_DISCOVERY_DIAL_RETRY_S`.
  `_open_byte_channel` calls `loop.dial` once. Its `retry_discovery`
  parameter and every caller argument are deleted. Delete the
  `DISCOVERY_DIAL_*` imports if unused.
- TypeScript: delete `settlesWhileResolving` and `dialResolving` from
  `channel.ts`. `impl.ts:125` calls `loop.dial(nodeId, directAddresses)`.
  Delete the two constant imports from `channel.ts` if unused.
- Racket: delete `dial-resolving` and `DISCOVERY-DIAL-RETRY-S`. The two call
  sites (`runtime.rkt:472`, `:492`) call `loop-dial!` once. Delete
  `propagating-discovery?` if nothing else reads it.
- `interop/iroh_reachability/driver.zig`: delete `callByIdOnlyRetrying` and
  the budget comment block. `main` calls `callByIdOnly` directly. The header
  sentence about `connect(locator)` dialers settling under discovery now says
  the runtime's dial retries transient faults on the shared budget.
- Each package's doc sentence that described a binding-side retry (grep the
  package for `DISCOVERY` and `retry`) now says the runtime dial retries on
  `GLOWCAP_DISCOVERY_DIAL_*` and a raw transport dial is one attempt.
- `docs/roadmap.md`: in the "One policy home" row, remove the dial-retry
  clause and its evidence sentence.

Preserve: every binding's public `connect` signature except the deleted
`retry_discovery` keyword. The four binding proofs under
`bindings-iroh-redeem-posture` and `bindings-verb-spine`. The TS
`IROH_RELAY_DIAL_ALLOWANCE_MS` derivation.

Refusals: a binding test that only passes with a binding-side sleep loop
(stop and name it: the runtime budget is the one to adjust, in `src/`).

Verify: `zig build bindings-fmt-check`, `zig build rust-dogfood`,
`zig build deno-dogfood`, `zig build python-dogfood`, `zig build racket-dogfood`,
then `zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section.

### B3 seam: release on drop is a Host option in Zig and C

Scope: `src/driver/core/host/configuration.zig`, `src/c_abi/host/host.zig`,
`src/c_abi/host/symbols.zig`, `tools/gen/header/host.zig`,
`include/glowcap_host.h` (generated), the generated binding mirrors
(`gen-ts-abi`, `gen-binding-constants`, `gen-binding-rust-ffi`,
`gen-binding-python-ffi`, `gen-binding-racket-ffi` and their checks),
`test/c_abi/`, `docs/architecture.md` (the options table),
`docs/decisions/adr/ADR-0192-rust-releases-on-drop-by-default.md`
(`amended_by` only). Out of scope: binding source other than the generated
mirrors (B4).

Tier assumed: the planner's own tier for the Zig option and the C verbs. The
`gen-*` regeneration is mechanical.

Read first: `src/driver/core/host/configuration.zig:34`,
`src/c_abi/host/host.zig:125` to `180`, `.agents/rules/cli.md` (Generated
State), `bindings/README.md`.

The mechanism:

- `driver_core.Host.Options` gains `release_on_drop: bool = true`, documented
  as the Host-wide setting a binding projects when its language has a scope
  end the binding can observe (ADR-0192), and that a Zig consumer reads with
  `Host.releaseOnDrop()` and changes with `Host.setReleaseOnDrop(bool)`.
  The sans-io core stores and reports it. It attaches no behavior there.
- `glowcap_host_new` and `glowcap_host_new_in` gain a `release_on_drop: u32`
  parameter after `local_turn_budget`. Two host-archive exports are added
  under the same prefix, a read verb (host, out pointer to `u32`) named
  release_on_drop and a set verb (host, `u32`) named set_release_on_drop,
  with header prose in `tools/gen/header/host.zig` and rows in `symbols.zig`.
- Every `gen-*` step that embeds the host archive fingerprint or the symbol
  table is rerun, and every `gen-*-check` passes.
- `test/c_abi/` gains the construct, read, set, read round trip.
- ADR-0192 gains `amended_by: [ADR-0193]`. The options table row in
  `docs/architecture.md` lists the Zig and C names.

Preserve: every other `glowcap_host_*` signature. The Rust `Host::set_release_on_drop`
public name (B4 reroutes it).

Refusals: any attempt to keep the old `glowcap_host_new` arity beside the new
one.

Verify: `zig build gen-header-ocapn gen-ts-abi gen-binding-constants gen-binding-rust-ffi gen-binding-python-ffi gen-binding-racket-ffi`,
then every matching `gen-*-check` in one invocation, then `zig build check`.
The bindings will not compile until B4. `check` does not build them, so the
report says so.

Commit authorized. Close by deleting this section.

### B4 sweep: the four bindings project the Host option

Scope: `bindings/rust/src/{host.rs,gc.rs,host/public.rs,host/vows.rs,session.rs}`,
the `glowcap_host_new` call sites in `bindings/python/glowcap/_host/__init__.py`,
`bindings/racket/private/host.rkt`, `bindings/ts/runtime/host/state.ts`,
`bindings/ts/web/test/wasm_handshake_smoke.ts`, `bindings/rust/src/host/lifecycle.rs`,
and `docs/roadmap.md`. Out of scope: `src/`, `tools/gen/`.

Tier assumed: mid tier. The binding checks hold every edit.

Predecessor: B3 on `dev`. Read first: `bindings/rust/src/host.rs:140` to
`160`, `bindings/rust/src/host/public.rs:185` to `195`.

Rule per site:

- Every `glowcap_host_new` or `glowcap_host_new_in` call passes
  `release_on_drop` after `local_turn_budget`: Rust passes `1`. TypeScript,
  Python, and Racket pass `0` because their release rides a finalizer and
  their per-session `withGc` / `with_gc` / `session-with-gc!` opt-in stays
  (ADR-0192).
- Rust: delete the `release_on_drop: Cell<bool>` field and its two
  initializers. `Host::set_release_on_drop` calls the B3 set verb. `gc.rs:152`
  and `host/vows.rs:174` call the B3 read verb. The doc comment on
  `set_release_on_drop` says the setting lives on the Host archive.
- `docs/roadmap.md`: in the "One policy home" row, remove the release-on-drop
  clause and its evidence sentence.

Preserve: the Rust GC tests pass without an opt-in. The TS, Python, and
Racket `verb_spine` proofs pass with their session opt-in. No binding gains
a second copy of the flag.

Refusals: a binding that needs the flag per session (stop: ADR-0192 placed
it on the Host).

Verify: `zig build rust-dogfood`, `zig build deno-dogfood`,
`zig build python-dogfood`, `zig build racket-dogfood`,
`zig build bindings-verb-spine`, `zig build bindings-fmt-check`, then
`zig build check` and `zig build runtime-check`.

Commit authorized. Close by deleting this section.
