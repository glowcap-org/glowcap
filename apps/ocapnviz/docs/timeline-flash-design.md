# Timeline authoring

The shipped lane model and authoring verbs are below. Flash is the
taste target, not a dependency.

The lane model and the authoring verbs turn "I can edit one event" into "I can
author a three-vat handoff from scratch." The core has shipped. Per-entity rows,
category collapse, row reorder, and per-row visibility live in `src/ui/Timeline/`
(`rowOrder`, `rowHidden`, `rowLabelHidden`, `rowBodyHidden` on the document).
Multi-select lives in `src/interactions/`. Snap uses the Scrubber's drag path.
Copy, paste, and duplicate live in `src/engine/schema/clipboard.ts` and
`paste.ts` behind Cmd-C, Cmd-V, and Cmd-D.

Flash's stage-and-timeline pairing is the direct-manipulation authoring
experience this is reaching for.

## The lane model

One row per entity is the default. The three categories, `peers`, `sessions`,
and `messages`, stay as the top-level grouping, and each can be collapsed back
to a single stacked row on demand.

```
peers       ▾
  alice    [════════════════════]
  bob              [══════]
  carol      [════════════════════════════════]
sessions    ▾
  alice→bob              [══════════════]
  alice→carol      [════════════]
  carol→bob        [══════════════════════]
messages    ▾
  msg-1                          [══]
  msg-2                          [══]
```

Click a category chevron and it folds:

```
peers       ▸  [════════════════════════════════════]  (stacked)
sessions    ▾
  alice→bob              [══════════════]
  alice→carol      [════════════]
  carol→bob        [══════════════════════]
messages    ▸  [≡ 47 events]
```

Category lanes alone cannot manipulate one entity, and Alice's and Bob's spans
occlude each other on the same row once a scenario has more than a handful of
peers. Per-entity rows alone lose the dense overview that answers what shape the
whole scenario has. So each category expands or collapses on its own, with one
row per entity as the default.

Collapsed rows paint with the existing lane drawing, sticky labels, cluster
collapse, zebra striping and all. Expanded rows use the same span vocabulary
without the cross-entity stacking, one horizontal track each, and each row is
its own label-flow context so labels never interact across rows.

Rows default to the order the entities first appear, and can be reordered by
dragging the handle at the left of a row header. Each row also carries an
eyeball that hides it, collapsing the row to a thin strip rather than removing
it, so it stays discoverable and can be clicked back open.

Row order and visibility round-trip through the document, because manual
ordering and "these are the rows that matter" are authoring decisions and should
survive a save. Both fields are optional and additive, so a document without
them renders exactly as before.

Timeline visibility is a timeline concern only. Hiding Bob's row hides the row;
Bob still draws on the stage. The stage has its own per-layer visibility, and
per-entity stage hiding is a separate feature.

## The verbs

All of them work in both expanded and collapsed lanes, and the modifiers match
Adobe, Figma, and Flash.

**Multi-select.** Rubber-band from empty timeline area, shift-click or cmd-click
to toggle one pill, Cmd-A for everything in the visible window, Escape to clear.
Selection is entity-keyed, and clicking a pill selects its parent entity.

With more than one entity selected the Inspector switches to a summary that is
homogeneous-or-locked, the Figma and Sketch convention. A field whose value is
the same across the selection stays editable, and committing it applies to every
selected entity in one transaction, so it is one undo step. A field whose values
differ shows "Mixed" and cannot be edited there. A selection spanning kinds has
no common schema, so it shows only the one field that always makes sense: a
relative time shift.

**Snap.** Dragging is freeform by default. Holding Shift snaps to the nearest
major tick on the ruler's existing grid, and draws a thin accent line at the
snap target. It applies the same way to a single drag, a multi-drag, and the
arrival handle.

**Copy, paste, duplicate.** Cmd-C copies the selection into an engine-side
clipboard, Cmd-V pastes it with the earliest event anchored at the playhead and
the relative spacing preserved, and Cmd-D duplicates in place with a small
offset. Pasted entities become the new selection, and the clipboard lives on the
engine so undo can rewind past a paste. The clipboard is per engine instance, so
copying between documents is not supported.

**Bulk delete and bulk drag.** Delete removes everything selected as one
transaction and one undo step; a cascade that already removed something makes
the second delete a no-op, and the transaction still collapses cleanly. Dragging
any pill in the selection translates all of them together, preserving spacing,
and the whole drag clamps at the first boundary rather than letting one item
silently drop.

## What the timeline does not do

**It does not create entities.** An entity has both a place on the stage and a
place in time, and only the stage can supply the first. So creation lives in the
stage's tool palette, where the click supplies the position and the playhead
supplies the time. That is insert-at-playhead with the position baked in, and
paste covers "the same thing again, later." Adding a state-change event from the
timeline would be a different feature on its own merits, but creating entities
there is not planned.

Deferred, and worth having later: onion-skinning the stage, tweening between
keyframes, named markers on the ruler, looping regions, and per-row color
overrides.

## Timeline and stage stay in step

The two are views of the same document, coupled through the playhead for any
gesture that creates something now. Drag the playhead to 2.0s, click Add Peer,
and the new peer's lifespan starts at 2.0s on both surfaces. Every verb here
dispatches through engine intents that read or set time against the same clock
and document, so there is no timeline-only path that bypasses the engine.

## What new verbs must preserve

The timeline already holds these, and a verb whose obvious implementation would
break one needs a different implementation or a smaller scope.

- **Repaint bails when nothing changed.** Every repaint compares against the
  last frame's inputs and returns early. Row identity, expansion state, and the
  selection set belong in that comparison, and the bail must stay effective
  while paused with no hover.
- **No per-frame allocation.** Scratch and hit areas are hoisted. The selection
  set is cleared and refilled rather than recreated, and the rubber-band
  rectangle is a hoisted object.
- **Lane bundles stay memoized**, per-entity bundles included, on a key that
  covers the theme and the expansion state.
- **Click and drag stay four pixels apart**, the same threshold peer dragging
  uses, and snapping uses the existing pixel-tolerance constant rather than a
  new one.
- **A burst is one transaction.** A multi-drag opens a transaction when it
  crosses the threshold, dispatches per pointer move, and closes on pointer up.
  The handler captured at commit survives mid-drag prop changes.
- **Selection halos are a fill and stroke on the existing span**, not an extra
  graphics child per selected event.
