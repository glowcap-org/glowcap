/**
 * Timeline control row, play/pause/restart, lane toggles, zoom,
 * fit, time readout, speed, and Live's record chrome.
 *
 * `TimelinePanel` owns the canvas regions and the view reducer. This
 * module owns the DOM toolbar those canvases sit under. Live mode
 * drops playback verbs outright rather than dimming them, so the
 * chrome never accumulates ghost buttons.
 */

import { FitGlyph } from "../glyphs.tsx";
import type { Ref } from "react";
import { formatClockTime as formatTime } from "../format.ts";
import { LiveControls } from "../LiveControls.tsx";
import { c, FONT, RADIUS, segmentCellClass, SIZE, SPACE, WEIGHT } from "../tokens.ts";
import { ScrubInput } from "./ScrubInput.tsx";
import type { LaneKind } from "./state.ts";

/** Everything the control row needs for Live's Record / Stop verb
 * and the connection badge. Provided iff the panel is in Live mode. */
export type TimelineLive = {
	/** Whether the feed's socket is open. Live mode dials on
	 *  entry, so this is usually true before anyone records. The
	 *  badge below reads it only to say when a running capture
	 *  has lost its feed. */
	connected: boolean;
	/** True while a capture is running. Idle Live renders no
	 *  timeline body at all, no rows, no playhead, just the
	 *  Record affordance. */
	recording: boolean;
	/** True iff the buffer holds any events (fixture, file,
	 *  prior recording). Drives the confirm-discard prompt on
	 *  Record. */
	bufferHasContent: boolean;
	onStartRecord: () => void;
	/** Claim the recording and land in Play. */
	onStopRecord: () => void;
	/** Throw the recording away, staying live. */
	onDiscardRecording: () => void;
};

export type TimelineToolbarProps = {
	rowRef: Ref<HTMLDivElement>;
	disabled?: boolean | undefined;
	live?: TimelineLive | undefined;
	isPlaying: boolean;
	onPlayPause: () => void;
	onRestart: () => void;
	expandedLanes: ReadonlySet<LaneKind>;
	onToggleLane: (lane: LaneKind) => void;
	visibleRangeLabel: string;
	zoom: number;
	zoomMin: number;
	zoomMax: number;
	setZoom: (next: number) => void;
	resetView: () => void;
	autoSizeTimeline?: boolean | undefined;
	onSetAutoSizeTimeline?: ((value: boolean) => void) | undefined;
	t: number;
	duration: number;
	speed: number;
	onSetSpeed: (speed: number) => void;
};

