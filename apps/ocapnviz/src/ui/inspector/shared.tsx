/**
 * Inspector shared primitives. Styles, format helpers, the
 * `EditorBindings` contract, and small widgets used by every
 * per-entity panel (Peer / Session / Message). Sidebar.tsx
 * orchestrates; the panels paint; this module supplies the
 * lego bricks both sides build out of.
 *
 * Time fields throughout the Inspector edit in seconds; engine
 * units are ms. Centralized so all three entity panels share
 * the same display + parse contract.
 */

import { useCallback, useEffect, useRef, useState } from "react";
import type { StageSelection } from "../../render/types.ts";
import type { MoveIntent, MoveSpanIntent } from "../../engine/authoring/events.ts";
import type { EngineError, EngineResult } from "../../engine/errors.ts";
import { FieldError } from "../error/FieldError.tsx";
import { ClearGlyph, PinGlyph } from "../glyphs.tsx";
import { ScrubInput } from "../Timeline/ScrubInput.tsx";
import type {
  CaptpVersion,
  Codec,
  EndpointAttachment,
  EndpointAttribution,
  PeerProfile,
  SessionSide,
  SessionState,
  Transport,
} from "../../schema/topology.ts";
import { attachedTo, backedBy, PROFILE_OPTIONS } from "../../schema/topology.ts";
import { UNNAMED_END_LABEL } from "../../schema/topology.ts";
import { c, CONTROL, FONT, PANEL, SIZE, SPACE, WEIGHT } from "../tokens.ts";
import { Identifier } from "../identifier.tsx";
import type { PeerProperty, SessionProperty, SessionValue, TrajectoryDisplay } from "../../engine/trajectory.ts";
import {
  LifecycleChip,
  type LifecycleStatus,
  MessageKindLabel,
  PeerKindLabel,
  PeerSwatch,
  SessionKindLabel,
  SessionSwatch,
  StateChip,
} from "../EntityChips.tsx";

// ───────────────────────── time format helpers ─────────────────────────

// The one authority is `src/ui/format.ts`; re-exported here
// because every inspector panel reads its time vocabulary through
// this module.
export { formatTime, formatTimeInput, parseTime } from "../format.ts";
import { formatCoord, formatTime, formatTimeInput, parseTime } from "../format.ts";

// ───────────────────────── entity picker labels ────────────────────────

// How a dropdown names the thing it is offering. The rule itself lives in
// `./picker-labels.ts`, which is pure and knows nothing of React;
// re-exported here so a picker reads its label rule from the same module
// it takes its controls from.
export { pickerLabelFor, pickerLabels, type PickerOption } from "./picker-labels.ts";
import { pickerLabelFor, type PickerOption } from "./picker-labels.ts";

// ───────────────────────── editor contract ─────────────────────────────

/** When set, the Details section renders writable fields and the
 * delete affordance. App provides this only in build mode.
 * `beginEdit`/`endEdit` brackets a focus session so a typing burst
 * collapses to one undo step; the label becomes the action name in
 * the undo tooltip. `onDelete` cascades through the engine
 * (deleting a peer removes its sessions and their messages). */
export type EditorBindings = {
  onUpdatePeer: (
    peerId: string,
    patch: {
      label?: string;
      profile?: PeerProfile;
      designator?: string;
    },
  ) => void;
  /** Reposition (= pin) a peer from the inspector's coordinate
   * fields — same intent the stage drag dispatches. */
  onRepositionPeer: (
    peerId: string,
    position: { x: number; y: number },
  ) => void;
  /** Unpin a peer: drop its authored position so the force layout
   * places it again — the inverse of drag-to-pin. */
  onUnpinPeer: (peerId: string) => void;
  /** Pin a session end nothing has attributed, by its `sessionId::side`
   * stage id. The endpoint sibling of `onRepositionPeer`, separate
   * because the position lands on the session that owns the end. */
  onRepositionEndpoint: (
    endpointId: string,
    position: { x: number; y: number },
  ) => void;
  /** Unpin a session end. */
  onUnpinEndpoint: (endpointId: string) => void;
  onUpdateSession: (
    sessionId: string,
    patch: {
      codec?: Codec;
      captpVersion?: CaptpVersion;
      /** The netlayer the session runs over; `null` stops stating one. */
      transport?: Transport | null;
      state?: SessionState;
    },
  ) => void;
  onUpdateMessage: (
    messageId: string,
    patch: {
      label?: string;
      sessionId?: string;
      swapDirection?: true;
    },
  ) => void;
  /** Retime a single event. Pass a tagged-union `MoveIntent` so each
   *  gesture (`translate` body slide, `resize-start` left edge,
   *  `resize-end` message right edge) declares exactly the inputs
   *  it needs. */
  onMoveEvent: (move: MoveIntent) => void;
  /** Retime a peer or session span addressed by entity — the write
   *  path for spans with no anchor observation event (freshly
   *  authored entities), and the timeline drag's dispatch for them. */
  onMoveEntitySpan: (move: MoveSpanIntent) => void;
  /** Storage-shaped peer duration edit. Inspector dispatches this
   *  directly; the eternal-peer case stays a real option —
   *  `onClearPeerEnd` removes the `peer-left` event entirely.
   *  Absolute-time end edits flow through `move-event` (drag) or
   *  the `set-peer-end` intent on the engine directly. */
  onSetPeerDuration: (peerId: string, duration: number) => void;
  onClearPeerEnd: (peerId: string) => void;
  /** Opt-in START time for a peer — mirror of the end-time
   * pair. `onClearPeerStart` makes the peer eternal-start
   * (no `peer-joined` event; identity stays in
   * `doc.entities.peers`). `onSetPeerStart` re-anchors a start
   * time, reading identity from the entities map. */
  onSetPeerStart: (peerId: string, t: number) => void;
  onClearPeerStart: (peerId: string) => void;
  /** Storage-shaped session duration edit. `onClearSessionEnd`
   *  removes the `session-closed` event (eternal-session). */
  onSetSessionDuration: (sessionId: string, duration: number) => void;
  onClearSessionEnd: (sessionId: string) => void;
  /** Session-trajectory edits, addressed by property the way the peer
   *  pair below is: a session's lifecycle and each of its two ends
   *  change over time, and each moment is one property taking a value
   *  at one `t`. The property set lives in `engine/trajectory.ts`, so
   *  a fourth session property needs nothing here.
   *
   *  Row 0 is the value the session is BORN with, and it is not a
   *  moment: `onSetSessionInitialState` edits the genesis state, and
   *  `onUpdateSessionEndpoint` the genesis end — including detaching
   *  it, which no moment can say. */
  onSetSessionKeyframe: (
    sessionId: string,
    property: SessionProperty,
    t: number,
    /** What the property takes at `t`, in its own value channel — one
     *  word, or the pair an end attaches by. */
    value: SessionValue,
  ) => void;
  onRemoveSessionKeyframe: (
    sessionId: string,
    property: SessionProperty,
    t: number,
  ) => void;
  onSetSessionInitialState: (sessionId: string, state: SessionState) => void;
  onUpdateSessionEndpoint: (
    sessionId: string,
    side: SessionSide,
    patch: {
      /** The peer this end attaches to; `null` detaches it and the
       *  end goes loose. */
      peer?: string | null;
      /** What the end claims to be; `null` drops the claim. */
      designator?: string | null;
      /** What backed the claim; `null` means nothing did. */
      attributedBy?: EndpointAttribution | null;
    },
  ) => void;
  /** Peer-trajectory edits, the peer sibling of the state
   *  trajectory. What a peer ARRIVES with is `onUpdatePeer` — a
   *  session's genesis state in peer form; each later moment states
   *  one property at its own `t`, addressed here the way state
   *  keyframes are addressed above. The property set lives in
   *  `engine/trajectory.ts`, so a second temporal peer property
   *  needs nothing here. */
  onSetPeerUpdate: (
    peerId: string,
    t: number,
    property: PeerProperty,
    value: string,
  ) => void;
  onRemovePeerUpdate: (
    peerId: string,
    t: number,
    property: PeerProperty,
  ) => void;
  /** Session start / message start counterparts of the peer
   *  start pair. Clearing a session start makes its effective
   *  start cascade to `max(peerA.effectiveStart,
   *  peerB.effectiveStart)`; clearing a message start cascades
   *  to its session's effective start. */
  onSetSessionStart: (sessionId: string, t: number) => void;
  onClearSessionStart: (sessionId: string) => void;
  onSetMessageStart: (messageId: string, t: number) => void;
  onClearMessageStart: (messageId: string) => void;
  /** Storage-shaped message flight duration edit. */
  onSetMessageDuration: (messageId: string, duration: number) => void;
  beginEdit: (label: string) => void;
  endEdit: () => void;
  onDelete: (selection: StageSelection) => void;
  /** Pre-flight collision check for the Inspector ID cell. Pure
   *  read; no state change. Inspector calls this on blur before
   *  dispatching `onRename` so the user sees the collision message
   *  inline rather than via the global error bus. */
  validateRename: (
    kind: "peer" | "session" | "message",
    oldId: string,
    newId: string,
  ) => EngineResult<void>;
  /** Commit a rename. Cascades the new id through every reference
   *  site (entities map, cross-category endpoints, events,
   *  rowOrder / rowHidden lists) in one engine transaction —
   *  one undo step. Returns the result so the Inspector can show
   *  a collision message inline on the (rare) race where validate
   *  passed but dispatch racing rejected. App-side handler also
   *  re-anchors the selection at the new id so the Inspector
   *  keeps tracking the entity post-rename. */
  onRename: (
    kind: "peer" | "session" | "message",
    oldId: string,
    newId: string,
  ) => EngineResult<void>;
};

