/**
 * A session's trajectory, as rows a reader can edit. Every moment the
 * session changed state or an end attached to a peer.
 *
 * It lives in its own module because two panels list these moments and they
 * list different ones. The session panel shows the whole trajectory. The
 * panel for one unattributed end shows that end's own attachments and
 * nothing else, since the state the session is in and what happens at its
 * other end are not that end's facts. Both are the same question asked with
 * a different set of properties, so both ask here.
 *
 * The rows are numbered within the set being shown. A reader counting rows
 * in front of them should reach the number beside the last one, and an end's
 * panel showing "#3" for the third attachment because two state changes came
 * first would be counting something the reader cannot see.
 */

import { Fragment } from "react";
import type { Engine } from "../../engine/engine.ts";
import {
	type SessionProperty,
	sessionRowDisplay,
	sessionTrajectoryRows,
	type SessionValue,
} from "../../engine/trajectory.ts";
import { peerLabelAt, sessionPropertyValueAt } from "../../engine/temporal/doc-resolver.ts";
import type { EditorBindings } from "./bindings.ts";
import { Field } from "./fields.tsx";
import { OptionalTimeRow, TrajectoryInsert, TrajectoryValue } from "./trajectory.tsx";

/** What the "state a property here" control offers at `t`, and the value each
 *  offer would insert.
 *
 *  A new moment arrives saying something true, what the session already
 *  carries at the playhead, so the author edits a real value rather than
 *  filling in a blank. It is the property's whole value, not the word that
 *  names it: an insert over an end a signed handoff attributed restates that
 *  attribution, where offering the peer alone would have the new moment
 *  quietly unsay it.
 *
 *  What a property carries can be nothing, though, and the two lanes differ
 *  there: every peer property is total, while an end may be attached to no
 *  peer at all. So an end falls back to a peer the document declares, and a
 *  document with none does not offer the row rather than offering one the
 *  write would refuse. */
export function trajectoryInsertOffers(
	engine: Engine,
	sessionId: string,
	t: number,
	properties: readonly SessionProperty[],
): { property: SessionProperty; value: SessionValue }[] {
	const def = engine.doc.entities?.sessions?.[sessionId];
	const firstPeer = Object.keys(engine.doc.entities?.peers ?? {})[0];
	const out: { property: SessionProperty; value: SessionValue }[] = [];
	for (const property of properties) {
		const carried = sessionPropertyValueAt(
			engine.doc,
			sessionId,
			property,
			t,
		);
		const value = carried ??
			(property === "state"
				? def?.initialState ?? "open"
				: firstPeer === undefined
				? undefined
				: { peer: firstPeer });
		if (value !== undefined) out.push({ property, value });
	}
	return out;
}

/**
 * The numbered moment rows for `properties`, followed by the control that
 * states another one at the playhead. Renders nothing outside Build, where
 * there is no editor to write with.
 *
 * `startingAt` is the number the first row takes, so a caller that has
 * already listed rows above these can continue the count instead of starting
 * over.
 */
export function SessionMoments(
	{ engine, sessionId, properties, editor, startingAt = 1 }: {
		engine: Engine;
		sessionId: string;
		properties: readonly SessionProperty[];
		editor: EditorBindings | undefined;
		startingAt?: number;
	},
) {
	if (!editor) return null;
	const peerIds = Object.keys(engine.doc.entities?.peers ?? {});
	const effStart = engine.intrinsicStart("sessions", sessionId);
	const effEnd = engine.intrinsicEnd("sessions", sessionId);
	const def = engine.doc.entities?.sessions?.[sessionId];
	const shown = new Set(properties);
	const moments = sessionTrajectoryRows(engine.doc, sessionId)
		.filter((m) => shown.has(m.property));
	// What bounds a row is its own property's neighbours. Another property's
	// moment at some other instant is not a constraint on this one, the tracks
	// are read separately, and the moment beside it in ITS track is. Grouped
	// over the whole trajectory, not over `moments`, so an end's panel bounds
	// its rows against every attachment on that end even while showing a subset.
	const byProperty = new Map<SessionProperty, typeof moments>();
	for (const m of sessionTrajectoryRows(engine.doc, sessionId)) {
		const rows = byProperty.get(m.property);
		if (rows === undefined) byProperty.set(m.property, [m]);
		else rows.push(m);
	}
	const t = Math.max(engine.clock.t, effStart);
	const offers = trajectoryInsertOffers(engine, sessionId, t, properties);
	return (
		<>
			{moments.map((moment, i) => {
				const siblings = byProperty.get(moment.property) ?? [];
				const at = siblings.findIndex((m) => m.eventId === moment.eventId);
				const prevT = at <= 0 ? effStart : siblings[at - 1]!.t;
				const nextT = at === siblings.length - 1 ? effEnd : siblings[at + 1]!.t;
				const spec = sessionRowDisplay(moment.property, peerIds);
				const n = startingAt + i;
				return (
					// Keyed on the observation that states this moment, which is the one
					// name that survives the edits a reader makes to it. Keyed on the
					// time, the row unmounts mid-drag and the gesture dies with the
					// element; keyed on the keyframe's place in its track, an insert
					// earlier in the track hands this row's fiber to a different status-allow: event or source ordering
					// keyframe and steals the focus out of whatever was being typed.
					<Fragment key={moment.eventId}>
						<OptionalTimeRow
							label={`#${n} ${spec.noun}`}
							below={
								<TrajectoryValue
									property={spec}
									value={moment.value}
									editing
									editSession={editor}
									// A row that attaches an end offers peers, and a peer
									// is known by its name. Read at the playhead, like
									// every other name this panel shows, so a peer renamed
									// partway through the recording is offered under the
									// name it answers to at the moment being edited. status-allow: state at observation
									nameOfPeer={(peerId) =>
										peerLabelAt(
											engine.doc,
											peerId,
											engine.clock.t,
										)}
									onChange={(v) =>
										editor.onSetSessionKeyframe(
											sessionId,
											moment.property,
											moment.t,
											v,
										)}
								/>
							}
							t={moment.t}
							editing
							// One intent, addressed by the observation the moment IS.
							// Removing and re-stating it was two writes with a hole between
							// them: `setSessionKeyframe` REPLACES at its `t`, so dropping the
							// row on a moment of its own property deleted that moment and
							// left the track one entry short. A move refuses that landing.
							onMove={(newT) =>
								editor.onMoveEvent({
									kind: "translate",
									eventId: moment.eventId,
									newT,
								})}
							onClear={() =>
								editor.onRemoveSessionKeyframe(
									sessionId,
									moment.property,
									moment.t,
								)}
							onSetAtPlayhead={undefined}
							min={prevT}
							max={nextT}
							strictMax={at < siblings.length - 1 ||
								def?.timing?.duration.explicit === true}
							scrubLabel={`Keyframe ${n} time`}
							editSession={editor}
						/>
					</Fragment>
				);
			})}
			{offers.length > 0 && (
				<Field label={`#${startingAt + moments.length}`}>
					<TrajectoryInsert
						properties={offers.map((o) => o.property)}
						describe={(property) => sessionRowDisplay(property, peerIds)}
						onInsert={(property) => {
							const offer = offers.find((o) => o.property === property);
							if (offer !== undefined) {
								editor.onSetSessionKeyframe(
									sessionId,
									property,
									t,
									offer.value,
								);
							}
						}}
					/>
				</Field>
			)}
		</>
	);
}
