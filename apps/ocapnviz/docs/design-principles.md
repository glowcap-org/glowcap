---
type: static
description: The visual vocabulary and interaction rules for changing the ocapnviz interface, with the one place each rule lives.
sources:
  - resource: /apps/ocapnviz/src/ui/
  - resource: /apps/ocapnviz/src/interactions/
  - resource: /apps/ocapnviz/src/state/
  - resource: /apps/ocapnviz/src/controls.css
---

# ocapnviz: Design Principles

When you change the interface, make each gesture work the same on every
surface and put each rule in one place in the code.

## Visual vocabulary

ocapnviz fits a large amount of protocol state on screen. It gets that density
from alignment and clear levels, not by shrinking every element equally.

**Type.** The interface uses four sizes:

| Size | Use |
| --- | --- |
| 9 px | Tracked uppercase section titles, field keys, and legend captions. Never body text. |
| 10 px | Data: field values, chips, and list rows. |
| 11 px | Controls. |
| 13 px | Headings. |

Monospace is reserved for protocol tokens, times, and addresses. It renders
larger than sans text at the same size, so a monospace value normally drops one
size. The narrow Legend is the exception: both faces use 9 px so its sentences
do not wrap excessively.

**Color.** Full ink is for the primary content, muted ink for controls and
labels, and subtle ink for captions and asides. The workspace has the strongest
surface contrast, with controls framing it in nested levels. Borders are faint
on a control without its own chrome, ordinary at rest, and strong under the
pointer. Accent color marks the active control or keyboard focus. Green, amber,
and red describe protocol state, not interface chrome.

**Treatments.** Use one visual signal for each fact:

- Hover combines a background and border change.
- A dialog's affirmative action may use a solid accent fill.
- A persistent selected state uses an accent border over a pale wash.
- Keyboard focus uses an outline one pixel outside the box so variants cannot
  erase it.
- Pressing a control moves it by one pixel.
- Controls use neither elevation nor bevels.

**Components.** A button runs an action. A segmented control chooses from a
small fixed set that should remain visible, such as modes or view kinds. A
dropdown handles a longer list. Anything that accepts a caret is a field,
including a numeric value that can also be dragged. Use an icon button only for
a conventional symbol in a cluster of similar controls. Add a text label when
the symbol would make the reader guess.

## Interface copy

Use the protocol's exact terms. Define them once in the Reference, then use the
same names throughout the interface so screen text can be matched with server
output.

**Separate claims from proof.** An endpoint may claim a designator without
proving it. `src/ui/reference/endpoint-attribution.ts` owns the wording for that
difference. When attribution is unknown, say so and leave the endpoint loose.

**A failure answers three questions.** Say what happened, what it means, and
what the reader can do next. `EngineError` carries those answers as `title`,
`detail`, and `recovery`. For example: "Live capability unreachable" followed
by "Check the sturdyref and the Rooms server, then wait for reconnect."

**A tooltip names the control, then explains it.** Use a colon between the two
parts: "Save (Cmd/Ctrl+S): download this timeline as a JSON file" or "Open
session: click the first node." Use a period between independent sentences.

**Do not make labels cryptic to save space.** The Scrubber hint spends a full
line on six gestures because each must be discoverable where it is used.

## The idiom index

Before adding UI or interaction behavior, find the idiom it belongs to. Each row
names one authority. A change that cannot use the authority extends it in place.