export function TimelineToolbar(
	{
		rowRef,
		disabled,
		live,
		isPlaying,
		onPlayPause,
		onRestart,
		expandedLanes,
		onToggleLane,
		visibleRangeLabel,
		zoom,
		zoomMin,
		zoomMax,
		setZoom,
		resetView,
		autoSizeTimeline,
		onSetAutoSizeTimeline,
		t,
		duration,
		speed,
		onSetSpeed,
	}: TimelineToolbarProps,
) {
	// Control row composition splits by mode rather than disabling
	// everything in place: Live MODE has no notion of playback (the
	// feed advances on its own), no start/end to seek between, and
	// no playback speed to scale, so those controls are dropped
	// outright. What stays is everything that still has meaning,
	// visibility, lane expansion, zoom, fit, the LIVE badge, and
	// the live-edge readout. Play / Build keep the full set. The
	// split renders as two branches instead of a sea of `disabled`
	// flags so the chrome doesn't accumulate "ghost" buttons that
	// just dim when not applicable.
	return (
		<div ref={rowRef} style={controlRow}>
			{disabled
				? (
					<>
						{live && (
							<LiveControls
								recording={live.recording}
								bufferHasContent={live.bufferHasContent}
								onStart={live.onStartRecord}
								onStop={live.onStopRecord}
								onDiscard={live.onDiscardRecording}
							/>
						)}
						{live?.recording && <LiveBadge connected={live.connected} />}
					</>
				)
				: (
					<>
						<button
							type="button"
							className={`ocv-btn${isPlaying ? " is-active" : ""}`}
							onClick={onPlayPause}
							title={isPlaying ? "Pause (Space)" : "Play (Space)"}
						>
							{isPlaying ? <PauseGlyph /> : <PlayGlyph />}
							<span>{isPlaying ? "Pause" : "Play"}</span>
						</button>
						<button
							type="button"
							className="ocv-btn is-ghost"
							onClick={onRestart}
							title="Restart (R)"
						>
							<RestartGlyph />
							<span>Restart</span>
						</button>
					</>
				)}

			{
				/* Lane toggles sit with the verbs on the left so the user
          reads the row as "primary action · what's visible · (spacer)
          · view controls". The master "all rows" visibility verb
          now lives as the eyeball next to the Overview's "overview"
          label (see `Overview.tsx`), aligning with the per-category
          and per-entity eyeballs in the gutter column. */
			}
			<Divider />
			<LaneToggles expanded={expandedLanes} onToggle={onToggleLane} />

			<span style={{ flex: 1 }} />

			<Divider />

			<span style={visibleRange}>{visibleRangeLabel}</span>
			<LabeledControl label="zoom">
				<ScrubInput
					value={zoom}
					onChange={setZoom}
					min={zoomMin}
					max={zoomMax}
					defaultValue={1}
					format={formatZoom}
					label="Zoom"
				/>
			</LabeledControl>
			<button
				type="button"
				className="ocv-btn is-ghost"
				onClick={resetView}
				title="Fit time view (or double-click the timeline)"
			>
				<FitGlyph />
				<span>Fit</span>
			</button>
			{onSetAutoSizeTimeline && (
				<label
					className="ocv-btn is-ghost"
					style={{
						display: "inline-flex",
						alignItems: "center",
						gap: 4,
						cursor: "pointer",
					}}
					title="Auto-size the panel to content — re-fits on row expand, collapse and mode switch. Drag the top edge to turn it off"
				>
					<input
						type="checkbox"
						checked={autoSizeTimeline ?? false}
						onChange={(e) => onSetAutoSizeTimeline(e.target.checked)}
						style={{ margin: 0 }}
					/>
					<FitHeightGlyph />
				</label>
			)}

			<Divider />

			<span style={timeReadout}>
				{
					/* Live: the clock IS the capture's length, so t alone
            (no end). Play / Build: t / duration. */
				}
				{formatTime(t)}
				{!disabled && ` / ${formatTime(duration)}`}
			</span>
			{!disabled && (
				<LabeledControl label="speed">
					<ScrubInput
						value={speed}
						onChange={onSetSpeed}
						min={0.0625}
						max={16}
						defaultValue={1}
						format={formatSpeed}
						label="Playback speed"
					/>
				</LabeledControl>
			)}
		</div>
	);
}

const controlRow = {
	display: "flex",
	alignItems: "center",
	gap: SPACE.sm,
	paddingInline: SPACE.md,
	paddingBlock: SPACE.sm,
	borderBottom: `1px solid ${c.divider}`,
	// Opaque chrome. The surrounding bar is transparent so the
	// unified canvas can paint Overview / Scrubber pixels through.
	background: c.surface,
} satisfies React.CSSProperties;

const visibleRange = {
	fontFamily: FONT.mono,
	color: c.textSubtle,
	fontSize: SIZE.xs,
	fontVariantNumeric: "tabular-nums",
	letterSpacing: 0.02,
	whiteSpace: "nowrap",
} satisfies React.CSSProperties;

// "ZOOM" / "SPEED" eyebrow next to the ScrubInput. Sans-serif
// label against the input's mono value, matches the sidebar's
// key / value convention.
const labeledControlWrap = {
	display: "inline-flex",
	alignItems: "center",
	gap: 6,
	flexShrink: 0,
} satisfies React.CSSProperties;

const controlLabel = {
	fontFamily: FONT.sans,
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	letterSpacing: 0.6,
	textTransform: "uppercase",
	color: c.textSubtle,
} satisfies React.CSSProperties;

// Thin vertical hairline that separates logical groups in the
// control row. Slightly shorter than the row so it reads as a
// divider, not a border.
const dividerStyle = {
	width: 1,
	height: 16,
	background: c.divider,
	flexShrink: 0,
	marginInline: SPACE.xs,
} satisfies React.CSSProperties;

function LabeledControl(
	{ label, children }: { label: string; children: React.ReactNode },
) {
	return (
		<span style={labeledControlWrap}>
			<span style={controlLabel}>{label}</span>
			{children}
		</span>
	);
}

function Divider() {
	return <span style={dividerStyle} aria-hidden="true" />;
}

