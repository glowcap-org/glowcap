/**
 * Inspector field widgets: a labeled row, a group, pickers, and
 * the typed/scrubbed inputs every panel builds from.
 */

import { useState } from "react";
import type { CSSProperties, ReactNode } from "react";
import type { EngineError } from "../../engine/errors.ts";
import type { PeerProfile } from "../../schema/topology.ts";
import { PROFILE_OPTIONS } from "../../schema/topology.ts";
import { FieldError } from "../error/FieldError.tsx";
import { ScrubInput } from "../Timeline/ScrubInput.tsx";
import { formatTime, formatTimeInput, parseTime } from "../format.ts";
import { pickerLabelFor, type PickerOption } from "./picker-labels.ts";
import type { EditorBindings } from "./bindings.ts";
import type { EditBracket } from "./edit-bracket.ts";
import { useEditBracket, usePendingEdit } from "./edit-bracket.ts";
import {
	fieldGroup,
	fieldGroupBox,
	fieldLineStyle,
	fieldNoteStyle,
	fieldValueStyle,
	groupTitle,
	inlineMonoInput,
	inlineSelectInput,
	keyStyle,
} from "./styles.tsx";

/** One field row: a key and the value it names.
 *
 *  It is one element rather than two loose cells because the line under
 *  a field belongs to the field. A row whose value needs two layout
 *  rows, a trajectory moment's time above the controls that moment
 *  states, is still one field and still carries one line, under the
 *  pair, and nothing has to remember to leave the line out of the
 *  middle. `.ocv-field` in styles.css draws it and re-inherits the `kv`
 *  grid's tracks, so the keys stay in a column across the group.
 *
 *  `note` is a remark about the value rather than a value of its own,
 *  so it rides inside the row instead of becoming a field the line
 *  would separate from what it is talking about.
 *
 *  `below` is the second layout row of a field that needs one. It is a
 *  prop rather than part of `children` so the field can tell its first
 *  line from its second: only the first gets the height lockup. */
export function Field(
	{ label, note, below, children }: {
		label: ReactNode;
		note?: ReactNode;
		below?: ReactNode;
		children: ReactNode;
	},
) {
	return (
		<div className="ocv-field">
			<span style={keyStyle}>{label}</span>
			<div style={fieldValueStyle}>
				<div style={fieldLineStyle}>{children}</div>
				{below !== undefined && below !== null && below}
				{note !== undefined && note !== null && <div style={fieldNoteStyle}>{note}</div>}
			</div>
		</div>
	);
}

export function EditableIdField(
	{ kind, id, editor }: {
		kind: "peer" | "session" | "message";
		id: string;
		editor: EditorBindings;
	},
) {
	// The draft starts at the committed id and stays local until the
	// field commits. Nothing syncs the prop back into it, because
	// nothing has to: App keys the whole Details subtree on
	// `${anchor.kind}:${anchor.id}`, so a committed rename mounts a
	// fresh field at the new id and this state starts over. A sync
	// effect beside that key was a second mechanism for the same job,
	// and it was the one that ran a paint behind.
	const [draft, setDraft] = useState(id);
	const [error, setError] = useState<EngineError | null>(null);

	const commit = () => {
		const next = draft.trim();
		if (next === id) {
			setError(null);
			return;
		}
		if (next.length === 0) {
			// Treat empty as a revert, don't try to rename to "".
			setDraft(id);
			setError(null);
			return;
		}
		const v = editor.validateRename(kind, id, next);
		if (!v.ok) {
			setError(v.error);
			return;
		}
		const r = editor.onRename(kind, id, next);
		setError(r.ok ? null : r.error);
	};
	// Blur is what a reader means by "done", and it is not the only way
	// they get there: clicking a different entity on the stage unmounts
	// this field with the caret still in it and no blur behind it. The
	// pending edit hands the draft up on either path and on neither
	// twice, so the rename cannot be dropped and cannot be replayed
	// against the id it has already changed.
	const pending = usePendingEdit(commit);

	return (
		<div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
			<input
				type="text"
				className="ocv-input"
				value={draft}
				onChange={(ev) => {
					setDraft(ev.target.value);
					pending.touch();
					// Clear stale error as the user keeps typing, they're
					// already correcting.
					if (error) setError(null);
				}}
				onBlur={() => pending.settle()}
				onKeyDown={(ev) => {
					if (ev.key === "Enter") {
						ev.currentTarget.blur();
					} else if (ev.key === "Escape") {
						// Say no to the edit before leaving, not by putting the
						// draft back: `setDraft` has not landed by the time the
						// blur below runs, so a commit reading the draft would
						// read the one the reader just abandoned and rename
						// anyway. The put-back is what the reader then sees.
						pending.discard();
						setDraft(id);
						setError(null);
						ev.currentTarget.blur();
					}
				}}
				spellCheck={false}
				style={inlineMonoInput}
				aria-invalid={error !== null}
				aria-label={`${kind} id`}
			/>
			<FieldError error={error} />
		</div>
	);
}

