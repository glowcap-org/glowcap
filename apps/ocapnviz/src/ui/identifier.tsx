/**
 * How an opaque identifier is shown.
 *
 * A designator, a peer id, a session id, a swissnum: strings the network
 * chose rather than a person, often sixty-four characters of hex, and none
 * of them a word. They are why the Inspector's panels ran off their own
 * right edge, and this module is the one place that decides what to do
 * about it.
 *
 * The middle is what goes. A reader has two jobs with an opaque
 * identifier: recognize one they have seen before, and tell two of them
 * apart. Both ends serve both jobs and either end alone serves neither,
 * because two keys that share a prefix read as the same key once the tail
 * is cut, and the same trap waits at the other end. Keeping a few
 * characters at each end is what git short shas and key fingerprints
 * settled on, for this reason.
 *
 * The whole value stays one hover away, in the element's title.
 *
 * A name a person chose is a different thing and gets the different
 * treatment it deserves. Names read left to right, so a long one is
 * clipped at its end by the row that holds it, never cut in the middle.
 * `Identifier` is for the strings nobody chose.
 */

import { c, FONT, SIZE } from "./tokens.ts";
import { elideIdentifier } from "./elide.ts";

// The shortening itself lives in `./elide.ts`, which the stage reads too:
// the label a node wears has to be measured by the layout before any DOM
// exists. Re-exported here so a panel that wants the text and the component
// still has one import.
export { elideIdentifier, IDENTIFIER_ELIDE_ABOVE, IDENTIFIER_END_CHARS } from "./elide.ts";

/** The elided text plus the clamp that keeps it inside its cell however
 *  narrow the panel gets. Two defenses rather than one: the elision is
 *  what a reader can act on, and the clamp is what the layout can rely
 *  on. */
const identifierStyle = {
	color: c.text,
	fontFamily: FONT.mono,
	fontSize: SIZE.xs,
	fontVariantNumeric: "tabular-nums",
	// `inline-block` so the clamp below applies in a sentence as well as in
	// a grid cell; `bottom` alignment keeps a clipped box sitting on the
	// line rather than hanging below it.
	display: "inline-block",
	verticalAlign: "bottom",
	maxWidth: "100%",
	minWidth: 0,
	overflow: "hidden",
	textOverflow: "ellipsis",
	whiteSpace: "nowrap",
} satisfies React.CSSProperties;

/**
 * One opaque identifier, elided in the middle and carrying the whole
 * value as its hover text.
 *
 * Every place the Inspector shows a designator, a peer id, a session id,
 * or a swissnum goes through here, so the treatment is decided once
 * rather than remembered at each row.
 */
export function Identifier(
	{ value, style }: {
		value: string;
		/** Layout the surrounding row needs, such as the weight a link row
		 *  gives its title cell. Typography and the clamp are this module's
		 *  and are not meant to be overridden. */
		style?: React.CSSProperties | undefined;
	},
) {
	return (
		<code
			style={style ? { ...identifierStyle, ...style } : identifierStyle}
			title={value}
		>
			{elideIdentifier(value)}
		</code>
	);
}