| Concern                                              | One authority                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Selection modifier grammar                           | `SelectMode` + `selectModeFromModifiers`, `src/interactions/types.ts`                                                                                                                                                                                                                                                                                                                                                              |
| What a select mode does to the selection             | `selectionActionFor`, `src/interactions/selection-store.ts`                                                                                                                                                                                                                                                                                                                                                                        |
| Keyboard shortcuts                                   | the `SHORTCUTS` table, `src/state/keyboard-shortcuts.ts`                                                                                                                                                                                                                                                                                                                                                                           |
| Whether a press is a shortcut or a gesture           | `resolveKeyDown`, `src/state/keyboard-input.ts` (held gestures take priority)                                                                                                                                                                                                                                                                                                                                                       |
| What gesture is running now                          | `inFlightGesture`, `src/interactions/pointer-machine.ts`                                                                                                                                                                                                                                                                                                                                                                           |
| The canvas cursor                                    | `cursorFor`, `src/interactions/cursor.ts`                                                                                                                                                                                                                                                                                                                                                                                          |
| Held keys (Space-as-hand, Shift/Alt preview)         | the `HELD_GESTURES` table, `src/state/keyboard-input.ts`                                                                                                                                                                                                                                                                                                                                                                           |
| Which pointer surface owns Space                     | `useOverStage`, `src/state/hooks.ts`                                                                                                                                                                                                                                                                                                                                                                                               |
| Which tools a mode offers                            | `toolsForMode`, `src/state/app-state.ts`                                                                                                                                                                                                                                                                                                                                                                                           |
| Which sprite layers accept pointer events            | `layerInteractivity`, `src/interactions/layer-interactivity.ts`                                                                                                                                                                                                                                                                                                                                                                    |
| What a control looks like, and what hover does to it | one baseline rule in `src/controls.css` shared by `.ocv-btn`, `.ocv-input` and `.ocv-select`: the box, the background and the resting outline, then one hover rule for the same three. `CONTROL.height` / `CONTROL.radius` in `src/ui/tokens.ts` carry the same values for inline styles                                                                                                                                             |
| Which family a control belongs to                    | its class. `.ocv-btn` is a label you press, `.ocv-input` a field you type into, `.ocv-select` a dropdown. Modifiers: `.is-ghost`, `.is-icon`, `.is-segment`, `.is-toggle`, `.is-primary`, `.is-numeric`. `segmentCellClass` in `src/ui/tokens.ts` spells a segmented cell                                                                                                                                                          |
| Keyboard focus                                       | `--ocv-focus-w` in `src/styles.css`, over `--ocv-accent`: an accent outline on `:focus-visible`, plain `:focus` for a field, in `src/controls.css`. An outline, never a `box-shadow`                                                                                                                                                                                                                                                |
| The control you have picked                          | `.ocv-btn.is-active`: an accent line on the border box over the palest accent wash. It differs from focus by where the line sits, not by color                                                                                                                                                                                                                                                                                    |
| Which control paints over its neighbour              | the stacking rule beside the focus rule in `src/controls.css`: focus over hover over chosen. Marks paint outside the border box, so a tight group has to state the order                                                                                                                                                                                                                                                           |
| Glyph color                                         | `--ocv-glyph` / `--ocv-glyph-hover` in `src/styles.css`, taken by the dropdown chevron and command icon buttons. A `.is-toggle` never takes it, because the accent is what being chosen looks like                                                                                                                                                                                                                                 |
| A control's chrome from rest to press                | the ladder at `.ocv-btn.is-ghost` in `src/controls.css`: a faint border at rest, an ordinary one under the pointer, and a one-pixel nudge on press. `CONTROL.height` in `src/ui/tokens.ts` is the same box for a control styled inline                                                                                                                                                                                             |
| How an icon is drawn                                 | `ICON` / `STROKE` in `src/ui/glyphs.tsx`: a glyph's viewBox equals the pixels it draws in, at one weight                                                                                                                                                                                                                                                                                                                           |
| What the stage writes under a node                   | `peerLabelText` / `endpointLabelText`, `src/render/stage-labels.ts`, read by both the renderer and the layout solver                                                                                                                                                                                                                                                                                                               |
| What to call a session, or one of its ends           | `sessionPairName` / `sessionEndName`, `src/ui/session-name.ts`: a session has no name of its own, so it is named by the pair it joins, read at whichever moment the surface is showing. The Inspector's heading, its pickers, the timeline's pills and the gutter's row labels all read it, and `SESSION_PAIR_SEPARATOR` stands between the two ends                                                  |
| What a timeline row is called                        | `laneRowLabel`, `src/ui/Timeline/lane-bundle.ts`: the gutter reads the name its own span carries, so a row and the pill beside it cannot say two things. `gutterLabelText` in `gutter-paint.ts` is what fits it into the column                                                                                                                                                                                                    |
| One field row, and the line between two              | `Field` in `src/ui/inspector/fields.tsx` over the `.ocv-field` subgrid rule: key and value are one element, so the hairline belongs to the row. `belowRowStyle` in `styles.tsx` sets the gap inside a two-line row, tighter than the gap to the next                                                                                                                                                                                 |
| One row in a Connections list                        | `LinkRow` in `src/ui/inspector/links.tsx` over `.ocv-session-row`: one element, two slots, all chrome in the class                                                                                                                                                                                                                                                                                                                 |
| Inspector row shape                                  | the `ROW_H` family in `src/ui/inspector/styles.tsx`                                                                                                                                                                                                                                                                                                                                                                                |
| Inspector editable fields                            | `InlineTextField` / `EnumSelect` / `EditableIdField`, `src/ui/inspector/fields.tsx`                                                                                                                                                                                                                                                                                                                                                |
| Scrub gesture = one undo step                        | `EditBracket` in `src/ui/inspector/edit-bracket.ts`, fired by `ScrubInput`                                                                                                                                                                                                                                                                                                                                                |
| When a new source means a new buffer                 | `bufferSourceTracker`, `src/state/hooks.ts`. Rebuilding empties Undo, so only a different document earns one: not a mode switch, and not the working document handed back on leaving Build. It records every source it is asked about, including one it decided not to rebuild for                                                                                                                                                                                                                               |
| What the buffer is                                   | the source resolution in `App` + `BufferSourceInfo`                                                                                                                                                                                                                                                                                                                                                                                |
| A node's pin                                         | `src/engine/event-helpers.ts`: `authoredPeerPosition` for one peer, `authoredPins` for the stage                                                                                                                                                                                                                                                                                                                                   |
| Timing provenance                                    | `TimeSpan.derived`, `src/engine/temporal/time-span.ts`: projection marks it, authoring strips it                                                                                                                                                                                                                                                                                                                                   |
| Whether a write changes anything                     | `isNoOpIntent`, `src/engine/no-op-guards.ts`. A keyframe restating a value still pins it (`keyframeExactlyAt`)                                                                                                                                                                                                                                                                                                                     |
| The live feed's connection                           | `useLiveConnection`, `src/state/hooks.ts`: a URL is a dial. `connected` means CapTP is up. `observed` means a record has arrived. Recording is a third fact.                                                                                                                                                                                                                                                                       |
| Live recording                                       | the same hook's capture arm. Record re-dials and mounts the engine, so t=0 is the press. Stop claims via `claimRecording`, `src/engine/live/mode.ts`                                                                                                                                                                                                                                                                               |
| Live wire names to stage identities                  | the `StageLedger`, `src/engine/stage-ledger.ts`: one lifetime per stage id, leaves refcounted by live sessions, epochs retire a dead producer                                                                                                                                                                                                                                                                                      |
| Builder mutations                                    | `engine.dispatch` intents, each with a no-op guard and an undo label. A guard compares against the authored doc, not the live world                                                                                                                                                                                                                                                                                                |
| Taking history back or forward                       | `undoWithSelection` / `redoWithSelection` / `undoAllWithSelection` / `discardAllEdits`, `src/builder/selection-history.ts`: a history step moves ids out from under the selection, so the step and the walk that catches the selection up are one act. Neither the top bar's buttons nor the Cmd-Z binding calls `engine.undo` itself                                                                                                                                               |
| What the Tools pane offers as a command              | `src/ui/ToolCommands.tsx`: a command is an act that runs once, not a tool you sit in, so it is a text button in the wrapping row under the strip rather than a sixth icon square. `ToolCommandButton` holds all three rules: Build only, inert with a tooltip that says why, and a `confirm` exactly when the act cannot be taken back                                                                                                                                             |
| Going back to where the buffer started               | two questions, not one. `Engine.undoAll` walks the history back and keeps it, offered on `canUndo`. `Engine.discardAllEdits` goes to the whole document the engine was built from and throws the history away, offered on `hasHistory`. The second reaches past the history's hundred-entry bound and past the fields `DocSnapshot` carries, which is why it is not a `BuilderIntent`                                                                                             |
| Whether an act may disturb a live capture            | the App's own `recording` state, read by every control that has to respect it (`ModeToggle`, `SaveOpenControls`, `LiveSturdyrefField`). A capture cannot outlive its connection, so an act that leaves Live is refused with the way out named. Stop and Discard are the only controls that end one                                                                                                                                                                              |
| What the arrow keys move                             | `nudgeSelection`, `src/builder/selection-history.ts`: the nodes the stage lets you drag, a peer or an end nothing has attributed. A press that moves nothing hands the keystroke back and it scrubs time                                                                                                                                                                                                                                     |
| Whether the document still holds an entity           | `documentHolds` in `src/interactions/selection-store.ts`, over `doc.entities`. An entity can be declared with no observation at all, and a peer added in Build is exactly that                                                                                                                                                                                                                                                     |
| A modal dialog                                       | `Dialog` in `src/ui/Dialog.tsx` over the rules in `src/ui/dialog.ts`: one box, and one input contract. Everything else on the page goes inert while it is up, keystrokes stop at the panel rather than reaching the app's window listener, the pointer is claimed from the gesture router by `holdPointerForModal` so a gesture in flight cannot outrank the dialog, and Escape, Enter and Tab mean the same thing in every dialog |
| What a picker offers                                 | the schema itself, in `src/schema/topology.ts`. A closed set is read off its own declaration (`Codec.options`, `CaptpVersion.options`, `SessionState.options`) and an open one off the list that names the offer (`PROFILE_OPTIONS`, `TRANSPORT_OPTIONS`). A picker never spells its own list, because a value added to the schema would then reach the document by one route and the picker by another                            |
| What a value in the document means                   | the tables under `src/ui/reference/`, one per closed set, each keyed by the type the schema declares so a value added there cannot ship without an explanation. The Legend says which mark stands for a value and the Reference says what the value means. `REFERENCE_SECTIONS` in `src/ui/reference/Reference.tsx` is the list of sections                                                                                         |
| Value display                                        | `src/ui/format.ts`, two roles: a fact reads at full fidelity (`formatTime`, `formatCoord`, `formatHexDump`), a moving readout reads coarse and stable (`formatClockTime`)                                                                                                                                                                                                                                                          |
| What kind of evidence backs an attribution           | `ATTRIBUTION_STANDING` in `src/schema/session-end.ts`, beside the words it classifies. Two surfaces ask it and must not answer differently: `attributionChipStyle` in `src/ui/EntityChips.tsx` picks the chip's tone from it, and the Reference's attribution section ranks its rows by it. Whether a name was backed at all is a separate question from how far the netlayer can be trusted, which belongs to the transports section |
| Which peer a session end claims                      | `claimedPeerByEnd` in `src/engine/claims.ts`, answered over the whole document so a designator two peers answer to resolves to nobody even when their lifetimes never overlap. Whether that claim is on stage at a moment is the separate question `claimsOnStage` answers                                                                                                                                                         |
| What the Inspector says about a selection            | `SelectionFields` in `src/ui/inspector/SelectionPanel.tsx` over the pure facts in `selection-summary.ts`. A panel changes the selection only by handing a set to the host's `set-selection`. It never mutates one itself                                                                                                                                                                                                            |
| What to call an entity in one line of running text   | `entityLabel` in `src/ui/inspector/SelectionPanel.tsx`, and `pickerLabelFor` / `pickerLabels` in `src/ui/inspector/picker-labels.ts` for a dropdown: lead with the human name, and add the id only when two options would read alike, then on every option in that list. The test is on the rendered string, not the underlying field, and a qualifier constant across the whole list is not a qualifier                           |
| Which channel carries which fact                     | `src/render/palette.ts`. A fact keeps its channel across surfaces, so hue means identity everywhere and weight, alpha or lightness means state everywhere. A surface may change how a channel is realised, never which channel carries the fact                                                                                                                                                                                    |