export function FieldGroup(
	{ title, children }: { title: string; children: ReactNode },
) {
	return (
		<div style={fieldGroup}>
			<div style={groupTitle}>{title}</div>
			<div style={fieldGroupBox}>{children}</div>
		</div>
	);
}

/** What a picker offers for "no choice at all", as a value. An end
 *  attached to nobody, and an end nothing attributed, are real states
 *  rather than missing ones, so each picker carries an option for them
 *  and the empty string is what a `<select>` can hold. */
export const NONE = "";

/** How the two "none" states read to a person.
 *
 *  They are ordinary states of the network rather than fields somebody
 *  forgot to fill, so each is spelled as an answer to the question its
 *  row asks. "Attached to" asks about a party, so the answer is a
 *  pronoun, "attribution" asks about a thing, so the answer is a noun.
 *  Neither is "loose", which is the word the model uses for an end
 *  nothing attributed and not a word a reader arrives with.
 *
 *  They are plain words rather than parenthesized ones:
 *  brackets read as chrome around an empty field, which is the reading
 *  these two states most need to avoid.
 *
 *  They live here because two surfaces ask the same question about one
 *  end, the session panel about the end a session is born with, and a
 *  trajectory row about the end at a moment, and two spellings of one
 *  word is where they would drift. */
export const NOBODY = "nobody";
export const NOTHING = "nothing";

export function EnumSelect<T extends string>(
	{ value, options, ariaLabel, onChange, labelFor, disabledReason }: {
		value: T;
		options: readonly T[];
		ariaLabel: string;
		onChange: (next: T) => void;
		labelFor?: (v: T) => string;
		/** Why this control cannot take effect right now, in words. A
		 *  picker whose write the engine would refuse is worse than no
		 *  picker: the reader changes it and nothing happens. Set this and
		 *  it is disabled, wearing the reason as its tooltip. */
		disabledReason?: string | undefined;
	},
) {
	return (
		<select
			className="ocv-select"
			value={value}
			onChange={(e) => onChange(e.target.value as T)}
			aria-label={ariaLabel}
			style={inlineSelectInput}
			{...(disabledReason !== undefined ? { disabled: true, title: disabledReason } : {})}
		>
			{offeredWith(options, value).map((o) => <option key={o} value={o}>{labelFor ? labelFor(o) : o}</option>)}
		</select>
	);
}

/**
 * The picker that asks which peer is on an end.
 *
 * Two rows ask that question, the end a session is born with, and the
 * moment somebody attaches to it, and they are one control, because a
 * reader meets the same list of peers in both and should read it the same
 * way. The names come from `pickerLabels`, so a document with two peers
 * called Alice says which Alice in both places or in neither.
 *
 * "Nobody" is an answer only where it is a legal one. A session's genesis
 * end may hold nobody. A moment that attaches an end cannot, because an
 * attachment names somebody by definition and an end comes loose by
 * losing the moment instead.
 */
