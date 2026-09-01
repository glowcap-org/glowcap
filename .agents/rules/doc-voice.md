---
description: "Documentation voice for Zig pancake: first-read docs, doc comments, and example narration read as speech, not notation."
globs: **/*.md, src/**/*.zig, apps/**/*.ts, apps/**/*.tsx, examples/**, test/**/*.zig, interop/**/*.zig, bench/**/*.zig, conformance/**/*.zig
---

# pancake — Documentation Voice

## Audience Split

Human docs explain the system to a person. Agent scaffolding instructs an executor. Do not mix the two voices.

| Audience | Surfaces                                                                                                                                                                                                                                                                                                                                                                                                    |
| -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Humans   | `README.md`, top-level `docs/*.md`, `docs/protocol-diagrams/**`, **all** authored `site/content/**`, binding, app, and example READMEs (`apps/**/README.md`, `ui/README.md`), user-facing app copy under `apps/**`, the profile summaries a transport package ships for its own listeners (`bindings/*/…` `ProfileInfo.summary`), which cross the wire and are drawn to a reader, **all** of `examples/**` (chapters, apps, demos), interop and bench driver narration, test module `//!` headers, Zig `//!` / `///` on public APIs and `cli/`, `.devcontainer/README.md` |
| Agents   | `.agents/**`, plus root `AGENTS.md` / `CLAUDE.md` as agent entry points                                                                                                                                                                                                                                                                                                                                     |

CapTP vocabulary cheat-sheets (symbol maps, “sticky note” dumps) live in the [architecture rule](architecture.md), not
in human living-state pages. Human pages name the product in sentences a newcomer can follow, then link an ADR when a
decision needs a record. `zig build source-check` bans the literal `CapTP sticky note` label on human first-read paths.

ADRs under `docs/decisions/adr/**` stay precise memos. Planning docs under `docs/planning/**` declare their own role.
Ordinary inline comments inside function bodies are not bound by this rule, even in app source. User-facing strings and
rendered prose are. Module `//!` headers on examples, apps, interop drivers, benches, and tests are bound: they are how
a human finds the scenario. Keep them speech-readable.

**Live humans stay out of docs.** Do not put a living person's personal name into human docs or READMEs; use generic
example nicks. Copyright attribution lines are fine.

**Completion bar.** Every human surface above must meet this rule (or better). Unfinished voice on a touched surface is
unfinished work, not taste. On product first-read paths, `zig build source-check` (`checkHumanDocVoice`) bans
high-signal regressions: the `CapTP sticky note` label, agent-scaffold needles (`Meta
scaffolding`, `next audit`, `visible boundary`,
`listen-oriented`), contrast-first openers (`This page is not`), headings that spend contrast before the subject has a
name (`The relay is a pipe, not a peer name`), self-praise (`deliberately boring` / `boring on purpose`), connective
`→`/`⇒` outside fenced code, and `.agents/` links on product first-read pages (`CONTRIBUTING.md` and
`.devcontainer/README.md` may still route contributors to executor rules).

## What This Rule Governs

Docs are one person explaining the system to another. Write them as that conversation. A reader should be able to follow
the prose out loud and have it sound like speech, not like a notation they have to decode first.

This rule is about how prose _reads_. Whether a state claim is _true_ is [doc-drift](doc-drift.md)'s job. The two run
together: a doc has to be both honest and readable.

## Build a reader's path

A first-read page answers one question for one reader, then points to the next useful level of detail.

- Lead with why the reader opened the page and what they can do there.
- Introduce a project term in plain language before using it as shorthand.
- Put the ordinary path before alternatives, internals, and exceptions. On a public first-read, that path is sealed and
  identity-aware, or a complete program, not the testing adapter. A disclaimer that the lead is cleartext means the lead
  is wrong ([first-impression](../personas/first-impression.md)).
- Name a heading after its subject. Contrast (`X, not Y`) is a tool, not the default title: if the distinction is
  load-bearing, put it in the paragraph after the subject has a name. `zig build source-check` refuses the title form on
  first-read pages.
- A landing discloses AI assistance and who is answerable for the work. It does not describe pancake as an AI-written
  project, claim a personal audit of every line, or announce the destination as a slogan. `PROVENANCE.md` owns the
  policy detail.
- Move maintainer mechanics and release procedure out of consumer landing pages.
- Let one document own each status claim. Other pages link to it instead of retelling it.
- Use a table when the reader is comparing choices. Use prose when one idea depends on the previous one.

Every paragraph should earn the next. A correct detail in the wrong place is still a documentation defect.

## Neighbors And Citations

- The projects pancake stands on — Spritely Goblins, OCapN, E, iroh, Zig, Syrup, Cap'n Proto — are spoken of only with
  respect. State pancake's own measurements plainly and let a chart carry any ordering; prose never ranks a neighbor
  downward.
- Cite an external project with a link at its first or most appropriate mention on a page, and leave later mentions on
  that page as plain text.

## Write Like This

- Use full sentences with a subject and a verb. If a line cannot be read aloud as speech, it is not finished.
- Keep one idea per sentence. When three clauses have stacked up behind em-dashes, split them into separate sentences.
- Introduce a name before you lean on it. "The session owns the answer table" reads like speech; "answer-table
  authority: session" does not.
