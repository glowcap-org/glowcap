/**
 * Connection-list rows in the Inspector: a peer, a claim, or a
 * session, each the same shape so a list of mixed links still reads.
 */

import type { ReactNode } from "react";
import type { CaptpVersion, Codec, SessionState } from "../../schema/topology.ts";
import { UNNAMED_END_LABEL } from "../../schema/session-end.ts";
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
import { Identifier } from "../identifier.tsx";
import { WEIGHT } from "../tokens.ts";
import {
	linkRowLeft,
	linkRowMeta,
	linkRowMetaCell,
	linkRowName,
	linkRowSelectedBadge,
	placeholder,
} from "./styles.tsx";

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
 *  kind of row differs by is what it can truthfully show, a peer has a
 *  profile swatch, an unattributed end has a claim and no swatch, a
 *  session has a state, so a kind is a pair of slots, not a second
 *  spelling of a row. The three below share one row shape and one hover style,
 *  so neither lives in more than one place.
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
		left: ReactNode;
		/** How it stands: a chip, or a plain word. */
		meta: ReactNode;
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
		 * in place of the plain profile meta. So the user sees
		 * "not yet joined" / "left" without losing the row. Omit or status-allow: pending state or quoted runtime label
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
					<span style={linkRowName} title={peerLabel}>
						{peerLabel}
					</span>
				</>
			}
			meta={showLifecycle
				? <LifecycleChip status={lifecycle!} entity="peer" />
				: <span style={linkRowMeta}>{peerProfile}</span>}
		/>
	);
}

/** Claim row link. The loose-end sibling of `PeerLinkRow`, and
 *  the same shape: a session's two ends are two rows in
 *  one list, and a reader should reach either the same way. It selects
 *  the placeholder the stage draws, so the row and the node are the
 *  same act from two places.
 *
 *  What differs is what it can truthfully show. There is no swatch,
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
			left={claim === undefined ? <span style={linkRowName}>{UNNAMED_END_LABEL}</span> : (
				<Identifier
					value={claim}
					style={{ fontWeight: WEIGHT.semibold }}
				/>
			)}
			meta={<span style={linkRowMeta}>unattached</span>}
		/>
	);
}

/** Session row link, shared by `PeerConnections` and
 *  `MessageConnections` so both surfaces have one
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
