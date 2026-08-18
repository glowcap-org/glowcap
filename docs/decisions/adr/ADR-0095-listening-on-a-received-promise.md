---
id: ADR-0095
status: accepted
date: 2026-07-29
tags: [engine, session, driver, handoff, promises]
decision: "A peer asks how a far reference it holds settles with `engine.listen.listenOnFar`, and the notification is read back through one version-neutral resolver-export table shared with the V1.0 resolver callback."
supersedes: []
superseded_by: []
amended_by: [ADR-0111]
---

# ADR-0095 Listening on a received promise

## Context

pancake could hand a third party a promise but could not be handed one. The
introducing-session proxy ([ADR-0009](ADR-0009-three-party-handoff-substrate.md))
mints a third-party import-promise on a recipient session and relays the
settlement to it, and when that settlement names a capability the node signs a
give for each recipient. The recipient half was missing: nothing above the
engine sent an `op:listen` for a promise received as a value, so a pancake
recipient had nothing to wait on and the three-party promise shape could not be
driven end to end against itself.

The engine already carried the settlement machinery. What it lacked was the
question, and a way to read the answer. CapTP delivers a listen notification to
the listener export as a `fulfill` or `break` message, which is byte-for-byte
the shape a V1.0 resolver callback carries. The engine already had a table for
exactly that shape, `Session.v1_0_outbound_resolver_link`, but the probe that
read it sat behind a `needsV1_0Translation` gate.

## Decision

One table serves both mints, and the probe that reads it is version-neutral.
`src/ocapn/session/resolver_export.zig` owns the link between a *resolver
export* — an export of ours whose settlement is one of our outbound answers —
and that answer; the field on `Session` is `outbound_resolver_link`. The probe
moved out of `engine.v1_0.interceptInboundDeliver` and into
`engine.inbound.classifyInboundDeliver`, where it runs first on every session.
What is left of the V1.0 intercept is `registerPartnerResolver`, which installs
the resolver the *partner* advertised and stays gated.

The verb is `engine.listen.listenOnFar(peer, target)`. It refuses anything
but a far this session holds, reserves a listener export bound to a fresh
outbound answer through `Session.nominateResolverExport` — which installs that
answer, so ordering it before the send is the verb's property rather than the
caller's — and queues one `op:listen`. It returns the answer, so the
tiers above express it as an ordinary vow: `driver_core.Served.listenTo`,
`driver_core.Host.listenTo`, `driver.Session.listenTo` / `listenSettled`, and
`driver.BlockingSession.listenTo` / `listenSettled`. Because the notification
surfaces as a resolve, the give arm that already reads a call's reply
(`Host.hostBeforeServe`, `actors.vat.serve.serveResolve`) reads a listen's
settlement too, and no new give path exists anywhere.

`Node.armHomeProxy` now queues a flush for the home session when it arms a
proxy. The `op:listen` it enqueues rides a session no verb is driving — the
recipient's session is the one being fed — so without that notice the home
peer's outbound was never encoded and the exporter was never asked.

## What is shared between profiles, and what is not

Both profiles carry the listen notification, so the widened probe is spec
behavior rather than V1.0 behavior reached by a second route. The pinned draft
CapTP text says that on receiving `op:listen`, "a mechanism MUST be setup to
fulfill or break the provided resolver when a resolution is available to the
`listen-desc` object". Its promises section defines `fulfill` and `break` on
the resolver object, and Goblins CapTP v1.0 settles a resolver callback the
same way. One table describes one wire shape.

How each profile asks for answer notification stays distinct. On V1.0 an
answered `op:deliver` is augmented with a synthesized resolver export and
settles through a callback deliver
(`engine.v1_0.installResolverForOutboundDeliver`,
`encodeResolveAsCallback`, `session.v1_0.mintOutboundResolver`). Next sends an
answered operation with no inline resolver, then follows it with a mandatory
`op:listen`. The listener callback settles the answer; next has no wire
`op:resolve`.

