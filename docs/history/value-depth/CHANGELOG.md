# Value depth changes after 0.1.7

The release entry in the [root changelog](../../../CHANGELOG.md) links here
for the full changes to Zig and C calls and stored Loam values after 0.1.7.

## Breaking

- Values nest at most 64 deep on every path (`model.max_value_depth`), and
  one count decides it: a top-level argument sits at depth 0, a container's
  items one deeper, and any container at depth 64, an empty one included, is
  refused. `SessionLimits.max_nesting_depth` and the C marshal's separate
  ceiling are gone, so a Zig embedder deletes the field from its limits.
- A send to a promise past the ceiling, settled data included, is refused at
  the call instead of failing after it queues, and the Zig surface reports
  `ValueTooDeep`. Data that settles only after the send is admitted can
  still fail when it lowers, and that send's result breaks.
- A local send, a promise send, a queued admission, a settle, a Vat send, a
  Loam write, and the C marshal refuse a value past the ceiling with
  `ValueTooDeep` before admission, and the session keeps serving. A partner's
  frame past it stays `NestingTooDeep` and ends that session. Over C, such a
  value returns `GLOWCAP_ERR_INVALID_ARGUMENT` where it returned
  `GLOWCAP_ERR_UNSUPPORTED_VALUE` (or `GLOWCAP_ERR_SESSION` for a far send),
  so handle that code for depth. Zig callers of those boundaries that matched
  `NestingTooDeep`, `UnsupportedValue`, `UnsupportedArgument` or
  `MalformedView` for their own deep value match `ValueTooDeep`.
- A handler result past the ceiling that fails conversion before its turn
  commits (the C marshal and Host capability lowering) retracts the turn's
  provisional sends. A served turn that already committed keeps its effects
  and breaks only its answer with `ValueTooDeep`. Neither ends the session.
- Low-level Zig callers also change. `model.argumentIsPlainData` now
  returns `error{ValueTooDeep}!bool`, so call it with `try` or handle
  `ValueTooDeep`. Resolver `fulfill` and the settle mailbox's `post` report an
  over-deep value as `ValueTooDeep` instead of `ForeignArgument` and
  `NotPlainData`. Those errors remain for authority. The view materializers
  `toTreeDepth` and `toSliceDepth`
  take a trailing comptime `author` argument, `.local` for a value your code
  wrote (`ValueTooDeep`) or `.partner` for wire data (`MalformedView`).
  Clones and measures of owned values now report `ValueTooDeep` for depth.
- A mutation intent counts each argument from depth 0. A stored Loam value
  with a container at depth 64, an empty one included, no longer decodes, and
  a write refuses it. An author whose records hold such a value rewrites each
  one so every container sits at depth 63 or less.
