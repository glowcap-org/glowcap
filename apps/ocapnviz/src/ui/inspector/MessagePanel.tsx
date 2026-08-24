/**
 * Message inspector panel — Details + Timing (`MessageFields`) and
 * the Connections sub-panel showing from-peer, to-peer, and the
 * carrying session (`MessageConnections`). Messages are transient
 * (only live between `message-sent` and `message-delivered`), but
 * the panel stays populated across the whole timeline so the user
 * can inspect off-stage messages too.
 */

import type { StageSelection } from "../../render/types.ts";
import type { Engine } from "../../engine/engine.ts";
import { findMessageInDoc } from "../../engine/event-helpers.ts";
import { messageEffective } from "../../engine/temporal/doc-resolver.ts";
import { PayloadViewer } from "./PayloadViewer.tsx";
import { LifecycleChip, type LifecycleStatus, MessageKindLabel } from "../EntityChips.tsx";
import { EditableIdField, EnumSelect, Field, FieldGroup, InlineTextField, TimeScrubInput } from "./fields.tsx";
import type { EditorBindings } from "./bindings.ts";
import { useScrubBracket } from "./edit-bracket.ts";
import { DivergenceHint, OptionalTimeRow } from "./trajectory.tsx";
import { PeerLinkRow, SessionLinkRow, Unknown } from "./links.tsx";
import {
	endRowScrubStyle,
	inlineHeadingInput,
	kv,
	linkRowList,
	PanelHeading,
	subSection,
	subSectionLabel,
	valueMono,
} from "./styles.tsx";
import { formatTime } from "../format.ts";
import { pickerLabelFor } from "./picker-labels.ts";
import { elideIdentifier, Identifier } from "../identifier.tsx";
import { isInSelection, messageInfo, peerInfo, sessionInfo } from "./entity-info.ts";
import { sessionPairName } from "../session-name.ts";
import type { EntityRefKey } from "../../interactions/types.ts";
import type { Codec } from "../../schema/topology.ts";
import { UNNAMED_PROFILE } from "../../schema/topology.ts";
import type { Observation } from "../../engine/temporal/recording.ts";

/** The part of a `message-sent` observation the Payload group reads.
 *  Taken from the schema rather than restated, so a field that moves
 *  there fails the build here. */
export type MessagePayloadFields = Pick<
	Extract<Observation, { kind: "message-sent" }>,
	"bytesB64" | "byteLen" | "bytesCodec" | "provenance"
>;

/** What the Payload group hands the viewer for one message.
 *
 * Split out of the panel because two of the three answers are easy
 * to get wrong and neither is visible in a screenshot. The codec is
 * the frame's own when the recording stated one and the carrying
 * session's otherwise, so a handshake frame on a Cap'n Proto session
 * is spaced as the Syrup it is (ADR-0103). The bytes stay `undefined`
 * rather than being suppressed, because the viewer owes an absent
 * payload a sentence. */
export function payloadProps(
	sentEv: MessagePayloadFields | null | undefined,
	sessionCodec: Codec | undefined,
): {
	bytesB64: string | undefined;
	byteLen: number | undefined;
	codec: Codec | undefined;
	derivedFrom: readonly string[] | undefined;
} {
	return {
		bytesB64: sentEv?.bytesB64,
		byteLen: sentEv?.byteLen,
		codec: sentEv?.bytesCodec ?? sessionCodec,
		derivedFrom: sentEv?.provenance?.["prov:wasDerivedFrom"],
	};
}

function findMessageInFlight(engine: Engine, id: string) {
	for (const e of engine.world.with("messageInFlight", "position")) {
		if (e.messageInFlight.id === id) return e;
	}
	return undefined;
}

