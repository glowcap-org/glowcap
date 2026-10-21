/**
 * Sidebar chips that mirror the canvas's visual encoding. Each
 * `<KindLabel>` pairs a mini-icon (same colors / line-style as the
 * on-canvas form) with the entity kind so the chip reads as both a
 * label and a legend cue. `<StateChip>` colors session state
 * traffic-light style.
 */

import type { CaptpVersion, Codec, PeerProfile, SessionState } from "../schema/topology.ts";
import {
	ATTRIBUTION_STANDING,
	type AttributionStanding,
	type EndpointAttribution,
	UNATTRIBUTED_WORD,
} from "../schema/session-end.ts";
import { CAPTP_VERSION_COLORS, colorForProfile, lineStyleForCodec, PROFILE_FALLBACK_COLOR } from "../render/palette.ts";
import type { PeerActivity } from "../render/types.ts";
import { c, FONT, RADIUS, SIZE, SPACE, WEIGHT } from "./tokens.ts";

const chip = {
	display: "inline-flex",
	alignItems: "center",
	gap: SPACE.sm,
	paddingInline: SPACE.sm,
	paddingBlock: 4,
	borderRadius: RADIUS.pill,
	background: c.surfaceMuted,
	border: `1px solid ${c.border}`,
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	letterSpacing: 0.6,
	textTransform: "uppercase",
	color: c.textMuted,
	width: "fit-content",
	maxWidth: "100%",
	whiteSpace: "nowrap",
	overflow: "hidden",
	textOverflow: "ellipsis",
} satisfies React.CSSProperties;

export function PeerKindLabel({ profile }: { profile: PeerProfile }) {
	return (
		<div style={chip}>
			<PeerSwatch profile={profile} />
			Peer node
		</div>
	);
}

export function SessionKindLabel(
	{ codec, captpVersion }: { codec: Codec; captpVersion: CaptpVersion },
) {
	return (
		<div style={chip}>
			<SessionSwatch codec={codec} captpVersion={captpVersion} />
			Session edge
		</div>
	);
}

/** An end of a session that nothing has attributed. Named for what it is
 *  rather than for what it lacks: the stage draws it where a peer would go,
 *  and the reader's question is which kind of node they have selected. */
export function EndpointKindLabel() {
	return (
		<div style={chip}>
			<EndpointSwatch />
			Session end
		</div>
	);
}

export function MessageKindLabel() {
	return (
		<div style={chip}>
			<MessageSwatch />
			Message in flight
		</div>
	);
}

/** The solid square the stage draws for a node a peer is on. Filled, with a
 *  solid inset edge: somebody is there, and the picture says so plainly.
 *
 *  It is a style rather than only a component because two surfaces need it,
 *  the swatch beside a peer's name, and the legend row that teaches the
 *  filled body against the hollow one below. Color is the caller's: a peer
 *  swatch takes the profile's color, and the legend holds color constant so
 *  the row it belongs to teaches fill rather than hue. */
export function peerBodySwatchStyle(
	fill: string,
	size = 12,
): React.CSSProperties {
	return {
		width: size,
		height: size,
		borderRadius: RADIUS.sm,
		background: fill,
		boxShadow: `inset 0 0 0 1px ${c.borderStrong}`,
		flexShrink: 0,
	};
}

export function PeerSwatch({ profile, size = 12 }: {
	profile: PeerProfile;
	size?: number;
}) {
	const fill = hex(colorForProfile(profile) || PROFILE_FALLBACK_COLOR);
	return <span style={peerBodySwatchStyle(fill, size)} />;
}

/** The color a node body wears when nothing about it says which
 *  implementation is behind it. The legend's fill row and its hollow row
 *  share it, so that pair differs only in fill and edge, which is the one
 *  thing the row is there to teach. */
export const NEUTRAL_BODY_COLOR = hex(PROFILE_FALLBACK_COLOR);

/** The dashed, faintly-filled square the stage draws where a session's end
 *  has no peer on it. A node's shape, not a solid one: something
 *  IS on the other end of the wire, and nothing has proved what.
 *
 *  It lives here beside the other swatches because two surfaces draw it, the
 *  legend that teaches the shape, and the chip that names a selected one,
 *  and a legend that drifted from the thing it explains teaches the wrong
 *  shape. */
export function endpointSwatchStyle(size = 12): React.CSSProperties {
	return {
		width: size,
		height: size,
		borderRadius: RADIUS.sm,
		background: `${hex(PROFILE_FALLBACK_COLOR)}38`,
		border: `1px dashed ${c.borderStrong}`,
		boxSizing: "border-box",
		flexShrink: 0,
	};
}