// ───────────────────────── inspector styles ────────────────────────────

// The panel heading is one line and it stays one line. What sits in it is
// whatever the entity answers to, and for a session over iroh that is a
// sixty-four character key: left to wrap it broke at the space in
// "a ↔ b" and put a clipped hex string on each of two lines. `PanelHeading`
// is the only door to these two, so a new panel cannot reintroduce that.
const headingClamp = {
  overflow: "hidden",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
  minWidth: 0,
} satisfies React.CSSProperties;

const heading = {
  fontWeight: WEIGHT.semibold,
  fontSize: SIZE.lg,
  color: c.text,
  lineHeight: 1.3,
  letterSpacing: -0.01,
  ...headingClamp,
} satisfies React.CSSProperties;

const headingMono = {
  ...heading,
  fontFamily: FONT.mono,
  fontSize: SIZE.base,
  letterSpacing: 0,
} satisfies React.CSSProperties;

/** The heading every entity panel opens with: the name of the thing the
 *  reader just selected.
 *
 *  `mono` picks the face. A name a person chose reads in the sans face
 *  the rest of the chrome uses; a string the network chose reads in the
 *  mono face every unproven token wears here.
 *
 *  `title` is what a reader gets on hover, which matters because the
 *  heading clips: pass the whole name even when the children are already
 *  elided. */
export function PanelHeading(
  { title, mono, children }: {
    title: string;
    mono?: boolean;
    children: React.ReactNode;
  },
) {
  return <div style={mono ? headingMono : heading} title={title}>{children}</div>;
}

export const placeholder = {
  color: c.textSubtle,
  fontSize: SIZE.sm,
  lineHeight: 1.55,
} satisfies React.CSSProperties;

// `minmax(0, 1fr)` on the value column, never a bare `1fr`. A bare `1fr`
// is `minmax(auto, 1fr)`, so its floor is the widest thing in it, and one
// unbreakable sixty-four character key widens the column past the panel
// and takes every other row's value with it. With a floor of zero the
// column obeys the panel and each value cell clips or elides on its own
// terms.
//
// Every direct child of this grid is a `Field`, which spans both tracks
// and re-inherits them with `subgrid`. The row gap here is therefore the
// space between one field's hairline and the next field's content;
// `.ocv-field`'s own bottom padding is the space above that line.
//
// The key column is a fixed width, and that is the point of it. Each
// field group is its own grid, so a track that sized itself to content
// gave every group the width of ITS OWN longest key: Details landed at
// one width and Timing at another, and the keys stopped forming a column
// down the panel. Pinning the track is what makes a reader's eye able to
// run down the keys across groups, which is how a dense panel stays
// readable as the type gets smaller.
//
// 78px is the widest key the app renders today, `CAPTP VERSION`, measured
// at the key's own 9px uppercase face with its tracking. A longer key
// wraps, visibly, rather than silently widening its own group back out of
// alignment — a wrap is a defect somebody sees, and a group half a
// character out of step is not.
const KEY_COL_W = 78;

export const kv = {
  display: "grid",
  gridTemplateColumns: `${KEY_COL_W}px minmax(0, 1fr)`,
  rowGap: SPACE.xs + 1,
  columnGap: SPACE.md,
  fontSize: SIZE.sm,
} satisfies React.CSSProperties;

// The value half of a field row.
//
// A column, so each thing in it is block-level. That is not decoration:
// before this wrapper existed every value was a grid item, and a grid
// item is blockified, which is what makes `overflow: hidden` and an
// ellipsis work on a sixty-four character name. Left as inline content
// in a plain block, the same span stops clipping and takes the panel's
// right edge with it.
const fieldValueStyle = {
  minWidth: 0,
  display: "flex",
  flexDirection: "column",
  alignItems: "stretch",
} satisfies React.CSSProperties;

// One layout line of a value, and the panel's vertical rhythm.
//
// A field row used to be as tall as whatever it happened to hold: one
// control's worth where the value was a control, one line of text where
// it was text. That reads as uneven padding under the last row of a
// panel, because what the eye measures is the gap to the ink, not the
// gap to the box.
//
// So a line is a control's height whatever is in it, and its content
// centers. A bare word and a 22px control then put their ink on the
// same pixel, which is also what stops the whole panel shifting when
// the same entity is read in Build and in Play.
const fieldLineStyle = {
  minHeight: CONTROL.height,
  display: "flex",
  alignItems: "center",
  minWidth: 0,
} satisfies React.CSSProperties;

// A note under a value — the clamp hint, today. Its own block so it
// starts a line of its own whatever the value above it was.
const fieldNoteStyle = {
  marginTop: 2,
  minWidth: 0,
} satisfies React.CSSProperties;

/** One field row: a key and the value it names.
 *
 *  It is one element rather than two loose cells because the line under
 *  a field belongs to the field. A row whose value needs two layout
 *  rows — a trajectory moment's time above the controls that moment
 *  states — is still one field and still carries one line, under the
 *  pair, and nothing has to remember to leave the line out of the
 *  middle. `.ocv-field` in styles.css draws it and re-inherits the `kv`
 *  grid's tracks, so the keys stay in a column across the group.
 *
 *  `note` is a remark about the value rather than a value of its own,
 *  so it rides inside the row instead of becoming a field the line
 *  would separate from what it is talking about.
 *
 *  `below` is the second layout row of a field that needs one. It is a
 *  prop rather than part of `children` so the field can tell its first
 *  line from its second: only the first gets the height lockup. */
export function Field(
  { label, note, below, children }: {
    label: React.ReactNode;
    note?: React.ReactNode;
    below?: React.ReactNode;
    children: React.ReactNode;
  },
) {
  return (
    <div className="ocv-field">
      <span style={keyStyle}>{label}</span>
      <div style={fieldValueStyle}>
        <div style={fieldLineStyle}>{children}</div>
        {below !== undefined && below !== null && below}
        {note !== undefined && note !== null && <div style={fieldNoteStyle}>{note}</div>}
      </div>
    </div>
  );
}

/** Inner box of a labeled field group — the actual recessed
 *  rectangle. Title sits OUTSIDE / above the box (see
 *  `FieldGroup`); the box itself only holds the kv content so
 *  the title doesn't compete with the field rows for visual
 *  weight. */
const fieldGroupBox = PANEL;

/** Stack a `groupTitle` label above the `fieldGroupBox`. Same
 *  idiom as `subSection` / `subSectionLabel` further down the
 *  Inspector — gives the panel one consistent shape: small-caps
 *  label, then recessed content block. */
const fieldGroup = {
  display: "flex",
  flexDirection: "column",
  gap: SPACE.xs,
} satisfies React.CSSProperties;

/** The one small-caps heading in the Inspector: a tracked, uppercase
 * eyebrow at the eyebrow size, over a block of content. Both the
 * sub-section titles and the field-group titles are this. */
export const subSectionLabel = {
  fontSize: SIZE.xs,
  fontWeight: WEIGHT.semibold,
  letterSpacing: 0.6,
  textTransform: "uppercase",
  color: c.textSubtle,
} satisfies React.CSSProperties;

/** Small-caps header sitting above a `fieldGroupBox`. It IS
 * `subSectionLabel` — one visual rhythm in the Inspector, "stacked
 * rectangles, each with its own title" — inset by the box's own padding
 * so the title lines up with the field keys under it. Two spellings of
 * that typography is how a panel comes to have two sizes of heading. */
