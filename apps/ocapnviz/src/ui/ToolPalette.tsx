/**
 * Tool affordances — the compact tool strip in the left pane and
 * the routing to the App reducer's `set-tool` dispatch. Rendered in
 * every mode: which tools appear comes from `toolsForMode` (the
 * same authority the reducer enforces), so the strip can never
 * offer a tool the reducer would refuse. The tool's behavior on
 * actual canvas clicks lives in `Stage` + `useStageBuildGestures` +
 * `builder/two-click.advanceTwoClick`.
 */

import { SIZE } from "./tokens.ts";
import { type AppMode, type BuilderTool, toolsForMode } from "../state/app-state.ts";
import { AddPeerGlyph, HandGlyph, OpenSessionGlyph, SelectGlyph, SendMessageGlyph } from "./glyphs.tsx";

/** Per-tool display facts. Order here is display order.
 *
 * Two grammars, one per column, and each holds across the set. A label is a
 * verb phrase naming the tool in sentence case. A tip is an imperative saying
 * what to click, then the shortcut key in brackets. Every surface that names
 * a tool reads this table, so the options bar and the palette cannot come to
 * spell one tool two ways. */
const TOOL_FACTS: {
	id: BuilderTool;
	label: string;
	hint: string;
	glyph: React.ReactNode;
}[] = [
	{
		id: "select",
		label: "Select",
		hint: "Click to inspect, drag to move (V)",
		glyph: <SelectGlyph />,
	},
	{
		id: "hand",
		label: "Hand",
		hint: "Drag to pan, or hold Space (H)",
		glyph: <HandGlyph />,
	},
	{
		id: "add-peer",
		label: "Add peer",
		hint: "Click empty canvas to place a peer (P)",
		glyph: <AddPeerGlyph />,
	},
	{
		id: "open-session",
		label: "Open session",
		hint: "Click two peers, or a peer then empty canvas (S)",
		glyph: <OpenSessionGlyph />,
	},
	{
		id: "send-message",
		label: "Send message",
		hint: "Click the sender, then the receiver (M)",
		glyph: <SendMessageGlyph />,
	},
];

/** What to call a tool, wherever it is named. One lookup rather than a second
 *  switch beside the table: the options bar spelled these in title case while
 *  the palette spelled them in sentence case, which is what two homes for one
 *  string does. */
export function toolLabel(tool: BuilderTool): string {
	return TOOL_FACTS.find((t) => t.id === tool)?.label ?? tool;
}

/** Left-rail tool strip. Compact icon-only buttons that wrap under
 * panel resize; each button's tooltip carries the label, what the
 * tool does, and its shortcut key. */
export function ToolPalette(
	{ mode, tool, onPick }: {
		mode: AppMode;
		tool: BuilderTool;
		onPick: (tool: BuilderTool) => void;
	},
) {
	const available = toolsForMode(mode);
	return (
		<div
			role="radiogroup"
			aria-label="Tool"
			style={paletteRow}
		>
			{TOOL_FACTS.filter((t) => available.includes(t.id)).map((t) => (
				<button
					key={t.id}
					type="button"
					role="radio"
					aria-checked={tool === t.id}
					aria-label={t.label}
					className={`ocv-btn is-icon${tool === t.id ? " is-active" : ""}`}
					onClick={() => onPick(t.id)}
					title={`${t.label} — ${t.hint}`}
					style={paletteButton}
				>
					{t.glyph}
				</button>
			))}
		</div>
	);
}

const paletteRow = {
	// Icon-only squares in a wrapping row: five tools fit one row at
	// the default pane width, and a narrow pane wraps instead of
	// clipping (the pane's resize handle owns the width).
	display: "flex",
	flexWrap: "wrap",
	gap: 2,
	// Centered, because the strip is the one row of its panel that does not fill
	// the width. The commands under it each take an equal share and reach both
	// edges, so a short row of squares left-aligned under them read as a row that
	// had run out rather than as a set of its own. Two tools in Play and five in
	// Build then sit in the same place instead of the strip's weight moving.
	justifyContent: "center",
} satisfies React.CSSProperties;

// Geometry comes from `.ocv-btn.is-icon` — the same square the top
// bar's icon buttons take, so the left rail and the header read as one
// app. All that is left here is this palette's own type size.
const paletteButton = {
	fontSize: SIZE.sm,
} satisfies React.CSSProperties;

// Gesture-flow feedback lives elsewhere: `ToolHint` (the floating
// context banner, build mode) says what the armed tool expects
// next, the ToolOptionsBar carries per-tool option fields, and
// each palette button's tooltip carries the label + shortcut.
// Pan affordances are signaled by the cursor change to `grab`,
// the Adobe convention.
