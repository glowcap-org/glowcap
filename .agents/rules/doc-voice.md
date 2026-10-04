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

## Sentences

- Full sentences with a subject and verb, one idea each. Code spans are nouns
  the sentence uses, never replacements for it. Put the reason in words before
  citing an ADR.
- Say each idea once; keep small topics small.
- Say what a thing is. One contrast where the distinction is load-bearing,
  never a passage built from denials.
- No self-praise ("honest", "elegant", "boring on purpose"). State the fact.
- Plain words over costly ones (use, before, signed claim), American spelling,
  and `form`/`encoding`/`name` rather than "spelling" outside orthography.
- No connective arrows outside a diagram, no telegraphic fragments, no bare
  citation dumps, no `⇒`/`iff`/`s.t.`, and no square brackets around a code
  span without a link target (rustdoc syntax, kept only in `bindings/rust`).
- The em-dash is occasional: a matched pair for an aside with its own commas,
  or one turn a comma cannot carry. If a comma, period, colon, or parentheses
  would do, use that. Agent prose is held to this too, because agents copy
  scaffolding style into reader-facing copy.

`source-check` enforces the mechanical tells (`checkHumanDocVoice`,
`banHabitualEmDash`, `banHabitualJustification`, `checkProseSentenceLength`).
Fix the prose; never weaken the check. Retire a row in
`tools/check/source_check/docs/voice_debt.zig` when you clear a listed file.

## Insider words

In human prose, prefer: "build check" over gate, "self-contained" over
hermetic, "reference fixtures" over oracle, "binding check" over dogfood, "docs
that must match today's code" over living-state, and introduce the ladder
before saying rung. Keep real identifiers (`zig build oracle-check`,
`*-dogfood`) and gloss them once. Describe inbound frames as untrusted,
peer-supplied, or malformed.
