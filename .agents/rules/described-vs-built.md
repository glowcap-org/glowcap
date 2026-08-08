---
description: "A comment in src/ that describes a mechanism is read as a mechanism that exists; write the indicative only for what the code does, and grep for callers before relying on one."
alwaysApply: true
---

# pancake — Described Is Not Built

A comment in `src/` that describes a mechanism is read as documentation of a
mechanism that exists. Nothing in the language or the gate can tell the two
apart, so the discipline is the only thing that does.

This rule exists because the most expensive defect in this repository's history
was not a bug. `engine.negotiation.negotiate` was correct from the initial
commit and unreachable from any connection for months. Its module header said a
netlayer adapter learns the partner's offer "from a locator hint" and runs the
same function. No adapter did. No hint existed. The sentence was a design note
in the present tense, and every reader after it — including the ones who
extended the file — took it for a description of working code. The same
sentence, and the same gap, had already crossed from the Rust implementation
into the Zig one.

Nothing caught it. The tests passed, because they tested the part that was
built. The gate was green, because a green gate means the code does what the
code does.

## The rule

**Write comments in the indicative only for what the code in front of you
does.** A mechanism that lives somewhere else is named with the symbol that
implements it, so a reader can go look and a rename breaks the claim:

> What each end knows of the other is one `model.Preference`, which the hello
> states in its locator hints and `session.Session.partner_preference` records.

not:

> a netlayer adapter that learns the partner's offer (for example from a
> locator hint) runs the same function.

The first names a caller and a field. The second names a hypothetical.

**An intended mechanism is written as intent, where intent is recorded.** An ADR
under `docs/decisions/adr/` argues a decision and says plainly what is not
implemented, in its Scope section, which is the section that exists for exactly
this. A `// TODO:` in the code is weaker but honest. A present-tense sentence in
a module header is neither.

**A public function with no caller outside its own tests is a claim under
construction.** That is the shape this failure takes every time: the algorithm
lands, the seam that would reach it does not, and the header describes the
finished design. When you write one, say so at the declaration, in a sentence
that would be embarrassing to leave once it is wired:

> Nothing on a connection calls this yet; `engine.pairing` is the only caller,
> and it has both offers in one process.

**When you wire it, the sentence goes.** Deleting that line is how the claim
becomes true, and it costs one line of diff at exactly the moment someone is
looking.

## Reading the tree

The corollary is for the reader rather than the writer, and it is the half that
would have saved the months: **a mechanism you are relying on, believe exists,
and have not seen called is worth one grep.** Not a review, not an audit. One
`grep -rn 'theFunction(' src/`, and read who calls it. If the callers are all
tests and one in-process helper, the mechanism is a library, not a feature, and
whatever you were about to build on top of it has no floor under it.

This is cheap enough to do on suspicion and it is the only check that catches
this class, because the class is precisely the one where everything compiles,
every test passes, and every document agrees.