The two profiles also differ on `op:listen` itself. V1.0 canonically emits
Goblins's third Boolean `wants_partial` operand. Its decoder also accepts the
older two-operand shape as `#f` / settling-only, strictly as compatibility with
the earlier OCapN text; pancake never emits that legacy form. Next carries
integer mode 1, 2, or 3. Both translate to `model.ListenMode` at the codec edge.
[ADR-0111](ADR-0111-next-promise-listeners.md) records the next-profile
amendment.

## Scope (what this does not decide)

- A listen on a *near* export, on a bare `promise` reference, on a sturdyref, or
  on a broken reference is refused `InvalidReference`. Only a far this session
  holds is a legal target.
- `listenTo` asks only for settling on both profiles. On next, the private
  mode-1 listener installed when the remote promise arrived is already the one
  shortening subscription PR 282 permits; the application listen is the later
  mode-2 request for its settled result. The public tiers do not expose a mode
  parameter.
- `Node.armHomeProxy` keeps its own claim path. Its listener export carries no
  resolver link, so the two probes are disjoint by construction, and it stays
  separate because its settlement consumer is different: it fans one home
  settlement out to N recipient stores and mints no vow. Both claim paths move
  their mode-2 listener to the current target when the promise shortens.
- The C ABI verb is `pancake_host_session_listen`; each language binding exposes
  the same far-reference listen under its Host/Session face. An unrelated
  `listen` on some bindings still means accept connections.
- No live partner has been asked to play *this* seat, where pancake waits on a
  promise a partner introduced, so the verb's own evidence is in-tree
  ([community-review](../../community-review.md) holds the proven/unproven
  split).

## Alternatives Considered

- **A second table keyed on listener exports.** Rejected because it would key
  the same wire shape twice, and a deliver matching both would have to pick one
  by precedence, which is the kind of ambiguity a single owner removes.
- **Restrict the target to third-party imports.** Rejected because CapTP admits
  a listen on a settled capability and answers it immediately, which pancake's
  own inbound handler already does
  (`engine.pipeline.fireLiveObjectExportListener`). Refusing the shape we serve
  would be asymmetric.
- **Surface the notification as a deliver and let the application decode it.**
  Rejected because it would push protocol authority above the engine, and every
  consumer would need its own give arm.

## Consequences

- `src/ocapn/session/resolver_export.zig` is new; `session/v1_0.zig` keeps only
  the V1.0-specific half. The session field `v1_0_outbound_resolver_link`
  became `outbound_resolver_link`.
- `engine.inbound.InboundDeliverClass.v1_0_resolve` is now
  `.resolver_callback_resolve`, and `engine.v1_0.InboundIntercept` is gone.
- `src/ocapn/engine/listen.zig` is new, one verb, no allocation on the wire
  path: `sendCopying` clones an `op:listen`'s two position-only references.
  Three POD rows per live application listen, in tables no partner can grow:
  every row is minted by this side, so the bound is the application's own
  listens. Next also maintains one private shortening subscription per remote
  promise.
- Evidence: `test/engine/relay_resolution_test.zig` (the verb, both profiles,
  fulfill and break, per-profile arity, refusals),
  `test/engine/resolver_export_test.zig` (the probe on both profiles, the
  ordinary-export negative, resolve-once, and the next-profile settlement
  negative), and `test/driver/core_host/` (the host vow plus
  Host-identity relay across three sessions, with nested object and promise
  projection under both codecs).

## Notes

[ADR-0009](ADR-0009-three-party-handoff-substrate.md) owns the relayed
resolution and the give it settles with.
[ADR-0007](ADR-0007-promise-pipelining-substrate.md) owns the `op:listen`
substrate and the V1.0 resolver-callback translation whose table this
generalizes. [ADR-0010](ADR-0010-payload-descriptor-discriminator.md) owns the
perspective flip that makes a deliver to one of our exports arrive as a `near`,
which is what the probe reads.