export function MessageFields(
	{ engine, id, editor }: {
		engine: Engine;
		id: string;
		editor?: EditorBindings | undefined;
	},
) {
	// No world pin to follow: shell `useDocVersion` + `useClockSnapshot` is
	// enough for playhead-shaped flight and lifecycle.
	// The flight-time row's drag brackets, held by the same thing every
	// other editable row here uses, so a panel that goes away mid-drag
	// cannot leave the transaction open behind it.
	const durationScrub = useScrubBracket(editor, "Message duration");
	const live = findMessageInFlight(engine, id)?.messageInFlight;
	const sentEv = findMessageInDoc(engine.doc, id);
	const def = engine.doc.entities?.messages?.[id];
	if (!live && !sentEv && !def) return <Unknown kind="message" id={id} />;

	const label = live?.label ?? def?.label;
	const from = live?.from ?? def?.from ?? "?";
	const to = live?.to ?? def?.to ?? "?";

	// Containment: a message lives inside its session — can't be sent
	// before session opens, can't arrive after session closes. Bounds
	// read from the carrying session's entity.timing via
	// engine.effectiveStart/End — the authoring source of truth.
	const carryingSessionId = live?.sessionId ?? def?.sessionId;
	const sessionId = live?.sessionId ?? def?.sessionId ?? "?";
	// Arrival reads through the EFFECTIVE span — the same authority
	// the world materializer paints from. The raw event's arrivalT
	// can differ: a live feed stamps arrivalT === t as its
	// "flight unobserved" sentinel and the projection substitutes
	// the default flight, so the event value would show a zero
	// flight (and flip the lifecycle to "after" too early).
	const effective = def !== undefined ? messageEffective(engine.doc, id) : undefined;
	const arrivalT = live?.arrivalT ?? effective?.end ?? sentEv?.arrivalT ?? 0;

	const lifecycle: LifecycleStatus = live
		? "active"
		: sentEv && engine.clock.t < sentEv.t
		? "before"
		: sentEv && engine.clock.t >= arrivalT
		? "after"
		: "off-stage";

	const editing = editor !== undefined;
	const update = editor?.onUpdateMessage;
	const duration = engine.doc.duration;
	// Sessions whose endpoints match the message's {from, to} are
	// valid swap targets. Empty when not editing or message off-stage.
	//
	// Every candidate joins the same two peers, so every candidate has the
	// same name. That is a collision by construction, and `pickerLabels`
	// answers it the way it answers any other: each option says which
	// session it is. Nothing here special-cases it, because a picker that
	// decided for itself when to show an id is the thing this rule
	// replaced.
	const candidateSessions = editing && live
		? [...engine.queries.sessions].filter((s) =>
			(s.endpoints.a === from && s.endpoints.b === to) ||
			(s.endpoints.a === to && s.endpoints.b === from)
		)
		: [];
	const sessionOption = pickerLabelFor(
		candidateSessions.map((s) => ({
			id: s.session.id,
			name: sessionPairName(engine.doc, s.session.id, engine.clock.t),
		})),
	);
	return (
		<>
			{editing
				? (
					<InlineTextField
						value={label ?? ""}
						onChange={(next) => update?.(id, { label: next })}
						ariaLabel="Message label"
						editLabel="Rename message"
						editSession={editor}
						placeholder="Unlabeled message"
						style={inlineHeadingInput}
					/>
				)
				: (
					<PanelHeading
						mono={label !== undefined}
						title={label ?? ""}
					>
						{label ?? "Unlabeled message"}
					</PanelHeading>
				)}
			<MessageKindLabel />
			<FieldGroup title="Details">
				<div style={kv}>
					<Field label="id">
						{editing && editor
							? (
								<EditableIdField
									kind="message"
									id={id}
									editor={editor}
								/>
							)
							: <Identifier value={id} />}
					</Field>
					<Field label="from">
						<Identifier value={from} />
					</Field>
					<Field label="to">
						<Identifier value={to} />
					</Field>
					{editing && (
						<Field label="direction">
							<button
								type="button"
								className="ocv-btn"
								onClick={() => update?.(id, { swapDirection: true })}
								title="Swap sender and receiver"
								style={{
									padding: "0 8px",
									width: "fit-content",
								}}
							>
								swap ↔
							</button>
						</Field>
					)}
					<Field label="session">
						{editing && candidateSessions.length > 1
							? (
								<EnumSelect
									value={sessionId}
									options={candidateSessions.map((s) => s.session.id)}
									ariaLabel="Session carrying this message"
									labelFor={sessionOption}
									onChange={(next) => update?.(id, { sessionId: next })}
								/>
							)
							: <Identifier value={sessionId} />}
					</Field>
				</div>
			</FieldGroup>
			{/* Always shown: see `payloadProps`. */}
			<FieldGroup title="Payload">
				<PayloadViewer
					{...payloadProps(
						sentEv,
						sessionInfo(engine, sessionId)?.codec,
					)}
				/>
			</FieldGroup>
			<FieldGroup title="Timing">
				<div style={kv}>
					<OptionalTimeRow
						label="start"
						t={def?.timing?.start.explicit ? engine.intrinsicStart("messages", id) : null}
						editing={editing}
						onMove={editing && editor?.onSetMessageStart
							? (t) => editor.onSetMessageStart(id, t)
							: undefined}
						onClear={editor?.onClearMessageStart ? () => editor.onClearMessageStart(id) : undefined}
						onSetAtPlayhead={editor?.onSetMessageStart
							? () => editor.onSetMessageStart(id, engine.clock.t)
							: undefined}
						min={carryingSessionId
							? engine.effectiveStart(
								"sessions",
								carryingSessionId,
							)
							: 0}
						max={def?.timing ? def.timing.start.value + def.timing.duration.value : duration}
						strictMax={def?.timing?.duration.explicit === true}
						scrubLabel="Message start time"
						editSession={editor}
						note={
							<DivergenceHint
								reason={engine.clampReason(
									"messages",
									id,
									"start",
								)}
							/>
						}
					/>
					<Field
						label="duration"
						note={
							<DivergenceHint
								reason={engine.clampReason(
									"messages",
									id,
									"end",
								)}
							/>
						}
					>
						{editing && editor && def?.timing
							? (
								<span style={endRowScrubStyle}>
									<TimeScrubInput
										value={def.timing.duration.value}
										min={0}
										max={Math.max(
											0,
											(carryingSessionId
												? engine.effectiveEnd(
													"sessions",
													carryingSessionId,
												)
												: duration) -
												def.timing.start.value,
										)}
										strictMax={carryingSessionId !==
											undefined}
										onChange={(dur) =>
											editor.onSetMessageDuration(
												id,
												dur,
											)}
										label="Message duration"
										{...durationScrub}
										// The one timing row with no ✕ beside it — a message
										// always has a flight. It still fills the value column,
										// so its digits sit where every other row's time does.
										style={{ width: "100%" }}
									/>
								</span>
							)
							: (
								<code style={valueMono}>
									{formatTime(
										arrivalT -
											(def?.timing?.start.value ?? 0),
									)}
								</code>
							)}
					</Field>
					<Field label="status">
						<LifecycleChip status={lifecycle} entity="message" />
					</Field>
				</div>
			</FieldGroup>
		</>
	);
}