const groupTitle = {
  ...subSectionLabel,
  paddingLeft: SPACE.xs,
} satisfies React.CSSProperties;

export const keyStyle = {
  color: c.textSubtle,
  fontWeight: WEIGHT.medium,
  fontFamily: FONT.sans,
  fontSize: SIZE.xs,
  letterSpacing: 0.4,
  textTransform: "uppercase",
} satisfies React.CSSProperties;

// Mono renders visually larger than sans at the same px, so mono
// values drop one notch on the SIZE scale to stay proportional in
// mixed key/value rows.
//
// This is the face for a SHORT token: a codec, a side letter, a time. A
// long opaque string goes through `Identifier` instead, which elides its
// middle and keeps the whole value on hover. The clamp here is the
// backstop for a value that turns out longer than its author expected —
// it clips rather than pushing the panel open, which is the failure a
// reader can at least see and hover.
export const valueMono = {
  color: c.text,
  fontFamily: FONT.mono,
  fontSize: SIZE.xs,
  fontVariantNumeric: "tabular-nums",
  display: "inline-block",
  verticalAlign: "bottom",
  maxWidth: "100%",
  minWidth: 0,
  overflow: "hidden",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
} satisfies React.CSSProperties;

// A value that is a sentence rather than a token — an explanation
// the reader needs in words. Sits beside `valueMono` in the same
// key/value grid, so it wraps and reads as prose while mono values
// stay tabular.
export const valueText = {
  color: c.textMuted,
  fontSize: SIZE.xs,
  lineHeight: 1.5,
} satisfies React.CSSProperties;

// A value that is a name a person chose, such as a peer's label. Sans
// face because it is a word rather than a token, and clipped at its end
// because a name reads left to right — the head is the part that
// identifies it. An opaque string goes to `Identifier` instead, which
// keeps both ends.
export const valueName = {
  color: c.text,
  fontSize: SIZE.sm,
  overflow: "hidden",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
  minWidth: 0,
} satisfies React.CSSProperties;

// Inline editable inputs used by the entity panels in build mode.
// Shapes echo the static `heading` / mono-value styles so the
// display ↔ edit transition doesn't shift the panel.
//
// Only typography. The box — corner, inset, surface, bevel, hover,
// focus — is `.ocv-input`'s in styles.css, and an inline copy of any of
// it would beat the class and freeze it. These two carried a corner and
// an inset each, which is how one field sat its text 6px in, its
// neighbour 8px, and the dropdown under them 10px.
export const inlineHeadingInput = {
  width: "100%",
  fontFamily: FONT.sans,
  fontSize: SIZE.lg,
  fontWeight: WEIGHT.semibold,
  letterSpacing: -0.01,
  lineHeight: 1.3,
} satisfies React.CSSProperties;

export const inlineMonoInput = {
  width: "100%",
  fontFamily: FONT.mono,
  fontSize: SIZE.sm,
} satisfies React.CSSProperties;

// Inspector enum-field `<select>`. Only overrides the kv-grid
// geometry — chevron, surface fill, hover, focus all live in
// `.ocv-select` so chevron rendering can stay theme-aware (the
// class swaps an accent-stroked SVG per `[data-theme]`, which an
// inline `background-image: url(currentColor…)` cannot do because
// data URIs don't read CSS variables).
//
// The right padding clears the chevron (13px wide, inset 5px) and then
// leaves a gap, because a native `<select>` clips its own text with no
// ellipsis: a long option run flush against the chevron reads as a
// rendering fault rather than as a value that did not fit. Options whose
// text can be an opaque identifier elide it before it gets here.
export const inlineSelectInput = {
  fontFamily: FONT.sans,
  fontSize: SIZE.sm,
  width: "100%",
  // No padding here. `.ocv-select` already sets the inset a dropdown wants,
  // chevron room included, and an inline value beats the class — which is how
  // a dropdown came to sit its text 6px in beside a top-bar one at 10px. Same
  // height, different rhythm, which is what reads as inconsistent.
} satisfies React.CSSProperties;

export const subSection = {
  display: "flex",
  flexDirection: "column",
  gap: SPACE.sm,
} satisfies React.CSSProperties;

export const linkRowList = {
  display: "flex",
  flexDirection: "column",
  gap: SPACE.xs,
} satisfies React.CSSProperties;

// Selection-membership badge — small uppercase tag rendered to the
// LEFT of the row's right-side meta. The visual signal "this is
// also in your selection" without leaning entirely on color.
const linkRowSelectedBadge = {
  fontSize: SIZE.xs,
  fontWeight: WEIGHT.semibold,
  letterSpacing: 0.6,
  textTransform: "uppercase",
  color: c.accent,
  marginRight: SPACE.xs,
  whiteSpace: "nowrap",
  flexShrink: 0,
} satisfies React.CSSProperties;

const linkRowLeft = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.sm,
  minWidth: 0,
} satisfies React.CSSProperties;

const linkRowName = {
  fontWeight: WEIGHT.semibold,
  whiteSpace: "nowrap",
  overflow: "hidden",
  textOverflow: "ellipsis",
  minWidth: 0,
} satisfies React.CSSProperties;

/** The right-hand cell of a link row, holding whatever badge the row
 *  ends with.
 *
 *  It does not shrink. A row has one thing that gives way when the panel
 *  narrows and it is the name on the left, which ellipsizes; a status
 *  badge is two or three words that mean nothing broken apart, and left
 *  to shrink it wraps and takes the row's height with it. "Not yet
 *  joined" set three lines tall beside a one-line name is what this
 *  cell exists to prevent. */
const linkRowMetaCell = {
  display: "inline-flex",
  alignItems: "center",
  flexShrink: 0,
  maxWidth: "100%",
} satisfies React.CSSProperties;

// The plain-text end of a link row, where a chip is not what the row
// has to say. Same rule as a chip: one line, and the name on the left
// gives way first.
const linkRowMeta = {
  fontFamily: FONT.mono,
  fontSize: SIZE.xs,
  color: c.textSubtle,
  letterSpacing: 0.02,
  whiteSpace: "nowrap",
} satisfies React.CSSProperties;

// Single source of truth for the optional-time row height. Every cell
// in the row (scrub input, ✕, "Insert @playhead") locks to this value
// so heights match exactly and the ✕ can be a true square by mirroring
// the height into its width. Reads the one control height rather than
// restating it: this row is not "22 tall", it is "as tall as every other
// control", and a second spelling of that is how they drift apart.
export const ROW_H = CONTROL.height;

/** The edit-transaction pair a row needs from `EditorBindings` so a
 * scrub gesture lands as ONE undo step. */
export type EditSession = Pick<EditorBindings, "beginEdit" | "endEdit">;

/**
 * One edit transaction's brackets, tracking whether it is open.
 *
 * Opening one is easy and closing one is the whole problem. A field
 * opens on focus and closes on blur, but a panel whose entity stops
 * being selected unmounts its field WITHOUT a blur, and the
 * transaction it left open swallows every dispatch after it: the
 * engine records history only at depth zero, so from that moment
 * nothing in the app is undoable. Two of the five panels had each
 * written their own unmount guard for this and three had not, which
 * is what a rule enforced by remembering looks like after a while.
 *
 * So the bracket knows if it is open, and closing twice is not a
 * second close. `useEditBracket` below hands its `end` to React's
 * unmount, which is the only thing a field can be sure of.
 *
 * Which editor it opened on is the other half, and it is the half a
 * flag cannot hold. The editor under a field is not a constant: it is
 * undefined outside Build and a different object once the buffer is a
 * different engine, and both changes are reachable while a caret sits
 * in a field. So `sessionNow` is asked once, at `begin`, and the
 * answer is what `end` closes — the transaction belongs to the editor
 * that opened it, and closing it against whatever the field is holding
 * a moment later either closes nothing (the leak this exists to stop)
 * or ends a transaction on an engine that never began one. Asked and
 * answered undefined, there is no bracket at all: a read-only host
 * opens nothing and so has nothing to close.
 *
 * This is a plain factory rather than a hook so a test can drive open,
 * close and the editor changing underneath in the orders a user
 * reaches them in.
 */
