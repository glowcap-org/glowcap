---
description: "Documentation voice for Zig pancake: first-read docs, doc comments, and example narration read as speech, not notation."
globs: **/*.md, src/**/*.zig, examples/**
---

# pancake — Documentation Voice

Docs are one person explaining the system to another. Write them as that
conversation. A reader should be able to follow the prose out loud and have it
sound like speech, not like a notation they have to decode first.

This rule is about how prose *reads*. Whether a state claim is *true* is
[doc-drift](doc-drift.md)'s job. The two run together: a doc has to be both honest
and readable.

## Where This Applies

The human-first surfaces, the ones someone reads to understand the system:

- `README.md`, `docs/vision.md`, `docs/architecture.md`, and other first-read docs;
- `docs/protocol-diagrams/**`;
- the `//!` file headers and the `///` doc comments on exported Zig declarations;
- the narration in `examples/**`.

Deliberately *not* bound by this rule, because they are terse-by-design records
rather than dialog:

- ADRs under `docs/decisions/adr/**`, which read like a precise memo;
- `docs/planning/**`, which declare their own role and read like plan records;
- the `.agents/**` rule and skill files, which are short agent-facing instructions;
- ordinary inline comments inside function bodies.

## Write Like This

- Use full sentences with a subject and a verb. If a line cannot be read aloud as
  speech, it is not finished.
- Keep one idea per sentence. When three clauses have stacked up behind em-dashes,
  split them into separate sentences.
- Introduce a name before you lean on it. "The session owns the answer table"
  reads like speech; "answer-table authority: session" does not.
- Let code references and links support the sentence instead of replacing it. A
  symbol in backticks is still a noun the sentence has to use: write "the engine
  drains outbound frames in `Peer.step`," not "outbound drain: `Peer.step`."
- Put the reason in the sentence. If a clause only makes sense once the reader
  opens the ADR you cited, state the reason in words and then cite the ADR.

## Not Like This

These are the tells that prose has drifted into a private notation:

- Self-awarded praise. Prose that calls the project's own arithmetic "honest,"
  a surface "elegant," or a path "instant" is congratulation, not information.
  State the fact plainly and let the reader judge it; superlatives need a
  measurement behind them.
- A costly word where a plain one says the same thing. Reach for the everyday
  word unless the precise term earns its place: write "signed claim" rather than
  "attestation," "use" rather than "utilize," "before" rather than "prior to,"
  unless the exact technical sense is the point. Some terms — capability, vat,
  sturdyref — are the precise word and stay. The test is whether a first-time
  reader gains anything from the harder word; if not, the plain one wins.
- Arrows used as connective tissue in a sentence, such as "malformed frame → typed
  abort." Write "a malformed frame becomes a typed abort." An arrow is fine inside
  an actual flow diagram like `Frame -> Codec -> Session` when it stands on its own
  line as a diagram.
- Em-dash pile-ups that pack three facts into one breath.
- Telegraphic fragments with the verb cut out: "Bounded recursion. Depth-capped.
  Fails loud."
- Bare citation dumps like "(Invariant 14)" or "(ADR-0025)" dropped in with no
  sentence saying what they mean. Make the point in words first, then cite.
- Glyphs and abbreviations a first-time reader would have to be taught, such as
  `⇒`, `s.t.`, or `iff`.
- Square brackets wrapped around a code span with no link target after them.
  That is rustdoc's intra-doc link syntax; nothing in this repository resolves
  it, so it renders as literal brackets around dead text. Write the plain code
  span, or a real Markdown link with a target. `zig build meta-check` rejects
  the form in owned Markdown and Zig comments (rustdoc resolves it, so
  `bindings/rust` keeps it).

## When You Touch A Doc

Read the surrounding lines first, and match a voice that already reads like speech.
If the file you are editing is itself written in the shorthand above, fix the lines
you touch instead of matching the drift, and leave the file a little more readable
than you found it.
