---
name: doc-writing
description: >-
  Use when drafting a doc, tightening one, or sweeping prose for voice: any
  Markdown or site page, README, guide, plan, or agent doc. It sets the order
  of work for a new doc, the passes that make an existing one tight, and the
  reader-voice judgment that pages for glowcap users and Rooms operators need.
  Not for checking claims against code (doc-drift).
---

# Doc writing

[doc-voice](../../rules/doc-voice.md) sets the bar and
[doc-drift](../../rules/doc-drift.md) keeps claims true. `source-check` holds
the mechanical floor: no semicolon or em dash on human and shared pages, no
word in `insider_words` (`source_check/docs/reader_voice.zig`) on human pages,
sentences of <!-- value ../../../tools/check/source_check/docs/voice.zig max_prose_sentence -->250<!-- /value --> characters or fewer, and paragraphs of
<!-- value ../../../tools/check/source_check/docs/paragraphs.zig max_paragraph_sentences -->6<!-- /value --> sentences or fewer. A green check is the floor. This procedure covers
the judgment the check cannot make.

## Draft

1. Decide the kind, audience, and sources ([doc-drift](../../rules/doc-drift.md)).
   If another doc owns the subject, edit or link that doc instead.
2. List the questions the reader arrives with, in the order they ask them.
   Each becomes a heading. Drop any that the code or another doc answers.
3. Under each heading, give the answer first, then only what the reader needs
   to act on it.
4. Tighten the draft before anyone else reads it.

## Tighten

Read the doc as its reader would, one section at a time.

1. **Purpose.** The opening says what the doc is for and what the reader can
   do with it. A sentence about the page itself goes.
2. **Every sentence earns its place.** Ask whether the reader would miss it.
   Usual cuts are a restated heading, a repeated fact, a reason already
   given, a denial of something nobody assumed, and history.
3. **Structure carries order.** A paragraph that walks steps becomes a
   numbered list. Rules a caller must follow become a bulleted list. Rows of
   similar facts become a table, and a paragraph with two ideas becomes two.
   A list earns its place by showing order or cutting words: one bullet per
   sentence of the old paragraph is the same paragraph, harder to read.
4. **One owner per fact.** A function-by-function walk copies what doc
   comments own. Keep the model and the rules that span calls, and link the
   source. If a fact lives only in the doc, move it into the doc comment
   first.
5. **Words.** Turn noun stacks into verbs, and replace our labels with what
   the reader calls the thing ([Reader voice](#reader-voice)).
6. **Truth.** Check every reworded claim against its source. Plain and wrong
   is worse than stiff and right.

Keep value markers, generated blocks, links, and OKF headers intact. Report
the word count before and after. A tightened doc that came out longer needs
a reason, such as a fact it was missing.

## Reader voice

Pages for people using glowcap or running Rooms get one more pass. Most
insider talk is an ordinary word used our way, so scan wider than the word
list. Look for:

- names we give parts of the UI or system (rail, pane, front, sidecar)
- internal state and process words (intent, custody, journal, evidence,
  matrix, ladder, gate, boundary used as a noun)
- spec voice: a noun stack where a person would use a verb ("submitted
  storage execution")
- strings a screen reader speaks, which count as prose (`aria-label` text and
  the `...Said` helpers in `apps/rooms/lib/text/`)
- comparisons that claim something is new

Classify each hit:

- **The reader's word.** OCapN, CapTP, and library terms the reader has to
  learn (vat, sturdyref, settle, seat, durable). Keep it, and say what it
  means the first time.
- **An on-screen label.** Use its exact text in bold. Read the label from
  `apps/rooms/lib/text/`, not from memory or a component name.
- **Ours.** Replace it with what the reader would call the thing. If the
  plain version is unclear, read the code to learn what the thing does, then
  say that.

Then rewrite:

- Split a semicolon into two sentences, and read every split.
- A list of fragments drops its end punctuation. A list of full sentences
  gets capitals. A table cell that loses its subject gets one back.
- A comparison names the familiar precedent first, then the difference. If
  nothing differs, leave the claim out.
- Shared pages (`CONTRIBUTING.md`, `ui/README.md`, ADRs, `docs/`,
  `bindings/proofs/`) may keep working words. `contributor_scopes` in
  `voice.zig` still holds them to the punctuation rule.

## Hold it

- A page's audience follows from where it lives (`classify` in `kinds.zig`).
  An app's or package's front page is human from its first commit. Any other
  human guide says `audience: human` in its header.
- Fix a generated block at its source, then run its `gen-*` step.
- Add a word to `insider_words` only if no reader page could ever need it.
- Plant a defect in a scratch copy to prove a new check catches it, then
  restore and `cmp` the file. Use `command cp -f`: an interactive `cp` alias
  skips the restore silently.
- Gates: `source-check`, plus `site site-render-check` for site pages,
  `gen-site-examples-check` for snippets, and `rooms-server-test` when Rooms
  text changes.
