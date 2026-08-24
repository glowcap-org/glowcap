/**
 * The ocapnviz grid shell: pointer-events contract and pane chrome.
 *
 * The unified canvas sits under a transparent grid. Empty center-pane
 * area passes events through; every opaque panel claims them back.
 * AppView and the rails own what goes in each pane.
 */

import type { CSSProperties } from "react";
import type { LayoutSizes } from "../state/app-state.ts";
import { TOP_BAR_HEIGHT } from "../state/app-state.ts";
import { c, FONT, PANEL, SIZE, SPACE, WEIGHT } from "./tokens.ts";

export function appShellStyle(
	sizes: LayoutSizes,
	bottomPaneHeight: number,
): CSSProperties {
	return {
		display: "grid",
		gridTemplateColumns: `${sizes.leftPaneWidth}px 1fr ${sizes.rightPaneWidth}px`,
		gridTemplateRows: `${TOP_BAR_HEIGHT}px minmax(0, 1fr) ${bottomPaneHeight}px`,
		width: "100vw",
		height: "100vh",
		fontFamily: FONT.sans,
		color: c.text,
		fontSize: SIZE.base,
		// Transparent shell so the unified PixiJS canvas (z-index 0)
		// shows through where panels don't cover. Stacking context via
		// z-index 1 so the resize-handle z-indexes layer above the
		// canvas. `pointer-events: none` so empty (center-pane) area
		// passes events through to the canvas — each opaque panel
		// re-claims `pointerEvents: "auto"`.
		background: "transparent",
		position: "relative",
		zIndex: 1,
		pointerEvents: "none",
	};
}

export const topBar = {
	gridColumn: "1 / -1",
	display: "flex",
	alignItems: "center",
	gap: SPACE.md,
	height: TOP_BAR_HEIGHT,
	paddingInline: SPACE.md,
	background: c.surface,
	borderBottom: `1px solid ${c.border}`,
	// See `appShellStyle.pointerEvents`.
	pointerEvents: "auto",
} satisfies CSSProperties;

export const brand = {
	display: "flex",
	alignItems: "center",
	gap: SPACE.sm,
	minWidth: 0,
} satisfies CSSProperties;

export const wordmark = {
	fontSize: SIZE.lg,
	fontWeight: WEIGHT.semibold,
	letterSpacing: -0.2,
	color: c.text,
} satisfies CSSProperties;

export const breadcrumbSep = {
	fontSize: SIZE.lg,
	color: c.textSubtle,
	marginInline: 2,
	fontWeight: WEIGHT.regular,
} satisfies CSSProperties;

export const breadcrumbCurrent = {
	fontSize: SIZE.base,
	color: c.textMuted,
	fontWeight: WEIGHT.medium,
	letterSpacing: 0.01,
	whiteSpace: "nowrap",
	overflow: "hidden",
	textOverflow: "ellipsis",
} satisfies CSSProperties;

export const headerSpacer = { flex: 1 } satisfies CSSProperties;

/**
 * The Tools section's own recessed block.
 *
 * Every other section in this rail keeps its content in one: the document's rows,
 * each of the Legend's mappings, every group in the Inspector. The tool strip and
 * the commands under it were the last thing sitting on the bare pane, which read
 * as the rail starting somewhere above where it does.
 *
 * Its two rows are ruled apart by `.ocv-tools-panel` in `styles.css`, which is
 * the same hairline the Inspector's field rows use, and the gap here is the same
 * 5px that sits above it — so the line has equal air on both sides, as it does in
 * every other panel. Every mode offers at least Select and Hand
 * (`toolsForMode`), so the box can never be empty.
 */
export const toolsPanel = {
	...PANEL,
	display: "flex",
	flexDirection: "column",
	gap: 5,
} satisfies CSSProperties;

export const leftPane = {
	background: c.surface,
	borderRight: `1px solid ${c.border}`,
	overflowY: "auto",
	minHeight: 0,
	position: "relative",
	// See `appShellStyle.pointerEvents`.
	pointerEvents: "auto",
} satisfies CSSProperties;

// Center pane is the transparent layout slot for the Stage region.
// `pointer-events: none` lets clicks pass through to the canvas;
// the Stage marker div inside is also `none` for the same reason.
//
// Flex column so the ToolOptionsBar (when rendered in build mode)
// takes its natural height at the top and the Stage marker fills
// the remaining space — without that, Stage's `height: 100%` would
// overlap the bar (both stack to 100% of the pane).
export const centerPane = {
	display: "flex",
	flexDirection: "column",
	position: "relative",
	minHeight: 0,
	minWidth: 0,
	pointerEvents: "none",
} satisfies CSSProperties;

// The Stage marker uses `height: 100%`; in a flex column its
// container needs `flex: 1` so "100%" resolves to "remaining space
// after the bar." `min-height: 0` lets it shrink correctly.
export const stageSlot = {
	flex: "1 1 0",
	minHeight: 0,
	position: "relative",
	pointerEvents: "none",
} satisfies CSSProperties;

export const rightPane = {
	background: c.surface,
	borderLeft: `1px solid ${c.border}`,
	overflowY: "auto",
	minHeight: 0,
	position: "relative",
	// See `appShellStyle.pointerEvents`.
	pointerEvents: "auto",
} satisfies CSSProperties;

export const bottomBar = {
	gridColumn: "1 / -1",
	// Transparent so the Timeline's Overview / Scrubber paint
	// through; the toolbar inside carries its own opaque surface.
	// `position: relative` is for the top-edge `ResizeHandle`;
	// `minHeight: 0` lets the panel honor the grid row.
	background: "transparent",
	borderTop: `1px solid ${c.border}`,
	position: "relative",
	minHeight: 0,
	overflow: "hidden",
	// See `appShellStyle.pointerEvents`.
	pointerEvents: "auto",
} satisfies CSSProperties;
