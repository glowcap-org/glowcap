# Runtime and capability semantics

Status: active plan. The [roadmap](../roadmap.md#runtime-and-capability-semantics)
owns its priority. An outside review of the library by an OCapN and Goblins
practitioner found these gaps between the current design and the one a reader
would expect. Each item names its decision, its first step, and the evidence
that closes it. Items marked **decision** need the maintainer's call before
code.

## Turn semantics

1. **A failed turn still sends its messages.** On a handler error the Vat
   drops only the staged `become` (`src/actors/vat/turn.zig`). Local sends are
   already queued and far sends already recorded on the Peer, so a turn that
   throws halfway still emits half its effects. Goblins drops the turn's
   messages and spawns and still sends the break (`core.rkt`, the `new-msgs`
   reset). ADR-0060 says there are no general transactional turns.
   - The blocker is the far send. `outbound.enqueueRecorded` records the answer
     row, export retains, the 1.0 resolver, next's paired listeners and Node
     lowering in one step that can fail. Holding a send until the turn commits
     needs that step split into a fallible prepare and an infallible commit, so
     a send failure still reaches the handler.
   - First step: an ADR for the outbound prepare/commit split and the turn as
     the unit of rollback (sends, spawns, exports), then the split, then Vat
     staging.
   - Evidence: a turn that sends locally and far, then errors, puts only the
     break on the wire; an error caught by an outer frame keeps inner sends;
     the Vat footprint pin holds or the ADR justifies the growth.

## Publication and reclamation

3. **decision: one publication table, unguessable by default.** A Session has
   its own bootstrap table beside the Host's giftable table, fetch consults them
   in an order no document states, and the examples publish guessable names.
   "Giftable" does not describe what the table holds, and a removed durable name
   can be bound again.
   - Proposed shape: one Host-owned table; `publish(capability)` returns a
     sturdyref with a random swiss number, `publishWellKnown(name, capability)`
     is the explicit guessable form, and a removed durable name stays retired
     for the Host's lifetime.
   - Cost: a rename across the C ABI, every binding, the CLI, Rooms and the
     examples. Needs an ADR.

4. **decision: distributed GC on where release is deterministic.** Every
   binding leaves GC off by default, per session (ADR-0063), so each fetched
   reference pins a partner export for the life of the session. Rust's `Drop`
   is deterministic, so releasing on drop there adds no hidden runtime.
   - Proposed shape: Rust releases on drop by default, the setting moves from
     the session to the binding's Host, and finalizer-based bindings stay opt-in.
     Amends ADR-0063.

5. **A revoked grant's publication keeps answering.** Revocation is checked on
   every call, but the grant's rooted publication waits for maintenance, so a
   fetch of a dead name wakes an endpoint only to fail.
   - First step: a terminal revoke enumerates its dependent endpoints, leases
     their publications during prepare, and retires them in the same batch,
     refusing with `RetirementRequired` over custody capacity, as maintenance
     does.

## One I/O runtime

6. **The measured loop is not the one applications run.** The 500,000-session
   run used `Bridge(TcpLoop)`, with a shared read pool. `driver.Session`,
   `HostRuntime`, the C driver and every binding run `HostRuntime`, which gives
   each stream connection its own read and write buffers. `BlockingSession`
   is a third runtime with its own value types, and dial retry is copied into
   each binding.
   - First step: an ADR for one runtime on the completion loop with pooled
     buffers behind every front, `Bridge` internal, `BlockingSession` replaced
     by a single-wire Host, and homes for dial retry, a stock Zig Loam worker
     and the GC setting.
   - Evidence: the scale run through `HostRuntime`, and binding checks green on
     the shared runtime.

Further ADR candidates, not scheduled: Loam actors that share the Vat actor
shape and upgrade older records lazily; durable swiss numbers derived from the
Host seed rather than stored raw.

## Product polish

7. **Rooms web relay failures are not actionable.** `rooms web: relay ended:
   iroh relay dial timed out` repeats once per browser relay attempt and names
   neither the destination nor whether the page can still reach its directory.
   - First step: name the destination designator in the notice and collapse
     repeats for the same destination.

9. **decision: Loam performance on the site.** The Loam benchmarks record
   results by hand in `bench/loam/results.md`; the performance page has no Loam
   section.
   - Proposed shape: a Loam section on the existing performance page, generated
     by `bench-site-report` like the others, answering four questions: how long
     a call to a sleeping actor takes, how resident memory stays flat as the
     graph grows, what a commit costs, and how long a restart takes to serve its
     first call.