export function editBracket(sessionNow: () => EditSession | undefined): {
  begin: (label: string) => void;
  end: () => void;
  readonly isOpen: boolean;
} {
  let open: EditSession | null = null;
  const end = () => {
    const opened = open;
    if (opened === null) return;
    open = null;
    opened.endEdit();
  };
  return {
    begin(label: string) {
      if (open !== null) return;
      const session = sessionNow();
      if (session === undefined) return;
      open = session;
      session.beginEdit(label);
    },
    end,
    get isOpen() {
      return open !== null;
    },
  };
}

/**
 * One typed-but-not-yet-handed-up edit, tracking whether it is still
 * waiting.
 *
 * `editBracket` above is the same story about an undo step; this is
 * the story about the edit itself. A field holds a draft while it is
 * being typed and hands it up when the reader is done, and "done" is
 * spelled as blur. Selecting another entity unmounts the field
 * WITHOUT a blur, so the draft went with it and the rename the reader
 * typed simply never happened. Nothing said so, which is what makes it
 * worse than a lost undo step: the reader watched themselves type it.
 *
 * So the edit knows whether it is still waiting, and handing it up
 * twice is not a second edit. `usePendingEdit` below hands its
 * `dispose` to React's unmount, which is the only thing a field can be
 * sure of. That second half is load-bearing on its own: a rename that
 * lands moves the anchor, which unmounts the field that made it, and
 * an unmount that handed the same draft up again would ask to rename
 * an id the document no longer has.
 *
 * `touch` says the draft has moved since it was last handed up, and
 * whether the draft differs from the committed value at all stays the
 * commit function's own question. `discard` is how a reader says no:
 * putting the draft back and then blurring cannot do it, because the
 * put-back is a state update that has not landed by the time the blur
 * runs, so the commit would read the draft the reader just abandoned.
 * This is a plain factory rather than a hook so a test can drive
 * typing, committing, abandoning and unmounting in the orders a reader
 * reaches them in.
 */
export function pendingEdit(commit: () => void): {
  touch: () => void;
  settle: () => void;
  discard: () => void;
  dispose: () => void;
  readonly isPending: boolean;
} {
  let waiting = false;
  const settle = () => {
    if (!waiting) return;
    waiting = false;
    commit();
  };
  return {
    touch() {
      waiting = true;
    },
    settle,
    discard() {
      waiting = false;
    },
    dispose: settle,
    get isPending() {
      return waiting;
    },
  };
}

/** A `pendingEdit` that lives as long as the field holding it, and
 *  hands its draft up when that field goes away. */
function usePendingEdit(commit: () => void) {
  // `commit` closes over this render's draft, so the pending edit
  // reads it through a ref rather than being rebuilt around it — a
  // rebuilt one would forget that an edit was waiting, and hand up a
  // stale draft when it did fire.
  const commitRef = useRef(commit);
  commitRef.current = commit;
  const held = useRef<ReturnType<typeof pendingEdit> | null>(null);
  if (held.current === null) {
    held.current = pendingEdit(() => commitRef.current());
  }
  const edit = held.current;
  useEffect(() => () => edit.dispose(), [edit]);
  return edit;
}

/** An `editBracket` that lives as long as the component holding it,
 *  and closes itself when that component goes away or when the editor
 *  under it changes. */
function useEditBracket(session: EditSession | undefined) {
  // One bracket for the field's whole life, reading the editor through
  // a ref rather than being rebuilt around it — a rebuilt bracket would
  // forget that it was open. The ref is read at `begin` and the answer
  // held, so a later render pointing it somewhere else cannot move an
  // open transaction.
  const sessionRef = useRef(session);
  sessionRef.current = session;
  const bracket = useRef<ReturnType<typeof editBracket> | null>(null);
  if (bracket.current === null) {
    bracket.current = editBracket(() => sessionRef.current);
  }
  const held = bracket.current;
  // Two ends a field never hears about, and one effect for both. The
  // field going away is the first: React has already detached its
  // handlers, so no blur is coming. The editor changing under a field
  // that stays is the second, and it is why `session` is a dependency:
  // leaving Build takes the editor away, and a new buffer replaces it,
  // and either way the transaction the old one opened has to be closed
  // on the old one while something still holds it.
  useEffect(() => () => held.end(), [held, session]);
  return held;
}

/** Drag brackets for a row's scrub input: open a labeled edit
 * transaction when the drag starts, close it when the drag ends, and
 * close it too if the row goes away mid-drag. Undefined session means
 * no brackets, for read-only hosts. */
export function useScrubSession(
  session: EditSession | undefined,
  label: string,
): { onScrubStart?: () => void; onScrubEnd?: () => void } {
  const bracket = useEditBracket(session);
  const onScrubStart = useCallback(() => bracket.begin(label), [
    bracket,
    label,
  ]);
  const onScrubEnd = useCallback(() => bracket.end(), [bracket]);
  if (!session) return {};
  return { onScrubStart, onScrubEnd };
}

// A time and the controls docked beside it. No height of its own: the
// field's line owns the row's rhythm, and this used to be the one place
// that happened to carry it, which is why a time row stood taller than
// every other read-only row in the panel.
const endRowStyle = {
  display: "flex",
  alignItems: "center",
  gap: SPACE.xs,
  minWidth: 0,
  flex: 1,
} satisfies React.CSSProperties;

// The second layout row of a field whose value needs one: the controls
// a trajectory moment states, sitting under the time that dates them.
// Full width of the value column, which is what gives an end's pair of
// pickers a half of the column each instead of a half of whatever the
// time field left over.
/** The gap is what says the two lines are one field, so it has to be
 *  visibly tighter than the gap to the NEXT field — which is the row's
 *  own bottom padding plus its hairline plus the grid's row gap, about
 *  eleven pixels.
 *
 *  Editing, the two lines are boxed controls, and a box's edges do the
 *  grouping on their own; the gap can be the ordinary small step and
 *  the pair still reads as a pair. Reading, both lines are bare text in
 *  a control-height row, so several pixels of the row's own dead space
 *  already sit between them and the same step on top brings the pair up
 *  to the distance between whole fields. Then proximity is saying the
 *  wrong thing: two lines of one field read as two fields that lost
 *  their divider.
 *
 *  So the step is the editing case's alone. It is one fact — how far
 *  apart the lines of a field sit — asked of the only thing that
 *  changes the answer. */
function belowRowStyle(editing: boolean): React.CSSProperties {
  return {
    marginTop: editing ? SPACE.xs : 0,
    minWidth: 0,
  };
}

// The scrub wrapper grows to consume whatever the row has left, which
// docks the ✕ at the right edge and gives the digits a target.
export const endRowScrubStyle = {
  minWidth: 0,
  height: ROW_H,
  flex: 1,
} satisfies React.CSSProperties;

// A worded button in one of these rows — "Insert @playhead" and its
// siblings. It holds its width against the scrub input beside it and
// reads at the panel's size rather than the chrome's; the box is
// `.ocv-btn`'s.
export const endRowButtonStyle = {
  flex: "0 0 auto",
  fontFamily: FONT.sans,
  fontSize: SIZE.sm,
} satisfies React.CSSProperties;

// The ✕ / pin that ends one of these rows. Square is `.ocv-btn.is-icon`
// at the call site — the same square the top bar's icon buttons take —
// and all this adds is the push that docks it against the row's right
// edge. It used to spell the square itself, out of the row height, and
// so was a second answer to "how big is an icon button".
//
// The bordered face, not the ghost one. Ghost belongs to the top bar,
// where a row of glyphs sits on chrome; in a pane of labels and values a
// borderless control reads as part of the value it sits beside rather
// than as something to press. The document panel's Opens-at row wears
// the same pair for the same reason.
export const endRowIconButtonStyle = {
  marginLeft: "auto",
} satisfies React.CSSProperties;

// ───────────────────────── shared widgets ──────────────────────────────

/** Inline editable ID cell. Tracks a local draft while the user
 *  types so a partial edit doesn't fight the engine; commits the
 *  rename on blur (or Enter), pre-flighting via
 *  `editor.validateRename` so collisions surface as inline
 *  `<FieldError>` instead of bus toasts. Escape reverts the draft
 *  to the committed id and abandons the edit. */
