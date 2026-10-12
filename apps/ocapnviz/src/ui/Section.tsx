import { c, FONT, SIZE, SPACE, WEIGHT } from "./tokens.ts";

const wrap = {
	display: "flex",
	flexDirection: "column",
} satisfies React.CSSProperties;

const title = {
	fontFamily: FONT.sans,
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	letterSpacing: 0.6,
	textTransform: "uppercase",
	color: c.textSubtle,
	paddingInline: SPACE.md,
	paddingTop: SPACE.md,
	paddingBottom: SPACE.sm,
	// A row so a section can put one control at the far end of its own heading.
	// With nothing there this is a row of one, which lays out as the block it
	// replaced.
	display: "flex",
	alignItems: "center",
	justifyContent: "space-between",
	gap: SPACE.sm,
} satisfies React.CSSProperties;

/**
 * The control at the end of a heading, on its center line and adding nothing to
 * its height.
 *
 * A heading is one line of small-caps and an icon button is a 20px square, so a
 * row holding both would be as tall as the button, and every section with an
 * action would sit a little lower than its neighbours. A box with no height of its
 * own contributes nothing to the row and centers its button on the line, so the
 * button hangs into the padding the heading already has above and below its text.
 *
 * Nothing here needs to know how tall either one is, which is the point: a pinned
 * line box or a measured margin would be two numbers that have to keep agreeing
 * with the font and the control height, and this way there are none.
 */
const titleAction = {
	height: 0,
	display: "flex",
	alignItems: "center",
} satisfies React.CSSProperties;

const body = {
	display: "flex",
	flexDirection: "column",
	gap: SPACE.md,
	paddingInline: SPACE.md,
	paddingBottom: SPACE.md,
	// Let flex children shrink below their intrinsic content width.
	// Without this, a wide child (e.g. a <select> sized to its widest
	// <option>) refuses to compress and the parent pane develops a
	// horizontal scroll seam at narrow widths.
	minWidth: 0,
} satisfies React.CSSProperties;

/** Body padding when the title is absent. The title's own
 *  `paddingTop` normally seeds the top edge of the section, so
 *  untitled sections need to take that over themselves to keep
 *  the same vertical rhythm as their titled siblings. */
const untitledBody = {
	...body,
	paddingTop: SPACE.md,
} satisfies React.CSSProperties;

/**
 * A titled block within a side pane. Sections in the same pane are
 * separated by a hairline rule (applied via CSS sibling selector in
 * styles.css `.ocv-pane > section + section`), so the first section
 * has no top border. `title` is optional: the Inspector's Details
 * section omits it because the selected entity's heading (e.g.
 * `alice ↔ carol`) already labels the pane. A "DETAILS" header
 * above the entity name was just visual noise, and the body's
 * own `FieldGroup` titles ("Details" / "Timing") still carry
 * the same vocabulary further down.
 *
 * `action` is one control about the whole section, sitting at the far end of its
 * heading. About the section rather than in it: the Legend's is the way to the
 * Reference, which explains every word in the swatch table under it and is not a
 * row of that table. A full-width button in the body claimed as much room as the
 * content it was a footnote to.
 */
export function Section(
	{ title: heading, action, children }: {
		title?: string;
		/** Expected to be one icon button. Anything taller than the heading's line
		 *  will hang into its padding rather than push the heading down. */
		action?: React.ReactNode;
		children: React.ReactNode;
	},
) {
	return (
		<section style={wrap}>
			{heading && (
				<div style={title}>
					<span>{heading}</span>
					{action !== undefined && action !== null && <span style={titleAction}>{action}</span>}
				</div>
			)}
			<div style={heading ? body : untitledBody}>{children}</div>
		</section>
	);
}
