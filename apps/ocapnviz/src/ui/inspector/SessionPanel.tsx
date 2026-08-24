/**
 * Session inspector panel — Details + Timing (with the full
 * trajectory editor) for `SessionFields`, and the Connections sub-
 * panel listing what each end connects to for `SessionConnections`.
 *
 * The panel is four blocks. Details holds the session's own facts, its
 * id and how it talks. Then one block per end, because a session has
 * exactly two and they are the part a reader comes here to read. Then
 * Timing.
 *
 * A session has three temporal properties: the lifecycle it moves
 * through, and which peer is on each of its two ends. The Timing
 * section lists every moment on all three, numbered in time order,
 * and each row can be dragged, edited, or cleared. What the session
 * is BORN with is not a moment: the genesis state folds onto the
 * start row, and each end's genesis — its claim, the peer it attaches
 * to, and what attributed it — is edited in that end's own block.
 */

import { TRANSPORT_OPTIONS } from "../../schema/topology.ts";
import { endpointStageId, SESSION_SIDES } from "../../schema/session-end.ts";
import type { StageSelection } from "../../render/types.ts";
import type { Engine } from "../../engine/engine.ts";
import { findSession } from "../../engine/world.ts";
import {
	findPeerJoinedEvent,
	findPeerLeftEvent,
	findSessionClosedEvent,
	findSessionOpenedEvent,
} from "../../engine/event-helpers.ts";
import { peerLabelAt, sessionEndpointPlaceAt } from "../../engine/temporal/doc-resolver.ts";
import { CAPTP_VERSION_OPTIONS, captpVersionLabel, CODEC_OPTIONS, SessionState } from "../../schema/topology.ts";
import { SESSION_PROPERTIES, type SessionProperty, sessionTrajectoryRows } from "../../engine/trajectory.ts";
import { SessionMoments } from "./SessionTrajectory.tsx";
import { LifecycleChip, type LifecycleStatus, SessionKindLabel, StateChip } from "../EntityChips.tsx";
import { EditableIdField, EnumSelect, Field, FieldGroup, NONE, NOTHING } from "./fields.tsx";
import type { EditorBindings } from "./bindings.ts";
import { DivergenceHint, OptionalTimeRow } from "./trajectory.tsx";
import { ClaimLinkRow, PeerLinkRow, Unknown } from "./links.tsx";
import { kv, linkRowList, PanelHeading, placeholder, valueMono, valueText } from "./styles.tsx";
import { Identifier } from "../identifier.tsx";
import { isInSelection, peerInfo, sessionInfo } from "./entity-info.ts";
import { sessionEndName } from "../session-name.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import { SessionEndFields, SessionEndNames } from "./session-end-fields.tsx";