const timeReadout = {
	fontFamily: FONT.mono,
	color: c.textMuted,
	fontSize: SIZE.xs,
	fontVariantNumeric: "tabular-nums",
	minWidth: 92,
	textAlign: "right",
	letterSpacing: 0.02,
} satisfies React.CSSProperties;

/** What the running capture is getting from its feed.
 *
 * It appears only while a capture is running, because that is the
 * state it reports on: a capture whose socket has dropped is still a
 * capture, and it is receiving nothing. So the two states are
 * "recording" and "reconnecting…", and the second is the one a reader
 * must not miss.
 *
 * Whether a feed is connected at all is a different fact, and it is
 * answered where a reader asks it: beside the URL in the Source panel,
 * which is green before anyone presses Record. Being connected is not
 * recording, and this badge is not a second place to read
 * the connection. */
function LiveBadge({ connected }: { connected: boolean }) {
	const label = connected ? "recording" : "reconnecting…";
	const color = connected ? c.danger : c.warning;
	const bg = connected ? c.dangerSoft : c.warningSoft;
	const title = connected
		? "Recording from the live feed; playback is disabled"
		: "The live feed dropped. The capture is running and receiving nothing";
	return (
		<span
			role="status"
			aria-label={title}
			title={title}
			style={{
				display: "inline-flex",
				alignItems: "center",
				gap: SPACE.xs,
				padding: `2px ${SPACE.sm}px`,
				borderRadius: RADIUS.pill,
				background: bg,
				color,
				fontSize: SIZE.xs,
				fontWeight: WEIGHT.semibold,
				letterSpacing: 0.6,
				textTransform: "uppercase",
				// Steady dot, not pulsing, pulsing on a static badge
				// gets annoying after a few seconds of monitoring.
			}}
		>
			<span
				aria-hidden="true"
				style={{
					width: 6,
					height: 6,
					borderRadius: "50%",
					background: color,
					display: "inline-block",
				}}
			/>
			{label}
		</span>
	);
}

function LaneToggles(
	{ expanded, onToggle }: {
		expanded: ReadonlySet<LaneKind>;
		onToggle: (lane: LaneKind) => void;
	},
) {
	const lanes: LaneKind[] = ["peers", "sessions", "messages"];
	return (
		<div className="ocv-segment" role="group" aria-label="Timeline lanes">
			{lanes.map((lane) => (
				<button
					key={lane}
					type="button"
					role="switch"
					aria-checked={expanded.has(lane)}
					className={segmentCellClass(expanded.has(lane))}
					onClick={() => onToggle(lane)}
					title={`Toggle ${lane} lane`}
				>
					{lane}
				</button>
			))}
		</div>
	);
}

/** Playback speed format: below 1× always two decimals (`0.50×`),
 * 1× and above two decimals only when non-integer (`1×`, `1.50×`,
 * `10×`). Tabular-nums takes care of column alignment. */
function formatSpeed(value: number): string {
	if (value < 1) return `${value.toFixed(2)}×`;
	if (Number.isInteger(value)) return `${value}×`;
	return `${value.toFixed(2)}×`;
}

/** Zoom factor: integer-rounded above 10×, two decimals below. */
function formatZoom(value: number): string {
	if (value >= 10) return `${Math.round(value)}×`;
	if (Number.isInteger(value)) return `${value}×`;
	return `${value.toFixed(2)}×`;
}

function PlayGlyph() {
	return (
		<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
			<path d="M2 1 L9 5 L2 9 Z" fill="currentColor" />
		</svg>
	);
}
function PauseGlyph() {
	return (
		<svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
			<rect x="2" y="1.5" width="2.2" height="7" fill="currentColor" />
			<rect x="5.8" y="1.5" width="2.2" height="7" fill="currentColor" />
		</svg>
	);
}
function RestartGlyph() {
	return (
		<svg
			width="11"
			height="11"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.6"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M2 6a4 4 0 1 0 1.2-2.85" />
			<polyline points="2 1.5 2 4 4.5 4" />
		</svg>
	);
}
// Vertical double-arrow between two horizontal rails, reads as
// "snap height to fit". Distinct from the time-Fit corner glyph.
function FitHeightGlyph() {
	return (
		<svg
			width="11"
			height="11"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.6"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<line x1="2" y1="2" x2="10" y2="2" />
			<line x1="2" y1="10" x2="10" y2="10" />
			<line x1="6" y1="4" x2="6" y2="8" />
			<polyline points="4 6 6 4 8 6" />
			<polyline points="4 6 6 8 8 6" />
		</svg>
	);
}