export function EditableIdField(
  { kind, id, editor }: {
    kind: "peer" | "session" | "message";
    id: string;
    editor: EditorBindings;
  },
) {
  // The draft starts at the committed id and stays local until the
  // field commits. Nothing syncs the prop back into it, because
  // nothing has to: App keys the whole Details subtree on
  // `${anchor.kind}:${anchor.id}`, so a committed rename mounts a
  // fresh field at the new id and this state starts over. A sync
  // effect beside that key was a second mechanism for the same job,
  // and it was the one that ran a paint behind.
  const [draft, setDraft] = useState(id);
  const [error, setError] = useState<EngineError | null>(null);

  const commit = () => {
    const next = draft.trim();
    if (next === id) {
      setError(null);
      return;
    }
    if (next.length === 0) {
      // Treat empty as a revert — don't try to rename to "".
      setDraft(id);
      setError(null);
      return;
    }
    const v = editor.validateRename(kind, id, next);
    if (!v.ok) {
      setError(v.error);
      return;
    }
    const r = editor.onRename(kind, id, next);
    setError(r.ok ? null : r.error);
  };
  // Blur is what a reader means by "done", and it is not the only way
  // they get there: clicking a different entity on the stage unmounts
  // this field with the caret still in it and no blur behind it. The
  // pending edit hands the draft up on either path and on neither
  // twice, so the rename cannot be dropped and cannot be replayed
  // against the id it has already changed.
  const pending = usePendingEdit(commit);

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
      <input
        type="text"
        className="ocv-input"
        value={draft}
        onChange={(ev) => {
          setDraft(ev.target.value);
          pending.touch();
          // Clear stale error as the user keeps typing — they're
          // already correcting.
          if (error) setError(null);
        }}
        onBlur={() => pending.settle()}
        onKeyDown={(ev) => {
          if (ev.key === "Enter") {
            ev.currentTarget.blur();
          } else if (ev.key === "Escape") {
            // Say no to the edit before leaving, not by putting the
            // draft back: `setDraft` has not landed by the time the
            // blur below runs, so a commit reading the draft would
            // read the one the reader just abandoned and rename
            // anyway. The put-back is what the reader then sees.
            pending.discard();
            setDraft(id);
            setError(null);
            ev.currentTarget.blur();
          }
        }}
        spellCheck={false}
        style={inlineMonoInput}
        aria-invalid={error !== null}
        aria-label={`${kind} id`}
      />
      <FieldError error={error} />
    </div>
  );
}

export function FieldGroup(
  { title, children }: { title: string; children: React.ReactNode },
) {
  return (
    <div style={fieldGroup}>
      <div style={groupTitle}>{title}</div>
      <div style={fieldGroupBox}>{children}</div>
    </div>
  );
}

/** What a picker offers for "no choice at all", as a value. An end
 *  attached to nobody, and an end nothing attributed, are real states
 *  rather than missing ones, so each picker carries an option for them
 *  and the empty string is what a `<select>` can hold. */
export const NONE = "";

/** How the two "none" states read to a person.
 *
 *  They are ordinary states of the network rather than fields somebody
 *  forgot to fill, so each is spelled as an answer to the question its
 *  row asks. "Attached to" asks about a party, so the answer is a
 *  pronoun; "attribution" asks about a thing, so the answer is a noun.
 *  Neither is "loose", which is the word the model uses for an end
 *  nothing attributed and not a word a reader arrives with.
 *
 *  They are plain words rather than parenthesized ones on purpose:
 *  brackets read as chrome around an empty field, which is the reading
 *  these two states most need to avoid.
 *
 *  They live here because two surfaces ask the same question about one
 *  end — the session panel about the end a session is born with, and a
 *  trajectory row about the end at a moment — and two spellings of one
 *  word is where they would drift. */
export const NOBODY = "nobody";
export const NOTHING = "nothing";

export function EnumSelect<T extends string>(
  { value, options, ariaLabel, onChange, labelFor, disabledReason }: {
    value: T;
    options: readonly T[];
    ariaLabel: string;
    onChange: (next: T) => void;
    labelFor?: (v: T) => string;
    /** Why this control cannot take effect right now, in words. A
     *  picker whose write the engine would refuse is worse than no
     *  picker: the reader changes it and nothing happens. Set this and
     *  it is disabled, wearing the reason as its tooltip. */
    disabledReason?: string | undefined;
  },
) {
  return (
    <select
      className="ocv-select"
      value={value}
      onChange={(e) => onChange(e.target.value as T)}
      aria-label={ariaLabel}
      style={inlineSelectInput}
      {...(disabledReason !== undefined ? { disabled: true, title: disabledReason } : {})}
    >
      {offeredWith(options, value).map((o) => <option key={o} value={o}>{labelFor ? labelFor(o) : o}</option>)}
    </select>
  );
}

/**
 * The picker that asks which peer is on an end.
 *
 * Two rows ask that question — the end a session is born with, and the
 * moment somebody attaches to it — and they are one control, because a
 * reader meets the same list of peers in both and should read it the same
 * way. The names come from `pickerLabels`, so a document with two peers
 * called Alice says which Alice in both places or in neither.
 *
 * "Nobody" is an answer only where it is a legal one. A session's genesis
 * end may hold nobody; a moment that attaches an end cannot, because an
 * attachment names somebody by definition and an end comes loose by
 * losing the moment instead.
 */
export function PeerSelect(
  { value, peers, ariaLabel, nobody = false, onChange, disabledReason }: {
    /** The peer on this end, or `NONE` when nobody is. */
    value: string;
    peers: readonly PickerOption[];
    ariaLabel: string;
    nobody?: boolean;
    /** The chosen peer's id, or `NONE` when the reader chose nobody. */
    onChange: (peerId: string) => void;
    disabledReason?: string | undefined;
  },
) {
  const labelFor = pickerLabelFor(peers);
  const ids = peers.map((p) => p.id);
  return (
    <EnumSelect
      value={value}
      options={nobody ? [NONE, ...ids] : ids}
      ariaLabel={ariaLabel}
      labelFor={(v) => v === NONE ? NOBODY : labelFor(v)}
      onChange={onChange}
      {...(disabledReason !== undefined ? { disabledReason } : {})}
    />
  );
}

/** The options a select offers, with the value it is actually holding
 *  among them.
 *
 *  A controlled `<select>` whose value matches no option shows the
 *  first one instead, and then the panel is stating a value the entity
 *  does not carry. That is reachable wherever the offered list is a
 *  shortlist rather than a domain: a peer's profile is any non-empty
 *  string, so a feed or an imported document can hand a picker
 *  something `PROFILE_OPTIONS` never named, and a select left to its
 *  own devices would report it as "pancake" while the chip beside it
 *  and the stage both showed the truth.
 *
 *  Nothing is added when the value is already offered, so a closed
 *  domain is unaffected. */
function offeredWith<T extends string>(
  options: readonly T[],
  value: T,
): readonly T[] {
  return options.includes(value) ? options : [...options, value];
}

/** Bulk-edit variant of `EnumSelect`. `commonValue` is the shared
 *  value across the selection, or `null` when entities disagree.
 *  In the mixed case the select renders a leading "—" sentinel
 *  option (no commit on its own); picking any concrete option
 *  fires `onChange` and the caller broadcasts to every selected
 *  entity. The "—" sentinel deliberately doesn't dispatch — there's
 *  no canonical "make it mixed" intent. */
export function BulkEnumSelect<T extends string>(
  { commonValue, options, ariaLabel, onChange, labelFor }: {
    commonValue: T | null;
    options: readonly T[];
    ariaLabel: string;
    onChange: (next: T) => void;
    labelFor?: (v: T) => string;
  },
) {
  const MIXED = "__mixed__";
  const selected = commonValue ?? MIXED;
  return (
    <select
      className="ocv-select"
      value={selected}
      onChange={(e) => {
        if (e.target.value === MIXED) return;
        onChange(e.target.value as T);
      }}
      aria-label={ariaLabel}
      style={inlineSelectInput}
    >
      {commonValue === null && <option value={MIXED}>— mixed —</option>}
      {(commonValue === null ? options : offeredWith(options, commonValue)).map(
        (o) => <option key={o} value={o}>{labelFor ? labelFor(o) : o}</option>,
      )}
    </select>
  );
}