export function PeerSelect(
	{ value, peers, ariaLabel, nobody = false, onChange, disabledReason }: {
		/** The peer on this end, or `NONE` when nobody is. */
		value: string;
		peers: readonly PickerOption[];
		ariaLabel: string;
		nobody?: boolean;
		/** The chosen peer's id, or `NONE` when the reader chose nobody. */
		onChange: (peerId: string) => void;
		disabledReason?: string | undefined;
	},
) {
	const labelFor = pickerLabelFor(peers);
	const ids = peers.map((p) => p.id);
	return (
		<EnumSelect
			value={value}
			options={nobody ? [NONE, ...ids] : ids}
			ariaLabel={ariaLabel}
			labelFor={(v) => v === NONE ? NOBODY : labelFor(v)}
			onChange={onChange}
			{...(disabledReason !== undefined ? { disabledReason } : {})}
		/>
	);
}

/** The options a select offers, with the value it is holding
 *  among them.
 *
 *  A controlled `<select>` whose value matches no option shows the
 *  first one instead, and then the panel is stating a value the entity
 *  does not carry. That is reachable wherever the offered list is a
 *  shortlist rather than a domain: a peer's profile is any non-empty
 *  string, so a feed or an imported document can hand a picker
 *  something `PROFILE_OPTIONS` never named, and a select left to its
 *  own devices would report it as "glowcap" while the chip beside it
 *  and the stage both showed the truth.
 *
 *  Nothing is added when the value is already offered, so a closed
 *  domain is unaffected. */
function offeredWith<T extends string>(
	options: readonly T[],
	value: T,
): readonly T[] {
	return options.includes(value) ? options : [...options, value];
}

/** Native `<select>` styled with `.ocv-select`. Was a segmented
 * control first, but the three pills overflowed the kv value
 * column at default pane width.
 *
 * The offer is `PROFILE_OPTIONS`, and a peer running something not on
 * that list still has to be choosable, or the select would lie. */
export function ProfileSelect(
	{ value, onChange }: {
		value: PeerProfile;
		onChange: (profile: PeerProfile) => void;
	},
) {
	return (
		<select
			className="ocv-select"
			value={value}
			onChange={(e) => onChange(e.target.value as PeerProfile)}
			aria-label="Peer profile"
			style={inlineSelectInput}
		>
			{offeredWith(PROFILE_OPTIONS, value).map((p) => <option key={p} value={p}>{p}</option>)}
		</select>
	);
}

/** Bulk-edit variant of `EnumSelect`. `commonValue` is the shared
 *  value across the selection, or `null` when entities disagree.
 *  In the mixed case the select renders a leading "—" sentinel
 *  option (no commit on its own). Picking any concrete option
 *  fires `onChange` and the caller broadcasts to every selected
 *  entity. The "—" sentinel doesn't dispatch, there's
 *  no canonical "make it mixed" intent. */
export function BulkEnumSelect<T extends string>(
	{ commonValue, options, ariaLabel, onChange, labelFor }: {
		commonValue: T | null;
		options: readonly T[];
		ariaLabel: string;
		onChange: (next: T) => void;
		labelFor?: (v: T) => string;
	},
) {
	const MIXED = "__mixed__";
	const selected = commonValue ?? MIXED;
	return (
		<select
			className="ocv-select"
			value={selected}
			onChange={(e) => {
				if (e.target.value === MIXED) return;
				onChange(e.target.value as T);
			}}
			aria-label={ariaLabel}
			style={inlineSelectInput}
		>
			{commonValue === null && <option value={MIXED}>— mixed —</option>}
			{(commonValue === null ? options : offeredWith(options, commonValue)).map(
				(o) => (
					<option key={o} value={o}>
						{labelFor ? labelFor(o) : o}
					</option>
				),
			)}
		</select>
	);
}