export function SessionFields(
	{ engine, id, editor }: {
		engine: Engine;
		id: string;
		editor?: EditorBindings | undefined;
	},
) {
	// No world pin to follow: shell `useDocVersion` + `useClockSnapshot` is
	// enough for playhead-shaped lifecycle and end placement.
	const live = findSession(engine.world, id);
	const openedEv = findSessionOpenedEvent(engine.doc, id);
	const closedEv = findSessionClosedEvent(engine.doc, id);
	const def = engine.doc.entities?.sessions?.[id];
	if (!live && !def) return <Unknown kind="session" id={id} />;

	// Where each end sits at the playhead, and whether anything attributed
	// it — one question, asked where it is answered for the stage too, so
	// this panel and the picture cannot disagree about which ends are loose.
	const place = {
		a: sessionEndpointPlaceAt(engine.doc, id, "a", engine.clock.t),
		b: sessionEndpointPlaceAt(engine.doc, id, "b", engine.clock.t),
	};
	const endpointA = place.a.node;
	const endpointB = place.b.node;
	// What to CALL each end in the heading. `sessionEndName` answers, and it
	// is the same answer the picker and the connection rows get, so the
	// heading and the lists below it cannot call one end two things. Each
	// kind of name is shown the way its kind wants: a name clipped at its
	// end, a claim cut in its middle.
	const endName = {
		a: sessionEndName(engine.doc, id, "a", engine.clock.t),
		b: sessionEndName(engine.doc, id, "b", engine.clock.t),
	};
	// What the session is BORN with, which is where Build writes it: the
	// definition is the authority the projection fills from the opening
	// observation, so a document loaded before that projection ran still
	// reads its netlayer off the observation.
	const transport = def?.transport ?? openedEv?.transport;
	const codec = live?.session.codec ?? def?.codec ?? "capnp";
	const captpVersion = live?.session.captpVersion ?? def?.captpVersion ??
		"v1_0";
	const sessionState = live?.session.state ?? def?.initialState ?? "open";

	// Containment window: a session can only exist while both endpoint
	// peers are joined. The intersection of the two peers' [joined,
	// left] ranges is the hard window for the session's opened /
	// closed times.
	const aJoinedEv = findPeerJoinedEvent(engine.doc, endpointA);
	const aLeftEv = findPeerLeftEvent(engine.doc, endpointA);
	const bJoinedEv = findPeerJoinedEvent(engine.doc, endpointB);
	const bLeftEv = findPeerLeftEvent(engine.doc, endpointB);
	const containedMin = Math.max(aJoinedEv?.t ?? 0, bJoinedEv?.t ?? 0);
	const peerLeftMin = aLeftEv && bLeftEv ? Math.min(aLeftEv.t, bLeftEv.t) : aLeftEv?.t ?? bLeftEv?.t ?? null;

	const lifecycle: LifecycleStatus = live
		? "active"
		: openedEv && engine.clock.t < openedEv.t
		? "before"
		: closedEv && engine.clock.t >= closedEv.t
		? "after"
		: "off-stage";

	const editing = editor !== undefined;
	const update = editor?.onUpdateSession;
	const duration = engine.doc.duration;

	const initialState = def?.initialState ?? "open";
	// Every moment on the session, whatever property it states, in one
	// numbered list. The rows come from `engine/trajectory.ts`, so a
	// fourth session property renders here with no change to this file.
	const moments = sessionTrajectoryRows(engine.doc, id);
	// The same moments grouped by the property each states, so a row can
	// find its own neighbours without walking the whole list per row.
	const byProperty = new Map<SessionProperty, typeof moments>();
	for (const m of moments) {
		const rows = byProperty.get(m.property);
		if (rows === undefined) byProperty.set(m.property, [m]);
		else rows.push(m);
	}
	// What a peer picker can offer: the peers this document declares, each
	// with the name it answers to at the playhead. `PeerSelect` decides how
	// those names read, so two peers called Alice are told apart there
	// rather than here.
	const peerOptions = Object.keys(engine.doc.entities?.peers ?? {}).map(
		(peerId) => ({
			id: peerId,
			name: peerLabelAt(engine.doc, peerId, engine.clock.t),
		}),
	);
	const effStart = engine.intrinsicStart("sessions", id);
	const startMaxEdit = moments.length > 0
		? Math.min(moments[0]!.t, closedEv?.t ?? duration)
		: closedEv?.t ?? duration;
	const startStrictEdit = moments.length > 0 || closedEv !== null;
	return (
		<>
			<PanelHeading
				mono={endName.a.opaque || endName.b.opaque}
				title={`${endName.a.text} ↔ ${endName.b.text}`}
			>
				<SessionEndNames a={endName.a} b={endName.b} />
			</PanelHeading>
			<SessionKindLabel codec={codec} captpVersion={captpVersion} />
			{
				/* The session's own facts: what it is called, and how it talks.
          The two ends get a group each below, because they are the part
          a reader came to read and they are symmetrical. */
			}
			<FieldGroup title="Details">
				<div style={kv}>
					<Field label="id">
						{editing && editor
							? (
								<EditableIdField
									kind="session"
									id={id}
									editor={editor}
								/>
							)
							: <Identifier value={id} />}
					</Field>
					<Field label="codec">
						{editing
							? (
								<EnumSelect
									value={codec}
									options={CODEC_OPTIONS}
									ariaLabel="Session codec"
									onChange={(v) => update?.(id, { codec: v })}
								/>
							)
							: <code style={valueMono}>{codec}</code>}
					</Field>
					<Field label="captp version">
						{editing
							? (
								<EnumSelect
									value={captpVersion}
									options={CAPTP_VERSION_OPTIONS}
									ariaLabel="Session CapTP version"
									labelFor={captpVersionLabel}
									onChange={(v) => update?.(id, { captpVersion: v })}
								/>
							)
							: (
								<code style={valueMono}>
									{captpVersionLabel(captpVersion)}
								</code>
							)}
					</Field>
					<Field label="transport">
						{editing
							? (
								<EnumSelect
									value={transport ?? NONE}
									options={[NONE, ...TRANSPORT_OPTIONS]}
									ariaLabel="Session transport"
									labelFor={(v) => v === NONE ? NOTHING : v}
									onChange={(v) =>
										update?.(id, {
											transport: v === NONE ? null : v,
										})}
								/>
							)
							: transport === undefined
							? <span style={valueText}>{NOTHING}</span>
							: <code style={valueMono}>{transport}</code>}
					</Field>
				</div>
			</FieldGroup>
			{SESSION_SIDES.map((side) => {
				// Build mode edits what the end is born with; read-only, the
				// peer is whoever holds the end at the playhead, which is the
				// peer the stage is drawing to.
				const end = def?.[side];
				const attached = place[side].peer;
				const editable = editing && editor !== undefined &&
					def !== undefined;
				return (
					<SessionEndFields
						key={endpointStageId(id, side)}
						sessionId={id}
						side={side}
						claim={end?.designator}
						// The peer and what attributed it are one fact and are read
						// from one moment. Build reads the genesis pair, which is
						// what its two pickers write; every other mode reads the
						// pair in effect at the playhead, so an end a signed
						// handoff attached mid-session says what proved it instead
						// of reporting the birth of an end that was loose then.
						peer={editable ? end?.peer : attached}
						peerLabel={attached === undefined
							? undefined
							: peerLabelAt(engine.doc, attached, engine.clock.t)}
						attributedBy={editable ? end?.attributedBy : place[side].attributedBy}
						peers={peerOptions}
						editor={editable ? editor : undefined}
					/>
				);
			})}
			<FieldGroup title="Timing">
				<div style={kv}>
					<OptionalTimeRow
						label="start"
						below={editing && editor
							? (
								<EnumSelect
									value={initialState}
									options={SessionState.options}
									ariaLabel="Initial session state"
									onChange={(v) => editor.onSetSessionInitialState(id, v)}
								/>
							)
							: undefined}
						note={
							<DivergenceHint
								reason={engine.clampReason(
									"sessions",
									id,
									"start",
								)}
							/>
						}
						t={def?.timing?.start.explicit ? effStart : null}
						editing={editing}
						onMove={editing && editor ? (t) => editor.onSetSessionStart(id, t) : undefined}
						onClear={editing && editor ? () => editor.onClearSessionStart(id) : undefined}
						onSetAtPlayhead={editing && editor
							? () => editor.onSetSessionStart(id, engine.clock.t)
							: undefined}
						min={containedMin}
						max={editing && editor ? startMaxEdit : closedEv?.t ?? duration}
						strictMax={editing && editor ? startStrictEdit : closedEv !== null}
						scrubLabel="Session start time"
						editSession={editor}
					/>
					{
						/* The session's trajectory: every moment it changed
              state or an end attached to a peer, numbered in time
              order. "start" above carries what the session was BORN
              in; each row here is one property stated at one moment —
              a time, what changed, the value, and an X to clear it.
              Clearing an attachment is how an end comes loose again. */
					}
					<SessionMoments
						engine={engine}
						sessionId={id}
						properties={SESSION_PROPERTIES}
						editor={editing ? editor : undefined}
					/>

					<OptionalTimeRow
						label="duration"
						note={
							<DivergenceHint
								reason={engine.clampReason(
									"sessions",
									id,
									"end",
								)}
							/>
						}
						t={def?.timing?.duration.explicit ? def.timing.duration.value : null}
						editing={editing}
						onMove={editing && editor?.onSetSessionDuration
							? (dur) => editor.onSetSessionDuration(id, dur)
							: undefined}
						onClear={editor?.onClearSessionEnd ? () => editor.onClearSessionEnd(id) : undefined}
						onSetAtPlayhead={editor?.onSetSessionDuration
							? () =>
								editor.onSetSessionDuration(
									id,
									Math.max(
										0,
										engine.clock.t -
											engine.intrinsicStart(
												"sessions",
												id,
											),
									),
								)
							: undefined}
						min={Math.max(
							0,
							(moments.length > 0 ? moments[moments.length - 1]!.t : openedEv?.t ?? 0) -
								engine.intrinsicStart("sessions", id),
						)}
						max={Math.max(
							0,
							(peerLeftMin ?? duration) -
								engine.intrinsicStart("sessions", id),
						)}
						strictMax={peerLeftMin !== null}
						scrubLabel="Session duration"
						editSession={editor}
					/>
					<Field label="status">
						{live ? <StateChip state={sessionState} /> : (
							<LifecycleChip
								status={lifecycle}
								entity="session"
							/>
						)}
					</Field>
				</div>
			</FieldGroup>
		</>
	);
}