## Working rules

- **A gesture's meaning follows the surface, not the mode.** Space pans over the
  stage. Off the stage it toggles transport in Play and Build, and does nothing
  in Live, which has no transport. Modes gate _mutation authority_.
- **Affordances precede actions.** A held modifier previews its effect on the
  cursor, a tool's tip sits above the stage, and a refused click says why
  instead of doing nothing.
- **One undo step per user gesture, and every edit is one.** A drag, a scrub, a
  wheel burst or a typing burst brackets its dispatches in one transaction.
  Anything that changes the composition takes an undo step. Zoom, pan,
  playhead position, open panes, and mode leave the history alone.
  `undo-coverage.test.ts` holds the first half, one case per intent, and refuses
  to compile when an intent arrives without one.
- **Reuse layout only when the edit preserves its equilibrium.** The
  force layout is multi-stable, so re-annealing with a changed constraint can
  settle into a different arrangement even when nothing semantically moved. A
  pin landing where the era already has the peer keeps that layout
  (`recomputeForPlacement`). A moved pin, an unpin, and every structural change
  derive cold through `recompute()`, which is one deterministic function of the
  document, so a pin-then-unpin round trip leaves the stage exactly still.
- **Tables over switches.** When behavior is a mapping, it is data with a small
  interpreter and unit tests, and the doc points at the table instead of
  restating it.
- **A duplicated form is a defect even when it works.** The fix for a
  surface that looks wrong is usually moving it into the idiom's home, not
  adjusting its pixels.
