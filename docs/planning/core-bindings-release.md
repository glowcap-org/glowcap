# Core and bindings release closure

Status: active plan. It contains only incomplete work needed to call pancake's
portable core, native runtimes, C ABI, and supported language bindings
release-ready. Completed rows are removed rather than checked off, so delete
this file when the list becomes empty.

The scope excludes application and product roadmap work in `apps/`, the CLI,
rooms, visualization, and future protocol features. The release contract is
that every admitted operation settles exactly once, its first failure reaches
the narrowest surviving owner, later cleanup failures remain attached, and no
library-owned failure terminates the process.

## Native core and runtime

- [ ] Prove Session, actor, promise, resolver, import, export, release, and peer
  abort transitions settle exactly once without orphaned authority.
- [ ] Give listener, connection, provider, and runtime teardown a deterministic
  returned or retained outcome, including asynchronous cancellation/reaping and
  Onion Unix-socket removal.
- [ ] Convert or prove every production panic, `unreachable`, `catch
  unreachable`, and panic-capable assertion reachable from caller input,
  resource pressure, peer behavior, callbacks, or shutdown races.

## C ABI and provider boundary

- [ ] Audit every export from argument validation through stable result,
  `last_error`, `last_abort`, output ownership, and stale-state clearing.
- [ ] Prove transactional rollback for every partially initialized handle,
  listener, session, transport, resolver, buffer, and callback context.
- [ ] Contain every foreign callback panic, exception, and invalid result at its
  boundary while settling the owning operation with the exact failure.
- [ ] Read the complete C ABI cold and remove retry, recovery, protocol,
  scheduling, and application policy; the ABI retains only validation,
  lifetime, and data plumbing.

## Language bindings

- [ ] Run Rust through forced callback panic, runtime shutdown, listener close
  failure, dial cancellation, saturation, and concurrent explicit/implicit
  close, asserting exact failures and stable state.
- [ ] Prove WebSocket, TCP, iroh, and in-process TypeScript operations and
  close barriers settle once with ordered failures under the forced matrix.
- [ ] Verify TypeScript's generated ABI projection and error wrappers preserve
  every native distinction without binding-owned networking policy, then run
  the complete forced-failure matrix.
- [ ] Prove Python Host, loop, transport, resolver, and native close
  aggregation preserves ordered failure under the forced matrix.
- [ ] Verify Python exception translation and asynchronous adapters preserve
  native distinctions without binding-owned networking policy, then run the
  complete forced-failure matrix.

## Cross-layer closure

- [ ] Add deterministic injection for broken wake descriptors,
  notification-after-commit, allocation failure, queue saturation, listener
  close, foreign callback failure, transport shutdown, synchronization poison,
  and concurrent close.
- [ ] Exercise final Onion and relay package release in every legal child and
  constructor order, including asynchronous cleanup and wake failure.
- [ ] Run the same forced native failures through Zig, C, Rust, TypeScript,
  Python, and Racket and prove equivalent identity, authority transition,
  bounded ownership, nonfatal process behavior, and single settlement.
- [ ] Read core, native runtimes, C ABI, and bindings cold for duplicate state
  machines, parallel error authorities, swallowed failures, policy leakage,
  stale compatibility paths, and unmeasured wire-path costs; repair every real
  finding and update architecture, stability, and shipped claims.
- [ ] Run focused checks after each repair, then finish with generated-surface
  checks, all binding checks, protocol reference checks, external conformance,
  and `zig build check` from a clean tree.