export function TimeScrubInput(
  {
    value,
    min = 0,
    max,
    strictMax = false,
    onChange,
    label,
    style,
    onScrubStart,
    onScrubEnd,
  }: {
    value: number;
    /** Lower bound for the scrub. Defaults to 0; entity-specific
     *  containment constraints (e.g. "session.closed can't be
     *  earlier than session.opened") raise this so the scrub
     *  can't produce an invalid state. */
    min?: number;
    max: number;
    /** When true, `max` is a HARD ceiling — the scrub clamps to
     *  it and never extends. Used when the upper bound comes from
     *  a containment constraint (e.g. "session.closed can't be
     *  later than peerA.left"). When false (default), `max` is a
     *  soft hint and the scrub extends generously so the user can
     *  drag past the current doc duration and have the engine
     *  auto-extend duration to match. */
    strictMax?: boolean;
    onChange: (next: number) => void;
    label: string;
    /** Drag-session brackets forwarded to ScrubInput — see its
     *  contract; rows wrap them in an edit transaction so one scrub
     *  is one undo step. */
    onScrubStart?: (() => void) | undefined;
    onScrubEnd?: (() => void) | undefined;
    /** Forwarded to ScrubInput. Used by callers (OptionalTimeRow) to
     *  make the scrub fill its flex container so a sibling ✕ button
     *  is pushed to the right edge. */
    style?: React.CSSProperties;
  },
) {
  return (
    <ScrubInput
      value={value}
      onChange={onChange}
      min={Math.max(0, min)}
      max={strictMax ? max : Math.max(max, value * 1.5, 60_000)}
      format={formatTime}
      formatInput={formatTimeInput}
      parse={parseTime}
      label={label}
      linear
      // Linear sensitivity: 1px ≈ 10 ms by default. Shift slows to
      // ~1 ms/px (fine); alt speeds to ~100 ms/px (coarse).
      pxPerDoubling={0.1}
      {...(style ? { style } : {})}
      {...(onScrubStart ? { onScrubStart } : {})}
      {...(onScrubEnd ? { onScrubEnd } : {})}
    />
  );
}

/** Inline text field with the inspector's edit-session bracketing:
 * focus opens a labeled transaction so a typing burst lands as one
 * undo step; blur closes it. The one spelling of the editable-text
 * idiom — heading and mono variants come in via `style`. */
export function InlineTextField(
  {
    value,
    onChange,
    ariaLabel,
    editLabel,
    editSession,
    placeholder,
    style,
    submitOnEnter = false,
  }: {
    value: string;
    onChange: (next: string) => void;
    /** What this field edits, for anyone who cannot see the row label
     *  beside it. Required rather than defaulted, because the two
     *  strings this field already carries are the wrong ones to borrow:
     *  `editLabel` is a verb phrase written for the undo menu, and a
     *  placeholder is what an EMPTY field shows, so it disappears as a
     *  name exactly when the field has content. */
    ariaLabel: string;
    /** Undo label for the typing burst. */
    editLabel: string;
    editSession: EditSession | undefined;
    placeholder: string;
    style: React.CSSProperties;
    /** Treat the field as a one-line form: Enter finishes it.
     *
     *  Enter BLURS rather than committing directly, so there stays exactly one
     *  commit path. A second one would have to close the edit bracket itself, and
     *  the bracket is the thing that must not be closed twice — a field that
     *  committed on Enter and again on the blur Enter caused would bracket one
     *  edit as two.
     *
     *  Off by default. A field inside a panel that is already tracking an entity
     *  has no form to submit, and taking Enter there would swallow a key the
     *  surrounding UI may want. */
    submitOnEnter?: boolean;
  },
) {
  const bracket = useEditBracket(editSession);
  return (
    <input
      type="text"
      className="ocv-input"
      aria-label={ariaLabel}
      value={value}
      onChange={(ev) => onChange(ev.target.value)}
      onFocus={() => bracket.begin(editLabel)}
      onBlur={() => bracket.end()}
      onKeyDown={submitOnEnter
        ? (ev) => {
          if (ev.key === "Enter") ev.currentTarget.blur();
        }
        : undefined}
      placeholder={placeholder}
      spellCheck={false}
      style={style}
    />
  );
}

/** One coordinate scrub for the position row — `TimeScrubInput`'s
 * sibling, formatting plain numbers instead of times. Same
 * `ScrubInput` engine, same ROW_H lock via the forwarded style. */
function CoordScrubInput(
  { value, onChange, label, onScrubStart, onScrubEnd }: {
    value: number;
    onChange: (next: number) => void;
    label: string;
    onScrubStart?: (() => void) | undefined;
    onScrubEnd?: (() => void) | undefined;
  },
) {
  return (
    <ScrubInput
      value={value}
      onChange={onChange}
      {...(onScrubStart ? { onScrubStart } : {})}
      {...(onScrubEnd ? { onScrubEnd } : {})}
      min={-100_000}
      max={100_000}
      // Full-fidelity fact display; the typed-edit seed especially
      // must round-trip, or a focus-then-blur commits the rounding
      // into the pin and cold-recomputes the layout (`format.ts`).
      format={formatCoord}
      formatInput={formatCoord}
      label={label}
      linear
      // 1px of drag ≈ 1 world unit — the stage's own scale.
      pxPerDoubling={1}
      style={{ flex: 1, minWidth: 0 }}
    />
  );
}

// The coordinate pair is one flex item in a fixed-height row, so it has
// to be allowed to shrink; `valueMono` already clips and ellipsizes.
const positionValueStyle = {
  ...valueMono,
  flex: "0 1 auto",
} satisfies React.CSSProperties;

/** Inspector row for a peer's placement — the position sibling of
 * `OptionalTimeRow`, built from the same row idiom (ROW_H shell,
 * square ✕, opt-in button). Two states, narrated to the user as
 * WHO owns the position — "pinned" (the user authored it) vs
 * "auto" (the system places it automatically; mechanically, the
 * force layout). "auto" is the user word on purpose: "layout" is
 * the implementation's name for the mechanism, and a UI string
 * that needs codebase knowledge to parse is an insider word in
 * pixel space.
 *
 *   - pinned ⇒ x / y coordinate scrubs when editing (each write
 *     re-pins) plus the ✕ that unpins, returning the peer to
 *     automatic placement
 *   - auto ⇒ the current coordinates read-only with a square
 *     pin-glyph opt-in (editing only), the placement's mirror of
 *     "Insert @playhead"
 *
 * "Auto" stays a first-class state, exactly like "no end" on the
 * timing rows. */
export function PositionRow(
  {
    pinned,
    at,
    editing,
    onMove,
    onClear,
    onPinHere,
    editSession,
    noun = "peer",
  }: {
    /** The authored position, or null when the layout owns the
     *  peer's placement. */
    pinned: { x: number; y: number } | null;
    /** Where the peer sits right now (authored, or the layout's
     *  latest placement); null when it isn't on stage at all. */
    at: { x: number; y: number } | null;
    editing: boolean;
    onMove: ((pos: { x: number; y: number }) => void) | undefined;
    onClear: (() => void) | undefined;
    onPinHere: (() => void) | undefined;
    /** Edit-transaction brackets (`EditorBindings` subset) — a
     *  coordinate scrub becomes one undo step. Required so a call
     *  site cannot silently ship unbracketed scrubs; pass the
     *  editor (undefined outside Build). */
    editSession: EditSession | undefined;
    /** What the row is placing, for the strings a user reads. A session's
     *  unattributed end is placed the same way and is not a peer. */
    noun?: string;
  },
) {
  const session = useScrubSession(editSession, `Move ${noun}`);
  return (
    <Field label="position">
      <span style={endRowStyle}>
        {pinned && editing && onMove
          ? (
            <>
              <CoordScrubInput
                value={pinned.x}
                onChange={(x) => onMove({ x, y: pinned.y })}
                label={`${noun} x`}
                {...session}
              />
              <CoordScrubInput
                value={pinned.y}
                onChange={(y) => onMove({ x: pinned.x, y })}
                label={`${noun} y`}
                {...session}
              />
              {onClear && (
                <button
                  type="button"
                  className="ocv-btn is-icon"
                  onClick={onClear}
                  title={`Unpin — return this ${noun} to automatic placement`}
                  aria-label="Unpin position"
                  style={endRowIconButtonStyle}
                >
                  <ClearGlyph />
                </button>
              )}
            </>
          )
          : (
            <>
              <code style={positionValueStyle}>
                {at ? `${formatCoord(at.x)}, ${formatCoord(at.y)}` : "—"} {pinned ? "· pinned" : "· auto"}
              </code>
              {!pinned && editing && onPinHere && at && (
                <button
                  type="button"
                  className="ocv-btn is-icon"
                  onClick={onPinHere}
                  title="Pin at the current automatic position"
                  aria-label="Pin at the current automatic position"
                  style={endRowIconButtonStyle}
                >
                  <PinGlyph />
                </button>
              )}
            </>
          )}
      </span>
    </Field>
  );
}

