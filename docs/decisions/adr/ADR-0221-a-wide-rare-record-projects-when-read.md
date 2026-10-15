---
id: ADR-0221
status: accepted
date: 2026-10-13
tags: [model, codec, session, performance]
decision: "A borrowed view keeps a signed handoff envelope and a sturdyref as lazy records: the codec frames the record's bytes at decode, and the consumer that reads it projects it, so the width of a rare record never sets the size of every argument."
supersedes: []
superseded_by: []
amends: []
amended_by: []
---

# ADR-0221 A wide, rare record projects when read

## Context

`model.view.Argument` is the value every inbound argument walk returns, the
value the session validator switches on, and the value the Vat copies into
its turn. Its size was 312 bytes, set by two arms: the signed handoff
envelope (304 bytes once parsed) and the sturdyref's peer locator (120 bytes
through `Reference`). A call round trip carries neither, and its profile
showed about 4,000 instructions per round trip in `memcpy` and zeroing,
most of it argument views and the bodies that embed them returned by value.

## Decision

`model.view.Lazy(Owned, View)` is a record that is parsed when it is read.
It holds either a pointer to the owned record or a codec backing: the
record's byte region in a `SequenceCtx` plus a projector, the same shape
`Args` uses for a list. `Argument.handoff` and `Reference.sturdy` are lazy
records, so `Argument` is 80 bytes and `Reference` 64, and the
`argument_view_budget_bytes` pin in `view.zig` refuses an arm that would
widen it again.

At decode, Syrup bounds the record with the structural walk every foreign
record gets, then stores the region. Cap'n Proto stores the struct location,
and its metered pass still walks the record's hint lists eagerly, so the
decode-time charge is unchanged. A malformed record is refused at
projection as `MalformedView`, the verdict a malformed list element already
gets, and the session's abort projection reports it as a malformed frame.
The session projects a sturdyref or handoff argument while validating it,
so an application never sees an unparsed record, and a session validator
that can reach a borrowed sturdyref carries `ProjectError` in its return
type (`passable.ReferenceError`). An owned reference keeps the plain
session error set.

## Alternatives Considered

- Box the two arms behind a pointer into the frame's parse region. Rejected:
  the borrowed view allocates nothing, and a decode-time parse of a record no
  consumer reads is the cost this change removes.
- Keep the arms inline and shrink the records. Rejected: the envelope's
  width is the wire format's, and a locator with hints is unbounded.
- Project at decode only when a feature flag says the session can carry the
  record. Rejected: it moves a session decision into the codec.

## Consequences

- An `inproc` call round trip spends about 2,500 fewer instructions, almost
  all of it `memcpy` and zero-initialization of argument views.
- A consumer that reads a handoff or sturdyref calls `project()` once and
  handles `MalformedView`. The Vat, the driver's host interception, the
  bootstrap request reader, the view equality and hash walks, and the
  oracle's handoff scenario do.
- The Syrup decoder's test for a malformed sturdyref or envelope expects the
  frame to decode and the projection to refuse.

## Evidence and gate

- `test/codec/syrup/decode_test.zig`: a sturdyref and a signed envelope are
  framed at decode and refused when read.
- `test/engine/peer/abort_test.zig`: a malformed sturdyref argument is
  refused at validation as a malformed frame.
- `test/model/equality_test.zig`: a borrowed handoff compares through a lazy
  backing.
- The `callgrind` recipe on the benchmarks page: 59,200 instructions per
  `inproc` round trip before, 56,700 after, on the benchmarks page's machine.
