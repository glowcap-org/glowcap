/**
 * Endpoint inspector panel, what one end of a session claims to be, and
 * what attributed it.
 *
 * The panel exists for the end nothing attributed. A session's other end is
 * a peer, and a peer has its own panel. This one is reached by selecting the
 * placeholder the stage draws where a peer would sit. It answers the one
 * question the placeholder raises, which is what this empty-looking node is.
 *
 * What it holds is this end's own facts and no others. The claim it makes is
 * its name, so that is the heading and it is edited there. Whether bytes are
 * moving through it is its status. The moments somebody attaches to it are
 * its trajectory. It does not report the session's transport, because one
 * session runs over one netlayer and both ends share it, so the transport is
 * the session's fact and is shown and edited there, and the same for the
 * state the session is in and for whatever happens at its other end.
 *
 * It does not teach the attributions either: those are values a reader meets
 * where they are chosen, and a taxonomy here is a lecture nobody asked for.
 *
 * There is no delete row. An end is one of the two a session HAS, so
 * removing it would leave a session with one end. Deleting the session takes
 * it, which is the act a reader who wants it gone actually means.
 */

import { nodeActivityIn, type StageSelection } from "../../render/types.ts";
import type { Engine } from "../../engine/engine.ts";
import { findEndpoint, findSession } from "../../engine/world.ts";
import { captpVersionLabel } from "../../schema/topology.ts";
import { parseEndpointStageId, SESSION_SIDES, UNNAMED_END_LABEL } from "../../schema/session-end.ts";
import { sessionEndpointPlaceAt } from "../../engine/temporal/doc-resolver.ts";
import { ActivityChip, AttributionChip, EndpointKindLabel, LifecycleChip } from "../EntityChips.tsx";
import { Field, FieldGroup, InlineTextField } from "./fields.tsx";
import type { EditorBindings } from "./bindings.ts";
import { PositionRow } from "./position-row.tsx";
import { SessionLinkRow } from "./links.tsx";
import { inlineHeadingInput, kv, linkRowList, PanelHeading, placeholder, valueMono, valueText } from "./styles.tsx";
import { SessionMoments } from "./SessionTrajectory.tsx";
import { Identifier } from "../identifier.tsx";
import { useEngineVersion } from "../useEngineVersion.ts";
import { isInSelection, peerInfo, sessionInfo } from "./entity-info.ts";
import type { EntityRefKey } from "../../interactions/types.ts";

/** What the document and the world know about one loose end. Null when the
 *  id does not name an end of a declared session, which is what an
 *  Inspector left pointing at an end whose session was deleted sees. */
function endpointInfo(engine: Engine, id: string) {
	const at = parseEndpointStageId(id);
	if (!at) return null;
	const def = engine.doc.entities?.sessions?.[at.sessionId];
	if (!def) return null;
	const live = findEndpoint(engine.world, id);
	return {
		sessionId: at.sessionId,
		side: at.side,
		// The world entity carries the claim resolved at the playhead; off
		// stage, the document's own genesis value is what the end claimed.
		designator: live?.endpoint.designator ?? def[at.side].designator,
		// An end this panel is showing is loose by construction: an attributed
		// end has a peer, and the Inspector follows the peer instead. Read the
		// playhead's own answer anyway rather than assuming, so a hand-edited
		// document that violates the invariant shows what it says,
		// and read it from the moment the rest of this panel is about, not
		// from the session's birth.
		attributedBy: sessionEndpointPlaceAt(
			engine.doc,
			at.sessionId,
			at.side,
			engine.clock.t,
		).attributedBy,
		onStage: live !== undefined,
		// Whether bytes are moving through this end is a separate question from
		// who is on it, and only the second one is open here. Messages on a
		// session with a loose end name that end's stage id, so this is the same
		// fold the end's own mark on the stage is drawn from.
		activity: live ? nodeActivityIn(engine.queries.messagesInFlight, id) : ("idle" as const),
	};
}

/** Position row that follows mid-drag world coords. The EndpointFields
 *  shell stays on doc+clock. This row alone wakes on `version`. */
function EndpointPositionLiveRow(
	{
		engine,
		id,
		editing,
		editor,
	}: {
		engine: Engine;
		id: string;
		editing: boolean;
		editor: EditorBindings | undefined;
	},
) {
	useEngineVersion(engine);
	// Read the pin from the live doc here. Not from a shell prop.
	// Mid-drag placement mutates `endpointPosition` inside a transaction
	// that leaves `docVersion` quiet, so a parent-computed `pinned` stays
	// at the pre-drag point for the whole gesture.
	const atEnd = parseEndpointStageId(id);
	const pinned = atEnd
		? engine.doc.entities?.sessions?.[atEnd.sessionId]
			?.endpointPosition?.[atEnd.side] ?? null
		: null;
	const live = findEndpoint(engine.world, id);
	const at = pinned ?? live?.position ?? null;
	return (
		<PositionRow
			noun="end"
			pinned={pinned}
			at={at}
			editing={editing}
			onMove={editor && ((pos) => editor.onRepositionEndpoint(id, pos))}
			onClear={editor && (() => editor.onUnpinEndpoint(id))}
			onPinHere={editor && at
				? () =>
					editor.onRepositionEndpoint(id, {
						x: at.x,
						y: at.y,
					})
				: undefined}
			editSession={editor}
		/>
	);
}