/** Inspector row that represents an OPT-IN end time. Two states:
 *
 *   - end event exists ⇒ time value (or scrub input when editing)
 *     plus a ✕ button to clear back to "no end"
 *   - end event missing ⇒ "Set end at playhead" button (editing
 *     only); a plain "—" placeholder when not editing (so the
 *     reader knows the entity is open-ended, not that we're
 *     hiding data)
 *
 * "No end" stays a first-class state — every new entity starts
 * eternal and the user can opt in / out at any time.
 *
 * Optional `below` slot — the controls this row's own kind of moment
 * needs, on a second layout row under the time. Under, not beside:
 * the time field is the one control every timing row shares, so it
 * takes the whole value column on all of them and a reader finds it
 * in the same place on a peer's start, a session's duration, and a
 * trajectory moment alike. The row is still ONE field, so the
 * hairline runs under the pair rather than between them. */
/** The value cell of a trajectory row: what changed, and the value
 *  it took. The editor comes from the property's descriptor
 *  (`engine/trajectory.ts`) — a name is typed, an enum property
 *  picks from its options, an end picks the peer it attaches to and
 *  what backed that — so a new temporal property renders here
 *  without this component learning it. Read-only outside Build,
 *  where the row is still worth reading.
 *
 *  It sits on the row's second layout line, under the time that dates
 *  the moment, and takes the whole value column there. The editor
 *  keeps its own shrinkable box anyway: inline inputs are
 *  `width: 100%`, which in a flex row resolves against the content
 *  unless the box may shrink, and an end's pair of pickers is two of
 *  them sharing one line. */
export function TrajectoryValue(
  { property, value, editing, editSession, onChange, nameOfPeer }: {
    property: TrajectoryDisplay;
    /** What the property carries at this moment, in its own value
     *  channel: one word, or the pair an end attaches by. */
    value: SessionValue;
    editing: boolean;
    editSession: EditSession | undefined;
    onChange: (next: SessionValue) => void;
    /** What a person calls one of the peers this row can attach to.
     *
     *  Only the attachment editor asks, because it is the only row whose
     *  value is an entity rather than a word, and only a caller holding
     *  the document can answer. Left out, every peer reads as its own id,
     *  which is what `pickerLabels` says about a thing nobody named. */
    nameOfPeer?: (peerId: string) => string | undefined;
  },
) {
  const { noun, editor } = property;
  // The one word that names this value, for the controls and the readings
  // that show a single string. An end's pair answers with its peer.
  const named = typeof value === "string" ? value : value.peer;
  return (
    <span style={trajectoryValueStyle}>
      {
        /* The property's name is the row's label, not part of its
          value. `noun` names the control for a screen reader and
          fills the empty-field placeholder. */
      }
      <span style={trajectoryEditorStyle}>
        {editing && editor.kind === "text"
          ? (
            <InlineTextField
              value={named}
              onChange={onChange}
              ariaLabel={`New ${noun}`}
              editLabel={`Edit ${noun}`}
              editSession={editSession}
              placeholder={noun}
              style={inlineMonoInput}
            />
          )
          : editing && editor.kind === "enum"
          ? (
            <EnumSelect
              value={named}
              options={editor.options}
              ariaLabel={`New ${noun}`}
              onChange={onChange}
            />
          )
          : editing && editor.kind === "attachment"
          ? (
            <AttachmentEditor
              noun={noun}
              peers={editor.peers.map((id) => ({
                id,
                name: nameOfPeer?.(id),
              }))}
              attributions={editor.attributions}
              value={typeof value === "string" ? { peer: value } : value}
              onChange={onChange}
            />
          )
          : <code style={valueMono}>{named}</code>}
      </span>
    </span>
  );
}

/** The two controls one end's moment is: the peer it attaches to, and
 *  what backed that.
 *
 *  Both, because the value IS the pair. A row offering only the peer could
 *  not state what a signed handoff proved, and restating the peer rewrote a
 *  proven attachment as one nothing backed — so the recording held a shape
 *  Build could not author, and touching the row destroyed it.
 *
 *  The peer picker offers no "nobody": a moment ATTACHES an end, and an end
 *  comes loose by losing the moment or by being born loose, which is the
 *  session panel's row 0. The attribution picker does offer "nothing",
 *  because an author may attach an end having measured nothing, and that is
 *  what the one-way invariant allows. */
function AttachmentEditor(
  { noun, peers, attributions, value, onChange }: {
    noun: string;
    peers: readonly PickerOption[];
    attributions: readonly EndpointAttribution[];
    value: EndpointAttachment;
    onChange: (next: EndpointAttachment) => void;
  },
) {
  return (
    <span style={attachmentEditorStyle}>
      <span style={attachmentControlStyle}>
        <PeerSelect
          value={value.peer}
          peers={peers}
          ariaLabel={`New ${noun}`}
          onChange={(peer) => onChange(attachedTo(value, peer))}
        />
      </span>
      <span style={attachmentControlStyle}>
        <EnumSelect
          value={value.attributedBy ?? NONE}
          options={[NONE, ...attributions]}
          ariaLabel={`What attributed ${noun}`}
          labelFor={(v) => v === NONE ? NOTHING : v}
          onChange={(v) =>
            onChange(
              backedBy(
                value,
                v === NONE ? undefined : v as EndpointAttribution,
              ),
            )}
        />
      </span>
    </span>
  );
}

/** The pair's two selects share the cell and each may shrink, for the same
 *  reason the cell itself may: a select is `width: 100%`, which resolves
 *  against its own box, so two left to themselves each take the whole cell
 *  and the second lands outside the row. */
const attachmentEditorStyle: React.CSSProperties = {
  display: "flex",
  gap: SPACE.xs,
  minWidth: 0,
};

const attachmentControlStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
};

const trajectoryValueStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "flex-start",
  gap: SPACE.xs,
  minWidth: 0,
};

const trajectoryEditorStyle: React.CSSProperties = {
  flex: 1,
  minWidth: 0,
};

/** The "state another property here" control for a trajectory. One
 *  property is one button that names it; several are a menu, because
 *  a button per property turns into a wall of them as properties are
 *  added. The menu picks and inserts in one gesture and keeps no
 *  selection of its own — there is nothing to remember between
 *  insertions. */
export function TrajectoryInsert<P extends string>(
  { properties, describe, onInsert }: {
    properties: readonly P[];
    describe: (property: P) => TrajectoryDisplay;
    onInsert: (property: P) => void;
  },
) {
  const nounOf = (property: P) => describe(property).noun;
  const only = properties.length === 1 ? properties[0] : undefined;
  if (only !== undefined) {
    return (
      <button
        type="button"
        className="ocv-btn"
        onClick={() => onInsert(only)}
        title={`State a new ${nounOf(only)} at the playhead`}
        style={{ ...endRowButtonStyle, width: "100%" }}
      >
        + {nounOf(only)} @playhead
      </button>
    );
  }
  return (
    <select
      className="ocv-select"
      value=""
      aria-label="State a property at the playhead"
      style={inlineSelectInput}
      onChange={(e) => {
        const picked = e.target.value as P | "";
        if (picked !== "") onInsert(picked);
      }}
    >
      <option value="">+ state @playhead…</option>
      {properties.map((property) => <option key={property} value={property}>{nounOf(property)}</option>)}
    </select>
  );
}