export function SessionConnections(
	{ engine, id, onSelect, entitySelection }: {
		engine: Engine;
		id: string;
		onSelect: (selection: StageSelection) => void;
		/** Multi-select awareness: an endpoint peer that's also in
		 *  the user's selection gets the "in selection" badge +
		 *  accent border, so the user reads "this endpoint is one of
		 *  the things I picked." */
		entitySelection?: ReadonlySet<EntityRefKey> | undefined;
	},
) {
	const s = sessionInfo(engine, id);
	if (!s) return null;
	const def = engine.doc.entities?.sessions?.[id];
	return (
		<div style={linkRowList}>
			{SESSION_SIDES.map((side) => {
				const ep = sessionEndpointPlaceAt(
					engine.doc,
					id,
					side,
					engine.clock.t,
				);
				// An end nothing has attributed connects to no peer, so its row
				// reaches the placeholder the stage draws instead. A row either
				// way: both ends of a session are reachable from here, and
				// reading this one as an unknown peer id would report a broken
				// reference where the document is telling the truth.
				// Every branch below is keyed the same way, on the end this row
				// IS rather than on whatever happens to be attached to it. The
				// three keys this had — the end's stage id, the side name, and
				// the attached peer's id — were three namespaces over one list,
				// and two of them collide: both ends attached to one peer (a
				// loopback session, which a live producer can report and nothing
				// refuses) gave two rows one key, and so did a peer named `a`
				// or `b`.
				const rowKey = endpointStageId(id, side);
				const attached = ep.peer;
				if (attached === undefined) {
					return (
						<ClaimLinkRow
							key={rowKey}
							claim={def?.[side].designator}
							selected={isInSelection(entitySelection, {
								kind: "endpoint",
								id: ep.node,
							})}
							onClick={() => onSelect({ kind: "endpoint", id: ep.node })}
						/>
					);
				}
				const p = peerInfo(engine, attached);
				if (!p) {
					return (
						<div key={rowKey} style={placeholder}>
							Unknown peer id: <Identifier value={attached} />
						</div>
					);
				}
				return (
					<PeerLinkRow
						key={rowKey}
						peerLabel={p.label}
						peerProfile={p.profile}
						lifecycle={p.lifecycle}
						selected={isInSelection(entitySelection, {
							kind: "peer",
							id: attached,
						})}
						onClick={() => onSelect({ kind: "peer", id: attached })}
					/>
				);
			})}
		</div>
	);
}
