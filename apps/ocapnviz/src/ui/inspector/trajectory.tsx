/**
 * Inspector widgets for a temporal property: a moment's value, an
 * insert-at-playhead control, and the optional start/end time row.
 */

import type { CSSProperties, ReactNode } from "react";
import { ClearGlyph } from "../glyphs.tsx";
import type { EndpointAttachment, EndpointAttribution } from "../../schema/session-end.ts";
import { attachedTo, backedBy } from "../../schema/session-end.ts";
import type { SessionValue, TrajectoryDisplay } from "../../engine/trajectory.ts";
import type { EditBracket } from "./edit-bracket.ts";
import { useScrubBracket } from "./edit-bracket.ts";
import { EnumSelect, Field, InlineTextField, NONE, NOTHING, PeerSelect, TimeScrubInput } from "./fields.tsx";
import type { PickerOption } from "./picker-labels.ts";
import {
	belowRowStyle,
	endRowButtonStyle,
	endRowIconButtonStyle,
	endRowScrubStyle,
	endRowStyle,
	inlineMonoInput,
	inlineSelectInput,
	valueMono,
} from "./styles.tsx";
import { formatTime } from "../format.ts";
import { c, FONT, SPACE } from "../tokens.ts";

export function TrajectoryValue(
	{ property, value, editing, editSession, onChange, nameOfPeer }: {
		property: TrajectoryDisplay;
		/** What the property carries at this moment, in its own value
		 *  channel: one word, or the pair an end attaches by. */
		value: SessionValue;
		editing: boolean;
		editSession: EditBracket | undefined;
		onChange: (next: SessionValue) => void;
		/** What a person calls one of the peers this row can attach to.
		 *
		 *  Only the attachment editor asks, because it is the only row whose
		 *  value is an entity rather than a word, and only a caller holding
		 *  the document can answer. Left out, every peer reads as its own id,
		 *  which is what `pickerLabels` says about a thing nobody named. */
		nameOfPeer?: (peerId: string) => string | undefined;
	},
) {
	const { noun, editor } = property;
	// The one word that names this value, for the controls and the readings
	// that show a single string. An end's pair answers with its peer.
	const named = typeof value === "string" ? value : value.peer;
	return (
		<span style={trajectoryValueStyle}>
			{
				/* The property's name is the row's label, not part of its
          value. `noun` names the control for a screen reader and
          fills the empty-field placeholder. */
			}
			<span style={trajectoryEditorStyle}>
				{editing && editor.kind === "text"
					? (
						<InlineTextField
							value={named}
							onChange={onChange}
							ariaLabel={`New ${noun}`}
							editLabel={`Edit ${noun}`}
							editSession={editSession}
							placeholder={noun}
							style={inlineMonoInput}
						/>
					)
					: editing && editor.kind === "enum"
					? (
						<EnumSelect
							value={named}
							options={editor.options}
							ariaLabel={`New ${noun}`}
							onChange={onChange}
						/>
					)
					: editing && editor.kind === "attachment"
					? (
						<AttachmentEditor
							noun={noun}
							peers={editor.peers.map((id) => ({
								id,
								name: nameOfPeer?.(id),
							}))}
							attributions={editor.attributions}
							value={typeof value === "string" ? { peer: value } : value}
							onChange={onChange}
						/>
					)
					: <code style={valueMono}>{named}</code>}
			</span>
		</span>
	);
}

/** The two controls one end's moment is: the peer it attaches to, and
 *  what backed that.
 *
 *  Both, because the value IS the pair. A row offering only the peer could
 *  not state what a signed handoff proved, and restating the peer rewrote a
 *  proven attachment as one nothing backed. So the recording held a shape
 *  Build could not author, and touching the row destroyed it.
 *
 *  The peer picker offers no "nobody": a moment ATTACHES an end, and an end
 *  comes loose by losing the moment or by being born loose, which is the
 *  session panel's row 0. The attribution picker does offer "nothing",
 *  because an author may attach an end having measured nothing, and that is
 *  what the one-way invariant allows. */
function AttachmentEditor(
	{ noun, peers, attributions, value, onChange }: {
		noun: string;
		peers: readonly PickerOption[];
		attributions: readonly EndpointAttribution[];
		value: EndpointAttachment;
		onChange: (next: EndpointAttachment) => void;
	},
) {
	return (
		<span style={attachmentEditorStyle}>
			<span style={attachmentControlStyle}>
				<PeerSelect
					value={value.peer}
					peers={peers}
					ariaLabel={`New ${noun}`}
					onChange={(peer) => onChange(attachedTo(value, peer))}
				/>
			</span>
			<span style={attachmentControlStyle}>
				<EnumSelect
					value={value.attributedBy ?? NONE}
					options={[NONE, ...attributions]}
					ariaLabel={`What attributed ${noun}`}
					labelFor={(v) => v === NONE ? NOTHING : v}
					onChange={(v) =>
						onChange(
							backedBy(
								value,
								v === NONE ? undefined : v as EndpointAttribution,
							),
						)}
				/>
			</span>
		</span>
	);
}

/** The pair's two selects share the cell and each may shrink, for the same
 *  reason the cell itself may: a select is `width: 100%`, which resolves
 *  against its own box, so two left to themselves each take the whole cell
 *  and the second lands outside the row. */
const attachmentEditorStyle: CSSProperties = {
	display: "flex",
	gap: SPACE.xs,
	minWidth: 0,
};

const attachmentControlStyle: CSSProperties = {
	flex: 1,
	minWidth: 0,
};