export function EndpointSwatch({ size = 12 }: { size?: number }) {
	return <span style={endpointSwatchStyle(size)} />;
}

export function SessionSwatch(
	{ codec, captpVersion }: { codec: Codec; captpVersion: CaptpVersion },
) {
	const color = hex(CAPTP_VERSION_COLORS[captpVersion]);
	return (
		<span
			style={{
				width: 16,
				height: 0,
				borderTop: `2px ${lineStyleForCodec(codec)} ${color}`,
				flexShrink: 0,
			}}
		/>
	);
}

export function MessageSwatch({ size = 10 }: { size?: number }) {
	return (
		<span
			style={{
				width: size,
				height: size,
				borderRadius: "50%",
				background: c.danger,
				flexShrink: 0,
			}}
		/>
	);
}

// Every status badge in the app: session state, lifecycle, activity,
// what attributed an end.
//
// `SIZE.xs` keeps status badges compact. A badge never wraps or shrinks,
// so the row name gives way first (`linkRowMetaCell`). A badge with no
// remaining room clips instead of growing its row.
/** The badge box itself, without the tones a caller paints into it. Exported
 *  because the Reference's transport verdicts are the same badge said about a
 *  netlayer instead of about an entity, and two spellings of one box drift. */
export const stateChipBase = {
	display: "inline-flex",
	alignItems: "center",
	paddingInline: SPACE.sm,
	paddingBlock: 1,
	borderRadius: RADIUS.sm,
	fontSize: SIZE.xs,
	fontWeight: WEIGHT.semibold,
	fontFamily: FONT.sans,
	letterSpacing: 0.4,
	textTransform: "uppercase",
	width: "fit-content",
	maxWidth: "100%",
	whiteSpace: "nowrap",
	overflow: "hidden",
	textOverflow: "ellipsis",
	flexShrink: 0,
} satisfies React.CSSProperties;

/** Lifecycle status of an entity at the current playhead.
 *  "active":     entity is on-stage right now (in the ECS)
 *  "before":     entity exists in the doc but hasn't started yet status-allow: pending state or quoted runtime label
 *                 (peer not yet joined / session not yet opened / status-allow: pending state or quoted runtime label
 *                 message not yet sent) status-allow: pending state or quoted runtime label
 *  "after":      entity has ended (peer left / session closed /
 *                 message delivered)
 *  "off-stage":  defensive: in the doc with no clear start/end
 *                 boundary but not in the ECS (shouldn't normally
 *                 happen. Renders so the bug is visible). */
export type LifecycleStatus = "active" | "before" | "after" | "off-stage";

/** Sidebar chip indicating where the selected entity is in its
 *  lifecycle relative to the playhead. Selection itself is valid
 *  whenever the entity exists in the doc. This chip is what
 *  surfaces "exists but not on stage right now". `entity` colors
 *  the label with kind-specific vocabulary ("not yet joined" status-allow: pending state or quoted runtime label
 *  for peers, "not yet open" for sessions, etc.) so the chip status-allow: pending state or quoted runtime label
 *  reads naturally for each kind without callers post-processing
 *  a generic string. */
export function LifecycleChip(
	{ status, entity }: {
		status: LifecycleStatus;
		entity: "peer" | "session" | "message";
	},
) {
	const [bg, fg, label] = lifecycleVisual(status, entity);
	return (
		<span style={{ ...stateChipBase, background: bg, color: fg }}>
			{label}
		</span>
	);
}

function lifecycleVisual(
	status: LifecycleStatus,
	entity: "peer" | "session" | "message",
): [bg: string, fg: string, label: string] {
	// Entity-specific vocabulary so the inspector reads naturally
	// without callers composing strings. Peer / session "active"
	// states are normally rendered as activity / state chips
	// (richer info than a plain lifecycle word); the labels here
	// are for the message inspector and the defensive "off stage"
	// case on any kind.
	const labels: Record<
		"peer" | "session" | "message",
		Record<LifecycleStatus, string>
	> = {
		peer: {
			active: "active",
			before: "not yet joined",
			after: "left",
			"off-stage": "off stage",
		},
		session: {
			active: "active",
			before: "not yet open",
			after: "closed",
			"off-stage": "off stage",
		},
		message: {
			active: "in flight",
			before: "not yet sent",
			after: "delivered",
			"off-stage": "off stage",
		},
	};
	const [bg, fg] = status === "active" ? [c.positiveSoft, c.positive] : [c.surfaceMuted, c.textSubtle];
	return [bg, fg, labels[entity][status]];
}

