# Interface discovery

Status: active plan, waiting for maintainer review before work starts.
Phase three of [interface definitions](interface-definitions.md). It starts
after [the interface language](interface-language.md) lands. Delete this
plan when its steps land.

## What this is for

A program or an agent handed a reference has no file for it. This phase lets
it ask the object. The object answers with its description, the same value
its server was generated from, so the asker learns what it can call, what
comes back, and what can go wrong, from the one party that knows. An
attenuated reference answers for what it exposes. An object may decline. A
Goblins peer that never asks loses nothing.

## Where things stand

Every generated server has its description embedded and validates against
it. Nothing on the wire asks for it. Loam answers `describe-access` and
`describe-control` for the standing of a grant, paused or revoked, and that
stays where it is. The glowcap MCP server offers hand-wired tools.

## The decision

One reserved method under a namespaced symbol, proposed to the OCapN group as
an optional convention, takes an optional known fingerprint. With a matching
fingerprint it answers "unchanged", otherwise the description. The object
dispatches it, never the engine or the Host, so a revoked reference breaks it
like any other message. The reply is pure data with no embedded references,
encoded once per interface, with a fixed byte cap and a cap on methods. It
reports shape only. A method-not-found refusal carries the current
fingerprint, so a stale client learns to ask again in one round trip.

Every first-party forwarder and facet helper answers from its own subset, and
a test proves each one does, because a forwarder that relays the question
reveals what it hides.

Human notes stay out of the model's path. The glowcap MCP server gives a model
the shape only. A person may see the notes, quoted and attributed to the
object with its fingerprint, and may approve that source, after which the
notes reach the model for that fingerprint until either the shape or the
notes change.

## Steps

1. **Record the convention.** An ADR for the method, its namespace, the
   conditional form, the bounds, the forwarder rule, and the error-name
   convention, written so it can be sent upstream unchanged. Test:
   `source-check`.
2. **Servers answer.** Generated scaffolds in every language answer the
   method from the embedded description, conditionally and within the caps.
   Test: a client asks each language's Tasks server, gets the committed
   description, then asks with the fingerprint and gets "unchanged".
3. **Forwarders answer for themselves.** Every facet and caretaker helper in
   Loam and the actors layer intercepts the method. Test: a read-only share
   of a list answers three methods, and the full object's methods never
   appear through it.
4. **Clients ask.** Generated clients carry the fingerprint of the
   description they were built from, and a method-not-found refusal with a
   new fingerprint surfaces as a typed error naming the change. The command
   `glowcap interface pull` prints a live object's interface in the text
   form. Test: a client built from an older description against a newer
   server reports the change, and pull round-trips against every Tasks
   server.
5. **The agent front.** The glowcap MCP server exposes a described reference
   as tools from its shape, with no notes. Notes are shown to the person and
   pinned by fingerprint pair. Test: a reference whose notes contain
   instruction-shaped text yields tools whose descriptions contain none of
   it, and a changed note asks again.
6. **Interop proof.** A generated client calls a plain Goblins object that
   answers nothing, and a Goblins peer calls a described glowcap object
   without asking. Test: added to the external checks and recorded in the
   community review matrix.
7. **Upstream.** Send the convention to the OCapN group with the evidence
   from steps 2 to 6, record the outcome in upstream watch, and remove this
   plan and the roadmap item.

## Parallel work

Steps 1 and 2 are one lane. Steps 3, 4, and 5 run in three lanes after step
2. Step 6 waits for 3 and 4. Step 7 is a maintainer action.

## Questions for you

- Whether agent fronts ask every received reference automatically or only on
  request. The plan says on request.
- Whether to send the convention upstream before or after glowcap runs it.

## Where the code is

| Concern | Where |
| --- | --- |
| Generated scaffolds | the generators under `tools/gen/` from phase two |
| Facet and caretaker helpers | `src/loam/access/hosting/`, `src/actors/` |
| MCP server | `cli/`, the glowcap-mcp skill |
| External checks | `conformance/goblins-peer/`, `zig build check-external` |
| Community review matrix | [`docs/community-review.md`](../community-review.md) |
| Upstream watch | [`docs/upstream-watch.md`](../upstream-watch.md) |

| Steps | Gate |
| --- | --- |
| 1, 7 | `source-check` |
| 2 to 4 | `runtime-check` |
| 5 | `cli-test` |
| 6 | `check-external` |
