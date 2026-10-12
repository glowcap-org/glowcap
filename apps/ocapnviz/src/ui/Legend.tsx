import {
	CAPTP_VERSION_COLORS,
	type CodecLineStyle,
	lineStyleForCodec,
	MESSAGE_IN_FLIGHT_COLOR,
	PROFILE_COLORS,
	PROFILE_FALLBACK_COLOR,
	SESSION_STATE_WIDTH,
} from "../render/palette.ts";
import {
	CAPTP_VERSION_REFERENCE_OPTIONS,
	captpVersionLabel,
	CODEC_REFERENCE_OPTIONS,
	UNNAMED_PROFILE,
} from "../schema/topology.ts";
import { endpointSwatchStyle, NEUTRAL_BODY_COLOR, peerBodySwatchStyle } from "./EntityChips.tsx";
import { HelpGlyph } from "./glyphs.tsx";
import { c, FONT, PANEL, RADIUS, SIZE, SPACE, WEIGHT } from "./tokens.ts";

// Layout class lives in styles.css (`.ocv-legend-grid`) so it can
// use container queries to switch from 1-column to 2-column when
// the pane is wide enough, keeps Legend in lockstep with the
// Layers panel above it.

const group = {
	...PANEL,
	display: "flex",
	flexDirection: "column",
	gap: 4,
} satisfies React.CSSProperties;

// A caption, not an eyebrow: "Profile · node color" is a sentence
// about an encoding rather than the name of a block, and it is too long
// to survive uppercase tracking in a pane this narrow, every second
// one wrapped to two lines, which costs more than the treatment buys.
// So it stays sentence case and separates from the rows it labels by
// weight and color instead of by size.
const groupLabel = {
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	color: c.textMuted,
	marginBottom: SPACE.xs,
} satisfies React.CSSProperties;

const rowsGrid = {
	display: "grid",
	gridTemplateColumns: "32px 1fr",
	alignItems: "center",
	rowGap: 4,
	columnGap: SPACE.sm,
} satisfies React.CSSProperties;

const swatchCell = {
	display: "flex",
	alignItems: "center",
	justifyContent: "center",
	height: 14,
} satisfies React.CSSProperties;

// Sans and mono rows share `SIZE.xs`, knowingly against the rule that
// mono drops a notch: these labels are sentences, and a notch up wraps
// them. The mono token reads a shade larger as a result.
const labelText = {
	fontSize: SIZE.xs,
	color: c.text,
} satisfies React.CSSProperties;

const tokenStyle = {
	fontFamily: FONT.mono,
	fontSize: SIZE.xs,
	color: c.text,
} satisfies React.CSSProperties;

const swatch = (color: number) =>
	({
		width: 14,
		height: 14,
		borderRadius: RADIUS.sm,
		background: hex(color),
		boxShadow: `inset 0 0 0 1px ${c.borderStrong}`,
	}) satisfies React.CSSProperties;

const lineSwatch = (
	color: number | string,
	width: number,
	style: CodecLineStyle,
) => ({
	width: 28,
	height: 0,
	borderTop: `${width}px ${style} ${typeof color === "number" ? hex(color) : color}`,
}) satisfies React.CSSProperties;

function hex(color: number): string {
	return `#${color.toString(16).padStart(6, "0")}`;
}

/** Legend body, slotted into a `<Section title="Legend">`.
 *
 * Each group is one mapping, titled `property · visual channel` and holding
 * one row per value that property takes. The order is fixed across the set:
 * the thing being encoded first, the channel encoding it second. A title that
 * leads with the channel has nowhere left to name the property, and the
 * property then migrates into the rows and grows into prose, which is how a
 * legend entry becomes a sentence.
 *
 * Color lives in the swatches so the chrome stays neutral.
 *
 * What a value MEANS is the Reference's job, and the question mark in this
 * section's heading is the door to it (`LegendReferenceButton` below). Keeping the
 * two apart is what lets this stay a key a reader can take in at a glance while
 * every word still has a full explanation somewhere. */