/** What backed one end's claim to be who it says it is, or that nothing did.
 *
 * The chip shows the stored value itself rather than a phrase of its own, so
 * what a reader sees, what the Build-mode picker offers, and what the document
 * holds are one word. An end nothing attributed has no stored word, and it
 * wears the app's one phrase for that.
 *
 * The tone is `attributionStandingStyle` below, over the standing the schema
 * gives the word. The Reference's attribution rows wear the same styles, so a
 * chip on the stage and the row that explains it are the same color. */
export function AttributionChip(
	{ attribution }: { attribution: EndpointAttribution | undefined },
) {
	const label = attribution ?? UNATTRIBUTED_WORD;
	return (
		<span style={attributionChipStyle(attribution)} title={label}>
			{label}
		</span>
	);
}

/** The chip an attribution wears, absence included.
 *
 * Nothing at all takes the warning tone: an end still waiting for a peer is a
 * live state of the network rather than an error, but it is the one a reader
 * must not miss. */
export function attributionChipStyle(
	attribution: EndpointAttribution | undefined,
): React.CSSProperties {
	if (attribution === undefined) {
		return {
			...stateChipBase,
			background: c.warningSoft,
			color: c.warning,
		};
	}
	return attributionStandingStyle(ATTRIBUTION_STANDING[attribution]);
}

/** The badge one kind of evidence wears.
 *
 * The three standings are not degrees of one thing, and the styles say so. A
 * signature somebody checked reads solid and confident. A producer speaking
 * about its own end is true by construction and quieter for it. This viewer's
 * own correlation is drawn weakest, in the dashed outline the stage
 * gives anything it cannot vouch for, because drawing it like a proof would be
 * the picture claiming something nothing measured. */
export function attributionStandingStyle(
	standing: AttributionStanding,
): React.CSSProperties {
	switch (standing) {
		case "checked":
			return {
				...stateChipBase,
				background: c.positiveSoft,
				color: c.positive,
			};
		case "stated":
			return {
				...stateChipBase,
				background: c.surfaceMuted,
				color: c.textMuted,
			};
		case "inferred":
			return {
				...stateChipBase,
				background: c.surface,
				color: c.textSubtle,
				border: `1px dashed ${c.border}`,
				fontWeight: WEIGHT.regular,
				textTransform: "none",
				letterSpacing: 0,
			};
	}
}

/** Traffic-light coloring for session state. */
export function StateChip({ state }: { state: SessionState }) {
	const [bg, fg] = stateColors(state);
	return (
		<span style={{ ...stateChipBase, background: bg, color: fg }}>
			{state}
		</span>
	);
}

function stateColors(state: SessionState): [bg: string, fg: string] {
	switch (state) {
		case "open":
			return [c.positiveSoft, c.positive];
		case "negotiating":
		case "draining":
			return [c.warningSoft, c.warning];
		case "closed":
			return [c.surfaceMuted, c.textSubtle];
	}
}

/** Sidebar version of the on-canvas activity badge. Same color
 * vocabulary (red = sending, green = receiving, slate = idle). Two
 * dots side by side for "both" so the duplication itself signals
 * the dual state. */
export function ActivityChip({ activity }: { activity: PeerActivity }) {
	const [bg, fg, label] = activityVisual(activity);
	return (
		<span style={{ ...stateChipBase, background: bg, color: fg, gap: 6 }}>
			<ActivityDots activity={activity} />
			{label}
		</span>
	);
}

function ActivityDots({ activity }: { activity: PeerActivity }) {
	if (activity === "both") {
		return (
			<span style={{ display: "inline-flex", gap: 2 }}>
				<Dot color={c.danger} />
				<Dot color={c.positive} />
			</span>
		);
	}
	const color = activity === "sending" ? c.danger : activity === "receiving" ? c.positive : c.textSubtle;
	return <Dot color={color} />;
}

function Dot({ color }: { color: string }) {
	return (
		<span
			style={{
				width: 6,
				height: 6,
				borderRadius: "50%",
				background: color,
				flexShrink: 0,
			}}
		/>
	);
}

function activityVisual(
	activity: PeerActivity,
): [bg: string, fg: string, label: string] {
	switch (activity) {
		case "sending":
			return [c.dangerSoft, c.danger, "sending"];
		case "receiving":
			return [c.positiveSoft, c.positive, "receiving"];
		case "both":
			return [c.surfaceMuted, c.textMuted, "sending + receiving"];
		case "idle":
			return [c.surfaceMuted, c.textSubtle, "idle"];
	}
}

function hex(color: number): string {
	return `#${color.toString(16).padStart(6, "0")}`;
}
