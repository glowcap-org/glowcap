---
description: "Documentation voice for Zig glowcap: first-read docs, doc comments, and example narration read as speech, not notation."
globs: **/*.md, site/content/**, apps/**/*.ts, apps/**/*.tsx, examples/**
paths:
  - "**/*.md"
  - "site/content/**"
  - "apps/**/*.ts"
  - "apps/**/*.tsx"
  - "examples/**"
---

# glowcap — Documentation Voice

Human docs explain the system to a person; agent scaffolding instructs an
executor. Keep the voices apart. [Doc-drift](doc-drift.md) keeps claims true;
this rule keeps them readable aloud.

**Human surfaces:** `README.md`, top-level `docs/*.md`,
`docs/protocol-diagrams/**`, all of `site/content/**` and `examples/**`,
binding, app, and UI READMEs, user-facing app copy and transport
`ProfileInfo.summary` strings, interop and bench narration, test-module `//!`
headers, public `//!`/`///` docs, and `cli/`. **Agent surfaces:** `.agents/**`,
`AGENTS.md`, `CLAUDE.md`. ADRs stay precise memos; planning docs declare their
own role. Inline comments in function bodies are exempt. A touched human
surface meets this rule; unfinished voice is unfinished work.

## A reader's path

- Lead with why the reader opened the page and what they can do there. Put the
  ordinary path first; on a public first-read that is the sealed,
  identity-aware path or a complete program, never the cleartext test adapter.
- Introduce a term in plain words before leaning on it. Name a heading after
  its subject; contrast belongs in the paragraph after.
- One document owns each status claim; others link to it. Maintainer mechanics
  stay out of consumer landings, and `.agents/` links stay off product
  first-read pages.
- A landing discloses AI assistance and who answers for the work, per
  `PROVENANCE.md`. No AI-project framing, line-audit claim, or destination
  slogan. Live humans stay out of docs except copyright lines; use generic nicks.
- Speak of Goblins, OCapN, E, iroh, Zig, Syrup, and Cap'n Proto with respect.
  Let a chart carry any ordering, and link an external project at its first
  apt mention.

## Narrative

A page says what is true and what to do. Cut how something came to be,
progress told as prose, an argument for a choice whose reason is already
given, a fact said twice, and sentences about the page itself. Status belongs
to `docs/shipped.md`, a plan, or an ADR, and history belongs to git. Keep a
story only when the reader needs it to understand, such as a worked example.
If a sentence might be narrative, cut it and reread: keep it only if the page
no longer makes sense without it.

## Sentences

- Full sentences with a subject and verb, one idea each. Code spans are nouns
  the sentence uses, never replacements for it. Put the reason in words before
  citing an ADR.
- Keep small topics small.
- Say what a thing is. One contrast where the distinction is load-bearing,
  never a passage built from denials.
- No self-praise ("honest", "elegant", "boring on purpose"). State the fact.
- Plain words over costly ones (use, before, signed claim), American spelling,
  and `form`/`encoding`/`name` rather than "spelling" outside orthography.
- No connective arrows outside a diagram, no telegraphic fragments, no bare
  citation dumps, no `⇒`/`iff`/`s.t.`, and no square brackets around a code
  span without a link target (rustdoc syntax, kept only in `bindings/rust`).
- Human prose uses no em dashes and no semicolons, on reader and contributor
  pages alike. Split the thought into two sentences, or use a comma, colon, or
  parentheses. Both read as generated text on a page a person meant to write.
  Agent prose keeps the em dash rare too, because agents copy scaffolding
  style into reader-facing copy.
- Write it the way a person explains something to a capable friend. Prefer
  the everyday word ("so" over "therefore", "to" over "in order to", "use"
  over "utilize"). Keep a technical term when the reader needs it, and say
  what it means the first time.

`source-check` enforces the mechanical tells (`checkHumanDocVoice`,
`banHabitualEmDash`, `banHabitualJustification`, `checkProseSentenceLength`).
Fix the prose; never weaken the check. Retire a row in
`tools/check/source_check/docs/voice_debt.zig` when you clear a listed file.

## Insider words

The names we use while building glowcap are not the reader's. A page for
people using glowcap or Rooms says what they would call the thing: the
sidebar, not the rail; a Rust library, not the sidecar; storage, not custody;
a build check, not a gate; reference fixtures, not the oracle. The same goes
for internal state names (intent, journal, front, pane) and for UI copy a
screen reader speaks. Refer to an on-screen label by its exact text in bold.
Keep real identifiers (`zig build oracle-check`) in code spans and gloss them
once. Describe inbound frames as untrusted, peer-supplied, or malformed.
Contributor pages may use the working words. `insider_words` in
`source_check/docs/reader_voice.zig` holds the ones that are never the
reader's, and `source-check` holds the reader pages and the Rooms text
catalog (`apps/rooms/lib/text/`) to that list and to the punctuation rule.
The [reader-voice skill](../skills/reader-voice/SKILL.md) is the procedure
for writing or sweeping those pages.