- Let code references and links support the sentence instead of replacing it. A symbol in backticks is still a noun the
  sentence has to use: write "the engine drains outbound frames in `Peer.step`," not "outbound drain: `Peer.step`."
- Put the reason in the sentence. If a clause only makes sense once the reader opens the ADR you cited, state the reason
  in words and then cite the ADR.

## Not Like This

These are the tells that prose has drifted into a private notation, or that a good tactic (contrast, an em-dash, a
fence) is being used as the default joint so the content thins and the tactic goes moot:

- Saying it twice. The commonest drift is stating an idea, restating it in different words, then qualifying it; and
  giving a minor topic as many words as a major one. Each idea gets said once, well, and small topics stay small. A
  major topic that grew into a changelog is rewritten as the present inventory, not shortened by dropping the facts.

- The sentence that never ends. Four ideas joined by semicolons, with a stack of identifiers and a decision-record
  number wedged in, is not one sentence. A two-clause semicolon on a landing is the same tell. Split it. The median
  sentence on these pages is under a hundred characters; `zig build source-check` (`checkProseSentenceLength`) refuses
  one past 250, which is well past the point a reader has lost the thread.

- Self-awarded praise. Prose that calls the project's own arithmetic "honest," a surface "elegant," or a path "instant"
  is congratulation, not information. State the fact plainly and let the reader judge it; superlatives need a
  measurement behind them.
- A costly word where a plain one says the same thing. Reach for the everyday word unless the precise term earns its
  place: write "signed claim" rather than "attestation," "use" rather than "utilize," "before" rather than "prior to,"
  unless the exact technical sense is the point. Write American English (`behavior`, `color`, `license` as the noun,
  `toward`), not British, except in quoted spec text and LICENSE filenames. Some terms — capability, vat, sturdyref —
  are the precise word and stay. The test is whether a first-time reader gains anything from the harder word; if not,
  the plain one wins.
- Using `spelling` for a representation, identifier, variant, or repeated fact. Reserve it for orthography; write form,
  encoding, name, symbol, or declaration for the engineering concept.
- Arrows used as connective tissue in a sentence, such as "malformed frame → typed abort." Write "a malformed frame
  becomes a typed abort." An arrow is fine inside an actual flow diagram like `Frame -> Codec -> Session` when it stands
  on its own line as a diagram.
- The em-dash as a default connector. It is a strong, occasional tool, not the punctuation a sentence reaches for by
  habit, and the drift here is using it everywhere a comma or period would do. Two uses earn it: a **matched pair**
  standing in for parentheses when the aside carries its own commas (`the core —
  model, codec, session — stays sync`),
  and a **single** dash for a turn a comma cannot carry, used sparingly and never more than one per sentence. Everything
  else is overuse: "X — and then Y", "X — which is Y", a lone dash where ", " or ". " reads the same, and three facts
  strung behind dashes in one breath. The test is simple: if a comma, period, colon, or parentheses would carry the
  sentence as well, the dash has not earned its place. `zig build source-check` (`banHabitualEmDash`) rejects the two
  patterns habit reaches for most, `— which` and `— and then`, across `src/`, `cli/`, `docs/`, `site/content`, and
  `README.md`. The rest of this bullet is still yours to hold.
- The justification tic. "X, which is what lets Y" restates a causal joint the sentence already has. Write a comma
  apposition, "so", or a second sentence. `zig build source-check` (`banHabitualJustification`) refuses the phrase
  across the first-party prose trees. The `apps/` files still carrying it are listed in
  `tools/check/source_check/docs/voice_debt.zig`, a closed list going to zero on the file-length contract: rewrite a
  listed file's instances and retire its row in the same change.
- Telegraphic fragments with the verb cut out: "Bounded recursion. Depth-capped. Fails loud."
- Bare citation dumps like "(Invariant 14)" or "(ADR-0025)" dropped in with no sentence saying what they mean. Make the
  point in words first, then cite.
- Glyphs and abbreviations a first-time reader would have to be taught, such as `⇒`, `s.t.`, or `iff`.
- Square brackets wrapped around a code span with no link target after them. That is rustdoc's intra-doc link syntax;
  nothing in this repository resolves it, so it renders as literal brackets around dead text. Write the plain code span,
  or a real Markdown link with a target. `zig build source-check` rejects the form in owned Markdown and Zig comments
  (rustdoc resolves it, so `bindings/rust` keeps it).

## Insider Words

Do not write as if every reader already works in this repository. Prefer plain words in human prose; keep build-step and
path names as identifiers and gloss them once.

| Insider word      | Prefer in prose                                                    |
| ----------------- | ------------------------------------------------------------------ |
| gate / gates      | build check, check step, verification; verb: checks, covers, holds |
| hermetic          | in-tree, self-contained, no network or external services           |
| oracle (metaphor) | reference, source of truth, reference corpus / fixtures            |
| dogfood           | binding check; “exercises the C ABI as a real consumer”            |
| living-state      | docs that must match today's code                                  |
| rung              | step on the ladder (introduce the ladder metaphor first)           |

Keep identifiers unchanged when they are real names: `zig build oracle-check`, `test/oracle/`, `*-dogfood`,
`tools/check/`. Gloss them: “`zig build oracle-check` (protocol reference fixtures)” rather than “the oracle gate.”