export function OptionalTimeRow(
  {
    label,
    below,
    note,
    t,
    editing,
    onMove,
    onClear,
    onSetAtPlayhead,
    min,
    max,
    strictMax,
    scrubLabel,
    editSession,
  }: {
    label: string;
    below?: React.ReactNode;
    /** A remark about this time, such as the clamp hint. Rides inside
     *  the row, because it is about the row's value rather than a
     *  field of its own. */
    note?: React.ReactNode;
    /** Resolved value to display when the side is EXPLICIT on
     *  `entity.timing`. `null` means the side is implicit (eternal-
     *  start or eternal-end) — render the placeholder / set-at-
     *  playhead UI. Single source of truth: the entity's timing,
     *  not any observation. */
    t: number | null;
    editing: boolean;
    onMove: ((t: number) => void) | undefined;
    onClear: (() => void) | undefined;
    onSetAtPlayhead: (() => void) | undefined;
    min: number;
    max: number;
    strictMax: boolean;
    scrubLabel: string;
    /** Edit-transaction brackets (`EditorBindings` subset) — a time
     *  scrub becomes one undo step. Required so a call site cannot
     *  silently ship unbracketed scrubs; pass the editor
     *  (undefined outside Build). */
    editSession: EditSession | undefined;
  },
) {
  const session = useScrubSession(editSession, scrubLabel);
  return (
    <Field
      label={label}
      note={note}
      below={below && <div style={belowRowStyle(editing)}>{below}</div>}
    >
      <span style={endRowStyle}>
        {t !== null
          ? (
            <>
              {editing && onMove
                ? (
                  <span style={endRowScrubStyle}>
                    <TimeScrubInput
                      value={t}
                      min={min}
                      max={max}
                      strictMax={strictMax}
                      onChange={onMove}
                      label={scrubLabel}
                      {...session}
                      // Either way the wrapper grows and the input
                      // fills it, so the ✕ (if any) docks at the row's
                      // right edge and the digits are a target rather
                      // than a sliver.
                      style={{ width: "100%" }}
                    />
                  </span>
                )
                : <code style={valueMono}>{formatTime(t)}</code>}
              {editing && onClear && (
                <button
                  type="button"
                  className="ocv-btn is-icon"
                  onClick={onClear}
                  title={`Clear ${label} time`}
                  style={endRowIconButtonStyle}
                  aria-label={`Clear ${label} time`}
                >
                  <ClearGlyph />
                </button>
              )}
            </>
          )
          : editing && onSetAtPlayhead
          ? (
            <button
              type="button"
              className="ocv-btn"
              onClick={onSetAtPlayhead}
              title={`Set ${label} at the playhead`}
              style={{ ...endRowButtonStyle, flex: 1 }}
            >
              Insert @playhead
            </button>
          )
          : <span style={{ ...valueMono, color: c.textSubtle }}>—</span>}
      </span>
    </Field>
  );
}

/** Small ghost-text indicator rendered under a time row when the
 * user's stored intent has been clamped by an ancestor context.
 * Hides itself when stored equals effective — no noise when there's
 * nothing to surface. The `reason` names which parent clamped (e.g.
 * "peer alice", "session phone-speaker") — the side is already
 * implicit from which field the hint sits under.
 *
 * It is a row's `note` rather than a row of its own: a hairline
 * between a time and the sentence explaining that time would separate
 * the two things a reader has to read together. */
export function DivergenceHint(
  { reason }: { reason: string | null },
) {
  if (!reason) return null;
  return (
    <span
      style={{
        fontFamily: FONT.sans,
        color: c.textSubtle,
        fontSize: "0.85em",
        fontStyle: "italic",
      }}
      title={`This time is held inside ${reason}'s own span, so the value stored here cannot take effect until that span reaches it.`}
    >
      clamped by {reason}
    </span>
  );
}

/** Native `<select>` styled with `.ocv-select`. Was a segmented
 * control first, but the three pills overflowed the kv value
 * column at default pane width.
 *
 * The offer is `PROFILE_OPTIONS`, and a peer running something not on
 * it keeps showing what it runs — see `offeredWith`. */
export function ProfileSelect(
  { value, onChange }: {
    value: PeerProfile;
    onChange: (profile: PeerProfile) => void;
  },
) {
  return (
    <select
      className="ocv-select"
      value={value}
      onChange={(e) => onChange(e.target.value as PeerProfile)}
      aria-label="Peer profile"
      style={inlineSelectInput}
    >
      {offeredWith(PROFILE_OPTIONS, value).map((p) => <option key={p} value={p}>{p}</option>)}
    </select>
  );
}

export function Unknown(
  { kind, id }: { kind: "peer" | "session" | "message"; id: string },
) {
  return (
    <>
      {kind === "peer" && <PeerKindLabel profile="other" />}
      {kind === "session" && <SessionKindLabel codec="capnp" captpVersion="v1_0" />}
      {kind === "message" && <MessageKindLabel />}
      <div style={placeholder}>
        Unknown {kind} id: <Identifier value={id} />
      </div>
    </>
  );
}

/** One row in a Connections list: something on the left that names
 *  where the row goes, something on the right that says how it stands,
 *  and the whole row is the click target.
 *
 *  Every row in every one of those lists is this element. What each
 *  kind of row differs by is what it can honestly show — a peer has a
 *  profile swatch, an unattributed end has a claim and no swatch, a
 *  session has a state — so a kind is a pair of slots, not a second
 *  spelling of a row. The three below used to spread one style object
 *  and patch it with the same selected-overlay each, which meant the
 *  row's shape lived in four places and its hover in a fifth.
 *
 *  The chrome is `.ocv-session-row` in styles.css, all of it: nothing
 *  here sets a border, a surface or a corner, because an inline value
 *  would beat the hover rule and freeze it. */
function LinkRow(
  { selected, onClick, left, meta }: {
    /** "This row's target is also in the user's entitySelection."
     *  Tints the row and leads its right-hand cell with a badge, so the
     *  membership reads without leaning entirely on color. */
    selected: boolean | undefined;
    onClick: () => void;
    /** What the row names. */
    left: React.ReactNode;
    /** How it stands: a chip, or a plain word. */
    meta: React.ReactNode;
  },
) {
  return (
    <button
      type="button"
      className={selected ? "ocv-session-row is-active" : "ocv-session-row"}
      onClick={onClick}
    >
      <span style={linkRowLeft}>{left}</span>
      <span style={linkRowMetaCell}>
        {selected && <span style={linkRowSelectedBadge}>in selection</span>}
        {meta}
      </span>
    </button>
  );
}

export function PeerLinkRow(
  { peerLabel, peerProfile, lifecycle, selected, onClick }: {
    peerLabel: string;
    peerProfile: string;
    /** When provided AND not "active", paints the lifecycle chip
     * in place of the plain profile meta — so the user sees
     * "not yet joined" / "left" without losing the row. Omit or
     * pass "active" for the default profile-only meta. */
    lifecycle?: LifecycleStatus;
    /** "This row's target peer is also in the user's
     *  entitySelection." Toggles a tinted background + accent
     *  border + leading "in selection" badge. */
    selected?: boolean;
    onClick: () => void;
  },
) {
  const showLifecycle = lifecycle !== undefined && lifecycle !== "active";
  return (
    <LinkRow
      selected={selected}
      onClick={onClick}
      left={
        <>
          <PeerSwatch profile={peerProfile} />
          <span style={linkRowName} title={peerLabel}>{peerLabel}</span>
        </>
      }
      meta={showLifecycle
        ? <LifecycleChip status={lifecycle!} entity="peer" />
        : <span style={linkRowMeta}>{peerProfile}</span>}
    />
  );
}

/** Claim row link — the loose-end sibling of `PeerLinkRow`, and
 *  deliberately the same shape: a session's two ends are two rows in
 *  one list, and a reader should reach either the same way. It selects
 *  the placeholder the stage draws, so the row and the node are the
 *  same act from two places.
 *
 *  What differs is what it can honestly show. There is no swatch,
 *  because a profile is something a peer has and this end has not been
 *  attributed to one. The name is the claim, in the mono face every
 *  unproven string wears here, and the meta says plainly that no peer
 *  is on this end. */
export function ClaimLinkRow(
  { claim, selected, onClick }: {
    /** What this end says it is, or undefined when it named nothing. */
    claim?: string | undefined;
    selected?: boolean;
    onClick: () => void;
  },
) {
  return (
    <LinkRow
      selected={selected}
      onClick={onClick}
      left={claim === undefined
        ? <span style={linkRowName}>{UNNAMED_END_LABEL}</span>
        : <Identifier value={claim} style={{ fontWeight: WEIGHT.semibold }} />}
      meta={<span style={linkRowMeta}>unattached</span>}
    />
  );
}

/** Session row link — extracted from `PeerConnections` and
 *  `MessageConnections.Carried over` so both surfaces share one
 *  shape. The right-side meta is either the live `state` chip
 *  (active session) or a `LifecycleChip` (off-stage / before /
 *  after). The `selected` prop applies the same multi-select
 *  highlight as `PeerLinkRow`. */
export function SessionLinkRow(
  {
    codec,
    captpVersion,
    name,
    state,
    lifecycle,
    selected,
    onClick,
  }: {
    codec: Codec;
    captpVersion: CaptpVersion;
    name: string;
    state: SessionState;
    lifecycle: LifecycleStatus;
    selected?: boolean;
    onClick: () => void;
  },
) {
  return (
    <LinkRow
      selected={selected}
      onClick={onClick}
      left={
        <>
          <SessionSwatch codec={codec} captpVersion={captpVersion} />
          <span style={linkRowName} title={name}>{name}</span>
        </>
      }
      meta={lifecycle === "active"
        ? <StateChip state={state} />
        : <LifecycleChip status={lifecycle} entity="session" />}
    />
  );
}
