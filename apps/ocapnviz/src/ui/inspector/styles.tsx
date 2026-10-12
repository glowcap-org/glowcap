/**
 * Inspector layout and type styles. One vocabulary for every panel
 * so a key column, a value face, and a row height cannot drift.
 */

import type { CSSProperties, ReactNode } from "react";
import { c, CONTROL, FONT, PANEL, SIZE, SPACE, WEIGHT } from "../tokens.ts";

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
} satisfies CSSProperties;

const heading = {
	fontWeight: WEIGHT.semibold,
	fontSize: SIZE.lg,
	color: c.text,
	lineHeight: 1.3,
	letterSpacing: -0.01,
	...headingClamp,
} satisfies CSSProperties;

const headingMono = {
	...heading,
	fontFamily: FONT.mono,
	fontSize: SIZE.base,
	letterSpacing: 0,
} satisfies CSSProperties;

/** The heading every entity panel opens with: the name of the thing the
 *  reader just selected.
 *
 *  `mono` picks the face. A name a person chose reads in the sans face
 *  the rest of the chrome uses. A string the network chose reads in the
 *  mono face every unproven token wears here.
 *
 *  `title` is what a reader gets on hover, which matters because the
 *  heading clips: pass the whole name even when the children are already
 *  elided. */
export function PanelHeading(
	{ title, mono, children }: {
		title: string;
		mono?: boolean;
		children: ReactNode;
	},
) {
	return <div style={mono ? headingMono : heading} title={title}>{children}</div>;
}

export const placeholder = {
	color: c.textSubtle,
	fontSize: SIZE.sm,
	lineHeight: 1.55,
} satisfies CSSProperties;

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
// alignment. A wrap is a defect somebody sees, and a group half a
// character out of step is not.
const KEY_COL_W = 78;

export const kv = {
	display: "grid",
	gridTemplateColumns: `${KEY_COL_W}px minmax(0, 1fr)`,
	rowGap: SPACE.xs + 1,
	columnGap: SPACE.md,
	fontSize: SIZE.sm,
} satisfies CSSProperties;

// The value half of a field row.
//
// A column, so each thing in it is block-level. That is not decoration:
// before this wrapper existed every value was a grid item, and a grid
// item is blockified, which is what makes `overflow: hidden` and an
// ellipsis work on a sixty-four character name. Left as inline content
// in a plain block, the same span stops clipping and takes the panel's
// right edge with it.
export const fieldValueStyle = {
	minWidth: 0,
	display: "flex",
	flexDirection: "column",
	alignItems: "stretch",
} satisfies CSSProperties;

// One layout line of a value, and the panel's vertical rhythm.
//
// A field row must not be as tall as whatever it happens to hold: one
// control's worth where the value was a control, one line of text where
// it was text. That reads as uneven padding under the last row of a
// panel, because what the eye measures is the gap to the ink, not the
// gap to the box.
//
// So a line is a control's height whatever is in it, and its content
// centers. A bare word and a 22px control then put their ink on the
// same pixel, which is also what stops the whole panel shifting when
// the same entity is read in Build and in Play.
export const fieldLineStyle = {
	minHeight: CONTROL.height,
	display: "flex",
	alignItems: "center",
	minWidth: 0,
} satisfies CSSProperties;

// A note under a value. The clamp hint, today. Its own block so it
// starts a line of its own whatever the value above it was.
export const fieldNoteStyle = {
	marginTop: 2,
	minWidth: 0,
} satisfies CSSProperties;

/** Inner box of a labeled field group. The actual recessed
 *  rectangle. Title sits OUTSIDE / above the box (see
 *  `FieldGroup`). The box itself only holds the kv content so
 *  the title doesn't compete with the field rows for visual
 *  weight. */
export const fieldGroupBox = PANEL;

/** Stack a `groupTitle` label above the `fieldGroupBox`. Same
 *  idiom as `subSection` / `subSectionLabel` further down the
 *  Inspector, gives the panel one consistent shape: small-caps
 *  label, then recessed content block. */
export const fieldGroup = {
	display: "flex",
	flexDirection: "column",
	gap: SPACE.xs,
} satisfies CSSProperties;

/** The one small-caps heading in the Inspector: a tracked, uppercase
 * eyebrow at the eyebrow size, over a block of content. Both the
 * sub-section titles and the field-group titles are this. */
export const subSectionLabel = {
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	letterSpacing: 0.6,
	textTransform: "uppercase",
	color: c.textSubtle,
} satisfies CSSProperties;

/** Small-caps header sitting above a `fieldGroupBox`. It IS
 * `subSectionLabel`, one visual rhythm in the Inspector, "stacked
 * rectangles, each with its own title", inset by the box's own padding
 * so the title lines up with the field keys under it. Two spellings of
 * that typography is how a panel comes to have two sizes of heading. */
export const groupTitle = {
	...subSectionLabel,
	paddingLeft: SPACE.xs,
} satisfies CSSProperties;

export const keyStyle = {
	color: c.textSubtle,
	fontWeight: WEIGHT.medium,
	fontFamily: FONT.sans,
	fontSize: SIZE.xs,
	letterSpacing: 0.4,
	textTransform: "uppercase",
} satisfies CSSProperties;

// Mono renders visually larger than sans at the same px, so mono
// values drop one notch on the SIZE scale to stay proportional in
// mixed key/value rows.
//
// This is the face for a SHORT token: a codec, a side letter, a time. A
// long opaque string goes through `Identifier` instead, which elides its
// middle and keeps the whole value on hover. The clamp here is the
// backstop for a value that turns out longer than its author expected,
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
} satisfies CSSProperties;

