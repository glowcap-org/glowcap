# ADR-0091: Reserved Position Bands

**Status:** Accepted, implemented. Both sums ship in `model/position.zig`:
`ImportName` over `RedeemedToken`, and `AnswerName` over `VirtualAnswer`, each
with `classify` as the one seam. The refusal seams in `session/validate.zig`
and `session/v1_0.zig` switch exhaustively, the virtual-answer mint returns
the typed arm and crosses back through the named `answerPosition` seat, and
`test/model/model_test.zig` pins both band boundaries at classify.
**Date:** 2026-07-29 (accepted 2026-08-02)
**Decision:** An import position is one of two things, and it should say so.
Either the partner named it on the wire, or this node minted it above
`REDEEMED_TOKEN_BASE` as a handoff token. That is a sum, not two types living
beside each other, so the fix is to name the sum and classify once at the one
seam where an integer becomes a name. The same holds for the answer space and
its engine-synthesized band.

---

## What changed, and why this ADR was rewritten

This ADR was first written proposing a distinct type per band: a
`RedeemedToken` beside an `ImportPosition`, minted through a checked
constructor. It was then rejected on cost, because the problem it described had
partly closed another way. The import band gained a single discriminator
(`Node.tokenIdOf` over `Node.isTokenId`) and the host verbs that compared
against the base themselves were routed through it, while the answer band never
had the problem at all: a virtual answer is minted in one place and refused in
one place.

Writing the design out as running code changed the conclusion. A type per band
is not the strongest shape available, and the rejection was therefore aimed at
the wrong target. Three shapes, in ascending order:

**As it stands.** One discriminator, correct, and nothing compels a consumer to
consult it. This compiles and is silently wrong for a token:

```zig
fn routeForgetful(p: ImportPosition) []const u8 {
    return "this session";
}
```

**A type per band**, the first proposal. Better, because a token can no longer
be passed where a wire position is wanted. But the classifying question moves
into the constructor, a caller still begins with a `u64` and chooses which
constructor to call, and nothing is exhaustive. The compiler still never asks
whether the other kind was considered.

**The sum.** A token is not a second type standing beside an import position.
It is the other arm of what an import position can be:

```zig
const ImportName = union(enum) {
    wire: WirePosition,
    token: RedeemedToken,

    /// The single seam. An integer becomes a name here or nowhere.
    fn classify(v: u64) ImportName {
        return if (v >= REDEEMED_TOKEN_BASE)
            .{ .token = @enumFromInt(v) }
        else
            .{ .wire = @enumFromInt(v) };
    }
};
```

Three things follow that the per-band types do not give. `routeForgetful`
becomes unwritable, because routing takes an `ImportName` and the only way to
hold one is to have classified. Every consumer switches exhaustively, so the
compiler asks the question at each site rather than trusting each author to.
And a third band, if one is ever carved, turns every consumer into a compile
error instead of a silent fallthrough.

This is the [namespace rule](../../../.agents/rules/architecture.md) one level
up. That rule says a name should carry its own dimensions; this says a space
with two kinds of name should carry the distinction in its type rather than in
each reader's memory.

## Problem

The three position spaces are already types. `model.ExportPosition`,
`ImportPosition`, and `AnswerPosition` are `enum(u64)` newtypes with `from`
and `int` as the only seams where a wire integer becomes a typed position, so
passing one where another is meant does not compile. That work is done, and
this ADR does not revisit it.

What remains arithmetic is *inside* two of those spaces. pancake mints values
of its own in bands a partner is refused:

- **`REDEEMED_TOKEN_BASE` (2^60), in the import space.** `engine.Node` hands
  out node-unique tokens above it for capabilities reached through a redeemed
  handoff (ADR-0069), and discriminates one by comparison:
  `if (id >= REDEEMED_TOKEN_BASE) id else null` (`engine/node.zig`).
- **`VIRTUAL_INBOUND_ANSWER_BASE` (2^63), in the answer space.** The engine
  synthesizes answers above it for the OCapN V1.0 resolver-callback
  translation (ADR-0010).

Both bands fail closed against a partner today: `session/validate.zig` refuses
an introduced import at or above the token base and an inbound answer at or
above the virtual base, and `test/session/session_test.zig` pins both refusals
with accept-just-below companions. So this is not a live defect. It is a
guarantee carried by every call site remembering to compare, in a codebase
whose architecture rule says a name that indexes a table should carry its own
dimensions.

The cost shows up as a question a reader cannot answer locally: given an
`ImportPosition` in hand, is it a wire position the partner named or a token
this node minted? The type says only "import position." Today the answer is a
comparison somewhere up the call stack, and the [namespace
rule](../../../.agents/rules/architecture.md) exists because that shape is the
costliest bug class this core has had.