export function EndpointFields(
	{ engine, id, editor }: {
		engine: Engine;
		id: string;
		editor?: EditorBindings | undefined;
	},
) {
	// Shell wakes on doc + playhead via EntityDetails. Mid-drag pins are
	// owned by `EndpointPositionLiveRow` below.
	const info = endpointInfo(engine, id);
	if (!info) {
		return (
			<div style={placeholder}>
				Unknown session end: <Identifier value={id} />
			</div>
		);
	}
	const editing = editor !== undefined;
	return (
		<>
			{
				/* The claim is editable here for the same reason the peer's name is
          editable in its own panel: it is this end's name, and this is the
          panel for this end. It is safe to edit here because it has one
          home, `def[side].designator`, what the end is born claiming, so
          this control reads and writes the same value. Nothing states a
          claim at a moment: an end's tracks carry who attached and what
          proved it, never what it called itself. */
			}
			{editing && editor
				? (
					<InlineTextField
						value={info.designator ?? ""}
						onChange={(next) =>
							editor.onUpdateSessionEndpoint(
								info.sessionId,
								info.side,
								{
									designator: next,
								},
							)}
						ariaLabel={`What end ${info.side} claims to be`}
						editLabel="Edit end claim"
						editSession={editor}
						placeholder={UNNAMED_END_LABEL}
						style={inlineHeadingInput}
					/>
				)
				: (
					<PanelHeading
						mono
						title={info.designator ?? UNNAMED_END_LABEL}
					>
						{info.designator === undefined ? UNNAMED_END_LABEL : <Identifier value={info.designator} />}
					</PanelHeading>
				)}
			<EndpointKindLabel />
			<AttributionChip attribution={info.attributedBy} />
			<div style={placeholder}>
				This is one end of a session, and nothing has proved who is on it. Attach it to a peer on the session
				below, and the peer takes its place here.
			</div>
			<FieldGroup title="Details">
				<div style={kv}>
					{
						/* No "claims" row: the heading above IS the claim, and it is
              where the claim is edited. Showing it twice would put one value
              behind two controls, and a reader who changed the one that does
              not write would learn that the panel lies. What the heading
              means is carried by the chip under it, which says in words that
              nothing has proved the name. */
					}
					{
						/* Upper case, because the session panel titles this end's block
              "End A" and a reader moving between the two is looking at one
              fact. */
					}
					<Field label="end">
						<code style={valueMono}>{info.side.toUpperCase()}</code>
					</Field>
					<Field label="attached to">
						<span style={valueText}>nobody</span>
					</Field>
					<EndpointPositionLiveRow
						engine={engine}
						id={id}
						editing={editing}
						editor={editor}
					/>
				</div>
			</FieldGroup>
			<FieldGroup title="Timing">
				<div style={kv}>
					{
						/* This end's own attachments, and nothing else. An end exists for
              exactly as long as its session does, so its start and end are
              the session's and are edited there; what happens at the other
              end is that end's. What IS this end's is the moment somebody
              attaches to it, which is the moment this placeholder gives way
              to a peer. */
					}
					<SessionMoments
						engine={engine}
						sessionId={info.sessionId}
						properties={[info.side]}
						editor={editor}
					/>
					{/* Last row of Timing, where every other panel puts it. */}
					<Field label="status">
						{info.onStage ? <ActivityChip activity={info.activity} /> : (
							<LifecycleChip
								status="off-stage"
								entity="session"
							/>
						)}
					</Field>
				</div>
			</FieldGroup>
		</>
	);
}

/** The session this end belongs to, and the peer on the far side of it when
 *  there is one. An end's only connection is its own session. That is what
 *  makes it an end rather than a node. */
export function EndpointConnections(
	{ engine, id, onSelect, entitySelection }: {
		engine: Engine;
		id: string;
		onSelect: (selection: StageSelection) => void;
		entitySelection?: ReadonlySet<EntityRefKey> | undefined;
	},
) {
	const at = parseEndpointStageId(id);
	const s = at ? sessionInfo(engine, at.sessionId) : null;
	if (!at || !s) return null;
	const live = findSession(engine.world, at.sessionId);
	// The node on the other end, named by whichever peer is there. An end
	// opposite another loose end has no peer to name, and says so.
	const otherSide = SESSION_SIDES.find((side) => side !== at.side) ?? "b";
	const otherNode = live ? live.endpoints[otherSide] : s[otherSide];
	const other = peerInfo(engine, otherNode);
	return (
		<div style={linkRowList}>
			<SessionLinkRow
				codec={s.codec}
				captpVersion={s.captpVersion}
				name={other?.label ??
					`${captpVersionLabel(s.captpVersion)} session`}
				state={s.state}
				lifecycle={s.lifecycle}
				selected={isInSelection(entitySelection, {
					kind: "session",
					id: at.sessionId,
				})}
				onClick={() => onSelect({ kind: "session", id: at.sessionId })}
			/>
		</div>
	);
}