// A value that is a sentence rather than a token, an explanation
// the reader needs in words. Sits beside `valueMono` in the same
// key/value grid, so it wraps and reads as prose while mono values
// stay tabular.
export const valueText = {
	color: c.textMuted,
	fontSize: SIZE.xs,
	lineHeight: 1.5,
} satisfies CSSProperties;

// A value that is a name a person chose, such as a peer's label. Sans
// face because it is a word rather than a token, and clipped at its end
// because a name reads left to right. The head is the part that
// identifies it. An opaque string goes to `Identifier` instead, which
// keeps both ends.
export const valueName = {
	color: c.text,
	fontSize: SIZE.sm,
	overflow: "hidden",
	textOverflow: "ellipsis",
	whiteSpace: "nowrap",
	minWidth: 0,
} satisfies CSSProperties;

// Inline editable inputs used by the entity panels in build mode.
// Shapes echo the static `heading` / mono-value styles so the
// display ↔ edit transition doesn't shift the panel.
//
// Only typography. The box, corner, inset, surface, bevel, hover,
// focus, is `.ocv-input`'s in controls.css, and an inline copy of any of
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
} satisfies CSSProperties;

export const inlineMonoInput = {
	width: "100%",
	fontFamily: FONT.mono,
	fontSize: SIZE.sm,
} satisfies CSSProperties;

// Inspector enum-field `<select>`. Only overrides the kv-grid
// geometry, chevron, surface fill, hover, focus all live in
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
	// chevron room included, and an inline value beats the class, which is how
	// a dropdown came to sit its text 6px in beside a top-bar one at 10px. Same
	// height, different rhythm, which is what reads as inconsistent.
} satisfies CSSProperties;

export const subSection = {
	display: "flex",
	flexDirection: "column",
	gap: SPACE.sm,
} satisfies CSSProperties;

export const linkRowList = {
	display: "flex",
	flexDirection: "column",
	gap: SPACE.xs,
} satisfies CSSProperties;

// Selection-membership badge, small uppercase tag rendered to the
// LEFT of the row's right-side meta. The visual signal "this is
// also in your selection" without leaning entirely on color.
export const linkRowSelectedBadge = {
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	letterSpacing: 0.6,
	textTransform: "uppercase",
	color: c.accent,
	marginRight: SPACE.xs,
	whiteSpace: "nowrap",
	flexShrink: 0,
} satisfies CSSProperties;

export const linkRowLeft = {
	display: "flex",
	alignItems: "center",
	gap: SPACE.sm,
	minWidth: 0,
} satisfies CSSProperties;

export const linkRowName = {
	fontWeight: WEIGHT.semibold,
	whiteSpace: "nowrap",
	overflow: "hidden",
	textOverflow: "ellipsis",
	minWidth: 0,
} satisfies CSSProperties;

/** The right-hand cell of a link row, holding whatever badge the row
 *  ends with.
 *
 *  It does not shrink. A row has one thing that gives way when the panel
 *  narrows and it is the name on the left, which ellipsizes. A status
 *  badge is two or three words that mean nothing broken apart, and left
 *  to shrink it wraps and takes the row's height with it. "Not yet
 *  joined" set three lines tall beside a one-line name is what this
 *  cell exists to prevent. */
export const linkRowMetaCell = {
	display: "inline-flex",
	alignItems: "center",
	flexShrink: 0,
	maxWidth: "100%",
} satisfies CSSProperties;

// The plain-text end of a link row, where a chip is not what the row
// has to say. Same rule as a chip: one line, and the name on the left
// gives way first.
export const linkRowMeta = {
	fontFamily: FONT.mono,
	fontSize: SIZE.xs,
	color: c.textSubtle,
	letterSpacing: 0.02,
	whiteSpace: "nowrap",
} satisfies CSSProperties;

// Single source of truth for the optional-time row height. Every cell
// in the row (scrub input, ✕, "Insert @playhead") locks to this value
// so heights match exactly and the ✕ can be a true square by mirroring
// the height into its width. Reads the one control height rather than
// restating it: this row is not "22 tall", it is "as tall as every other
// control", and a second spelling of that is how they drift apart.
export const ROW_H = CONTROL.height;

// A time and the controls docked beside it. No height of its own: the
// field's line owns the row's rhythm, so a time row stands as tall as every
// other read-only row in the panel.
export const endRowStyle = {
	display: "flex",
	alignItems: "center",
	gap: SPACE.xs,
	minWidth: 0,
	flex: 1,
} satisfies CSSProperties;

export function belowRowStyle(editing: boolean): CSSProperties {
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
} satisfies CSSProperties;

// A worded button in one of these rows, "Insert @playhead" and its
// siblings. It holds its width against the scrub input beside it and
// reads at the panel's size rather than the chrome's; the box is
// `.ocv-btn`'s.
export const endRowButtonStyle = {
	flex: "0 0 auto",
	fontFamily: FONT.sans,
	fontSize: SIZE.sm,
} satisfies CSSProperties;

// The ✕ / pin that ends one of these rows. Square is `.ocv-btn.is-icon`
// at the call site, the same square the top bar's icon buttons take,
// and all this adds is the push that docks it against the row's right
// edge. It does not spell the square itself, which would be a second answer to
// "how big is an icon button".
//
// The bordered face, not the ghost one. Ghost belongs to the top bar,
// where a row of glyphs sits on chrome; in a pane of labels and values a
// borderless control reads as part of the value it sits beside rather
// than as something to press. The document panel's Opens-at row wears
// the same pair for the same reason.
export const endRowIconButtonStyle = {
	marginLeft: "auto",
} satisfies CSSProperties;