export function TimeScrubInput(
	{
		value,
		min = 0,
		max,
		strictMax = false,
		onChange,
		label,
		style,
		onScrubStart,
		onScrubEnd,
	}: {
		value: number;
		/** Lower bound for the scrub. Defaults to 0. Entity-specific
		 *  containment constraints (e.g. "session.closed can't be
		 *  earlier than session.opened") raise this so the scrub
		 *  can't produce an invalid state. */
		min?: number;
		max: number;
		/** When true, `max` is a HARD ceiling. The scrub clamps to
		 *  it and never extends. Used when the upper bound comes from
		 *  a containment constraint (e.g. "session.closed can't be
		 *  later than peerA.left"). When false (default), `max` is a
		 *  soft hint and the scrub extends generously so the user can
		 *  drag past the current doc duration and have the engine
		 *  auto-extend duration to match. */
		strictMax?: boolean;
		onChange: (next: number) => void;
		label: string;
		/** Drag-session brackets forwarded to ScrubInput, see its
		 *  contract. Rows wrap them in an edit transaction so one scrub
		 *  is one undo step. */
		onScrubStart?: (() => void) | undefined;
		onScrubEnd?: (() => void) | undefined;
		/** Forwarded to ScrubInput. Used by callers (OptionalTimeRow) to
		 *  make the scrub fill its flex container so a sibling ✕ button
		 *  is pushed to the right edge. */
		style?: CSSProperties;
	},
) {
	return (
		<ScrubInput
			value={value}
			onChange={onChange}
			min={Math.max(0, min)}
			max={strictMax ? max : Math.max(max, value * 1.5, 60_000)}
			format={formatTime}
			formatInput={formatTimeInput}
			parse={parseTime}
			label={label}
			linear
			// Linear sensitivity: 1px ≈ 10 ms by default. Shift slows to
			// ~1 ms/px (fine); alt speeds to ~100 ms/px (coarse).
			pxPerDoubling={0.1}
			{...(style ? { style } : {})}
			{...(onScrubStart ? { onScrubStart } : {})}
			{...(onScrubEnd ? { onScrubEnd } : {})}
		/>
	);
}

/** Inline text field with the inspector's edit-bracket:
 * focus opens a labeled transaction so a typing burst lands as one
 * undo step. Blur closes it. The one spelling of the editable-text
 * idiom, heading and mono variants come in via `style`. */
export function InlineTextField(
	{
		value,
		onChange,
		ariaLabel,
		editLabel,
		editSession,
		placeholder,
		style,
		submitOnEnter = false,
	}: {
		value: string;
		onChange: (next: string) => void;
		/** What this field edits, for anyone who cannot see the row label
		 *  beside it. Required rather than defaulted, because the two
		 *  strings this field already carries are the wrong ones to borrow:
		 *  `editLabel` is a verb phrase written for the undo menu, and a
		 *  placeholder is what an EMPTY field shows, so it disappears as a
		 *  name exactly when the field has content. */
		ariaLabel: string;
		/** Undo label for the typing burst. */
		editLabel: string;
		editSession: EditBracket | undefined;
		placeholder: string;
		style: CSSProperties;
		/** Treat the field as a one-line form: Enter finishes it.
		 *
		 *  Enter BLURS rather than committing directly, so there stays exactly one
		 *  commit path. A second one would have to close the edit bracket itself, and
		 *  the bracket is the thing that must not be closed twice. A field that
		 *  committed on Enter and again on the blur Enter caused would bracket one
		 *  edit as two.
		 *
		 *  Off by default. A field inside a panel that is already tracking an entity
		 *  has no form to submit, and taking Enter there would swallow a key the
		 *  surrounding UI may want. */
		submitOnEnter?: boolean;
	},
) {
	const bracket = useEditBracket(editSession);
	return (
		<input
			type="text"
			className="ocv-input"
			aria-label={ariaLabel}
			value={value}
			onChange={(ev) => onChange(ev.target.value)}
			onFocus={() => bracket.begin(editLabel)}
			onBlur={() => bracket.end()}
			onKeyDown={submitOnEnter
				? (ev) => {
					if (ev.key === "Enter") ev.currentTarget.blur();
				}
				: undefined}
			placeholder={placeholder}
			spellCheck={false}
			style={style}
		/>
	);
}