const trajectoryValueStyle: CSSProperties = {
	display: "flex",
	alignItems: "flex-start",
	gap: SPACE.xs,
	minWidth: 0,
};

const trajectoryEditorStyle: CSSProperties = {
	flex: 1,
	minWidth: 0,
};

/** The "state another property here" control for a trajectory. One
 *  property is one button that names it. Several are a menu, because
 *  a button per property turns into a wall of them as properties are
 *  added. The menu picks and inserts in one gesture and keeps no
 *  selection of its own. There is nothing to remember between
 *  insertions. */
export function TrajectoryInsert<P extends string>(
	{ properties, describe, onInsert }: {
		properties: readonly P[];
		describe: (property: P) => TrajectoryDisplay;
		onInsert: (property: P) => void;
	},
) {
	const nounOf = (property: P) => describe(property).noun;
	const only = properties.length === 1 ? properties[0] : undefined;
	if (only !== undefined) {
		return (
			<button
				type="button"
				className="ocv-btn"
				onClick={() => onInsert(only)}
				title={`State a new ${nounOf(only)} at the playhead`}
				style={{ ...endRowButtonStyle, width: "100%" }}
			>
				+ {nounOf(only)} @playhead
			</button>
		);
	}
	return (
		<select
			className="ocv-select"
			value=""
			aria-label="State a property at the playhead"
			style={inlineSelectInput}
			onChange={(e) => {
				const picked = e.target.value as P | "";
				if (picked !== "") onInsert(picked);
			}}
		>
			<option value="">+ state @playhead…</option>
			{properties.map((property) => (
				<option key={property} value={property}>
					{nounOf(property)}
				</option>
			))}
		</select>
	);
}

export function OptionalTimeRow(
	{
		label,
		below,
		note,
		t,
		editing,
		onMove,
		onClear,
		onSetAtPlayhead,
		min,
		max,
		strictMax,
		scrubLabel,
		editSession,
	}: {
		label: string;
		below?: ReactNode;
		/** A remark about this time, such as the clamp hint. Rides inside
		 *  the row, because it is about the row's value rather than a
		 *  field of its own. */
		note?: ReactNode;
		/** Resolved value to display when the side is EXPLICIT on
		 *  `entity.timing`. `null` means the side is implicit (eternal-
		 *  start or eternal-end), render the placeholder / set-at-
		 *  playhead UI. Single source of truth: the entity's timing,
		 *  not any observation. */
		t: number | null;
		editing: boolean;
		onMove: ((t: number) => void) | undefined;
		onClear: (() => void) | undefined;
		onSetAtPlayhead: (() => void) | undefined;
		min: number;
		max: number;
		strictMax: boolean;
		scrubLabel: string;
		/** Edit-transaction brackets (`EditorBindings` subset), a time
		 *  scrub becomes one undo step. Required so a call site cannot
		 *  silently ship unbracketed scrubs. Pass the editor
		 *  (undefined outside Build). */
		editSession: EditBracket | undefined;
	},
) {
	const session = useScrubBracket(editSession, scrubLabel);
	return (
		<Field
			label={label}
			note={note}
			below={below && <div style={belowRowStyle(editing)}>{below}</div>}
		>
			<span style={endRowStyle}>
				{t !== null
					? (
						<>
							{editing && onMove
								? (
									<span style={endRowScrubStyle}>
										<TimeScrubInput
											value={t}
											min={min}
											max={max}
											strictMax={strictMax}
											onChange={onMove}
											label={scrubLabel}
											{...session}
											// Either way the wrapper grows and the input
											// fills it, so the ✕ (if any) docks at the row's
											// right edge and the digits are a target rather
											// than a sliver.
											style={{ width: "100%" }}
										/>
									</span>
								)
								: <code style={valueMono}>{formatTime(t)}</code>}
							{editing && onClear && (
								<button
									type="button"
									className="ocv-btn is-icon"
									onClick={onClear}
									title={`Clear ${label} time`}
									style={endRowIconButtonStyle}
									aria-label={`Clear ${label} time`}
								>
									<ClearGlyph />
								</button>
							)}
						</>
					)
					: editing && onSetAtPlayhead
					? (
						<button
							type="button"
							className="ocv-btn"
							onClick={onSetAtPlayhead}
							title={`Set ${label} at the playhead`}
							style={{ ...endRowButtonStyle, flex: 1 }}
						>
							Insert @playhead
						</button>
					)
					: (
						<span style={{ ...valueMono, color: c.textSubtle }}>
							—
						</span>
					)}
			</span>
		</Field>
	);
}

/** Small ghost-text indicator rendered under a time row when the
 * user's stored intent has been clamped by an ancestor context.
 * Hides itself when stored equals effective, no noise when there's
 * nothing to surface. The `reason` names which parent clamped (e.g.
 * "peer alice", "session phone-speaker"), the side is already
 * implicit from which field the hint sits under.
 *
 * It is a row's `note` rather than a row of its own: a hairline
 * between a time and the sentence explaining that time would separate
 * the two things a reader has to read together. */
export function DivergenceHint(
	{ reason }: { reason: string | null },
) {
	if (!reason) return null;
	return (
		<span
			style={{
				fontFamily: FONT.sans,
				color: c.textSubtle,
				fontSize: "0.85em",
				fontStyle: "italic",
			}}
			title={`This time is held inside ${reason}'s own span, so the value stored here cannot take effect until that span reaches it.`}
		>
			clamped by {reason}
		</span>
	);
}