## Decision

Name the sum, and classify once.

```text
model.WirePosition       an import position the partner named
engine.RedeemedToken     an import id this node minted (ADR-0069)
model.ImportName         the union of those two, with `classify` as its
                         one constructor from a wire integer

model.AnswerPosition     an answer position the partner named
session.VirtualAnswer    an answer the engine synthesized (ADR-0010)
model.AnswerName         the same shape for the answer space
```

`classify` is the only place a `u64` becomes a name, so it is the only place
the band boundary appears. Routing, lowering, and the foreign-import and
redeemed tables take the arm they mean, and the maps key on the arm rather
than on a bare integer. Encode still needs a wire integer, so each arm keeps a
named conversion, and those conversions are greppable in a way `int()` on a
shared type is not.

The validators in `session/validate.zig` keep their refusals. A type that makes
the mistake unrepresentable in pancake's own code does not make it
unrepresentable in a partner's bytes.

## Scope (what this does not decide)

The three position-space types are not revisited; they are already correct.
Nothing here changes the wire: the bands are pancake-internal numbering and no
frame's bytes move. The `gc` bulk position vectors stay `[]const u64` for the
reason `model/position.zig` already gives.

## Alternatives Considered

- **Leave it as comparisons.** Defensible: it fails closed, it is tested, and
  no defect has come from it. Rejected as the *long-term* shape because the
  guarantee is re-established at each call site rather than held once, which
  is the pattern the namespace rule was written after several incidents.
- **One `PositionKind` tag field beside the integer.** Rejected: a tag that
  can be set wrong is the same class of bug with more ceremony, and it costs a
  word in types the footprint budgets watch.
- **Assert on construction instead of typing.** Rejected: an assert compiles
  out in ReleaseFast, which is the build a consumer ships — the same reason
  `Server.close` returns `SessionsStillOpen` rather than asserting.

## Consequences

- The work is a migration, not a local edit, and it reaches past Zig.
  `REDEEMED_TOKEN_BASE` is published across the C ABI as
  `PANCAKE_REDEEMED_TOKEN_BASE` and mirrored into every binding's generated
  constants, so a C or Python consumer still compares against a bare integer
  whatever Zig does. Typing the Zig side is still worth it — pancake's own
  code is where the mistake would be made — but the ADR should not claim the
  comparison disappears everywhere. Sizing, at the time of writing: about
  twenty-five token-keyed sites in `engine/node.zig`, four in `session`, and
  fifteen published-constant mirrors under `bindings/` and `include/`.
- The consolidation is already done, and it is not what this buys.
  `Node.tokenIdOf` over `Node.isTokenId` is the only place a reserved id is
  recognized, and the host verbs above call it rather than re-comparing. What
  the sum adds is that consulting it stops being optional: a consumer cannot
  hold a routable name without having classified, and the switch is exhaustive.
  That is a different thing from tidiness, and it is why the earlier rejection
  of this ADR was aimed at the wrong design.
- The migration is smaller than the per-band version it replaces. There is one
  classify seam rather than a constructor call at every site that mints, so the
  edit is concentrated where integers arrive (`Node.route`, `routeToken`,
  `Host.gcRelease`, the foreign-import and redeemed maps) instead of spread
  across every caller that happens to hold an id.
- Touches every site comparing against either base, plus
  `model/position.zig`'s `reinterpret`, which is the deliberate cross-space
  re-tag (`engine/pipeline.zig` uses it four times to read a near export
  position as an answer or import position). `reinterpret` is the hard case:
  it must keep working for the genuine re-tags while not becoming the hole
  through which a token re-enters wire space. Implementation settled it the
  second way: `reinterpret` stays on the three wire-space types, and each band
  arm carries its own named conversion (`RedeemedToken.wirePosition`,
  `VirtualAnswer.answerPosition`), so the sites where a band value crosses
  back into wire space are greppable one by one.
- The mint counters and routing-table keys stay raw `u64` inside their owning
  modules (`Node.next_token`, the `redeemed`/`foreign_imports` maps,
  `Session.next_virtual_inbound_answer`). The sum's job is the consumer seam,
  where an integer of unknown provenance becomes a name; the mint *is* the
  provenance, and typing its private counter would re-spell the same fact with
  no reader protected.
- The refusals in `session/validate.zig` stay, with their tests. A type that
  makes the mistake unrepresentable in pancake's own code does not make it
  unrepresentable in a partner's bytes.
- No behavior changes, so the existing suite is the regression proof; the new
  evidence is that the old comparison sites no longer compile without a
  conversion.