export function MessageConnections(
	{ engine, id, onSelect, entitySelection }: {
		engine: Engine;
		id: string;
		onSelect: (selection: StageSelection) => void;
		/** Multi-select awareness: each row checks whether its target
		 *  (peer or session) is in the entitySelection and renders
		 *  the "in selection" treatment. */
		entitySelection?: ReadonlySet<EntityRefKey> | undefined;
	},
) {
	// From / to / carrier-session ids come through `messageInfo` so
	// every Connections sub-panel resolves identities through the
	// same `entity-info` shim — same as `peerInfo` / `sessionInfo`
	// — instead of reaching into the doc directly here.
	const info = messageInfo(engine, id);
	if (!info) return null;
	const { fromId, toId, sessionId } = info;
	const from = peerInfo(engine, fromId);
	const to = peerInfo(engine, toId);
	const session = sessionInfo(engine, sessionId);

	return (
		<>
			<div style={subSection}>
				<div style={subSectionLabel}>From peer</div>
				<div style={linkRowList}>
					<PeerLinkRow
						peerLabel={from?.label ?? elideIdentifier(fromId)}
						peerProfile={from?.profile ?? UNNAMED_PROFILE}
						{...(from ? { lifecycle: from.lifecycle } : {})}
						selected={isInSelection(entitySelection, {
							kind: "peer",
							id: fromId,
						})}
						onClick={() => onSelect({ kind: "peer", id: fromId })}
					/>
				</div>
			</div>

			<div style={subSection}>
				<div style={subSectionLabel}>To peer</div>
				<div style={linkRowList}>
					<PeerLinkRow
						peerLabel={to?.label ?? elideIdentifier(toId)}
						peerProfile={to?.profile ?? UNNAMED_PROFILE}
						{...(to ? { lifecycle: to.lifecycle } : {})}
						selected={isInSelection(entitySelection, {
							kind: "peer",
							id: toId,
						})}
						onClick={() => onSelect({ kind: "peer", id: toId })}
					/>
				</div>
			</div>

			{session && (
				<div style={subSection}>
					<div style={subSectionLabel}>Carried over</div>
					<div style={linkRowList}>
						<SessionLinkRow
							codec={session.codec}
							captpVersion={session.captpVersion}
							// The pair the session joins, from the one place that
							// derives it. This row used to build the pair itself out
							// of the message's sender and the peer on the far end,
							// which read the same most of the time and differed
							// whenever an end was loose.
							name={sessionPairName(
								engine.doc,
								sessionId,
								engine.clock.t,
							)}
							state={session.state}
							lifecycle={session.lifecycle}
							selected={isInSelection(entitySelection, {
								kind: "session",
								id: sessionId,
							})}
							onClick={() => onSelect({ kind: "session", id: sessionId })}
						/>
					</div>
				</div>
			)}
		</>
	);
}