export function LegendBody() {
	return (
		<>
			<div className="ocv-legend-grid">
				<Group label="Profile · node color">
					{Object.entries(PROFILE_COLORS).map(([profile, color]) => (
						<Row
							key={profile}
							swatch={swatch(color)}
							label={profile}
							token
						/>
					))}
					<Row
						swatch={swatch(PROFILE_FALLBACK_COLOR)}
						label={UNNAMED_PROFILE}
						token
					/>
				</Group>

				{
					/* Two rows, because the fact here is a contrast and one row cannot
          teach one. Both swatches carry the same color: what separates them
          is the fill and the edge, which is exactly what the stage varies,
          and holding the color still keeps this row from reading as a second
          lesson about profile color.

          The title is the Inspector's own field label, and the two rows are
          its two values, so a reader meets one phrasing whichever surface
          they came from. It is not "session end": that names the thing being
          drawn rather than the property being encoded, and the rest of this
          legend names properties. */
				}
				<Group label="Attached to · node body">
					<Row
						swatch={peerBodySwatchStyle(NEUTRAL_BODY_COLOR, 14)}
						label="a peer"
					/>
					<Row swatch={endpointSwatchStyle(14)} label="nobody" />
				</Group>

				<Group label="Codec · line style">
					{CODEC_REFERENCE_OPTIONS.map((codec) => (
						<Row
							key={codec}
							swatch={lineSwatch(
								c.text,
								3,
								lineStyleForCodec(codec),
							)}
							label={codec}
							token
						/>
					))}
				</Group>

				<Group label="CapTP version · line color">
					{CAPTP_VERSION_REFERENCE_OPTIONS.map((version) => (
						<Row
							key={version}
							swatch={lineSwatch(
								CAPTP_VERSION_COLORS[version],
								3,
								"solid",
							)}
							label={captpVersionLabel(version)}
							token
						/>
					))}
				</Group>

				<Group label="Session state · line thickness">
					{Object.entries(SESSION_STATE_WIDTH).map((
						[state, width],
					) => (
						<Row
							key={state}
							swatch={lineSwatch(c.textMuted, width, "solid")}
							label={state}
							token
						/>
					))}
				</Group>

				{
					/* Stated as the same property-and-channel pair as its siblings rather
          than as a category of its own. A category header among five mappings
          is the one entry a reader has to stop and parse, and the mapping was
          there all along: a message is drawn as a dot, and the value the dot
          carries is the state it is in. */
				}
				<Group label="Message · dot">
					<Row
						swatch={swatch(MESSAGE_IN_FLIGHT_COLOR)}
						label="in flight"
					/>
				</Group>
			</div>
		</>
	);
}

/**
 * The way from the Legend to the Reference, as one glyph.
 *
 * It goes in the section's heading (`Section`'s `action`), because what it opens
 * explains every word in the table below rather than adding a row to it. As a
 * full-width button under the swatches it took as much room as a whole mapping
 * and read as one.
 *
 * The same question mark the Reference titles itself with, so the button and what
 * it opens are visibly one thing.
 */
export function LegendReferenceButton(
	{ onOpen }: { onOpen: () => void },
) {
	return (
		<button
			type="button"
			className="ocv-btn is-ghost is-icon"
			onClick={onOpen}
			title="What these words mean — open the Reference"
			aria-label="What these words mean"
		>
			<HelpGlyph />
		</button>
	);
}

function Group(
	{ label, children }: { label: string; children: React.ReactNode },
) {
	return (
		<div style={group}>
			<div style={groupLabel}>{label}</div>
			<div style={rowsGrid}>{children}</div>
		</div>
	);
}

function Row(
	{ swatch, label, token = false }: {
		swatch: React.CSSProperties;
		label: string;
		token?: boolean;
	},
) {
	return (
		<>
			<span style={swatchCell}>
				<span style={swatch} />
			</span>
			<span style={token ? tokenStyle : labelText}>{label}</span>
		</>
	);
}
