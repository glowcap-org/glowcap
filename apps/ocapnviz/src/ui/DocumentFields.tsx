/**
 * What a document says about itself, readable and editable in place.
 *
 * The other half of the panel `SourcePicker` opens: that one says where the
 * buffer came from and how to swap it, this one says what the buffer IS. Two
 * files because they are two questions, a document's identity does not change
 * when you load a different one, it is simply a different document's identity.
 *
 * It is built out of the Inspector's own parts rather than out of new ones:
 * `Field`'s key-and-value rows with the hairline under each, `kv`'s grid,
 * `valueName` for a value. Reading a document is the same act as reading a peer,
 * so it should not be a second thing to learn, and anything spelled fresh here
 * would be one more place for the panel's type sizes and insets to drift.
 *
 * These are the rows only. The panel they sit in belongs to `SourcePicker`, which
 * holds the source select above them: what a document is and where it came from
 * are one thing to a reader, so they share one box and it needs no heading of its
 * own, the section around it is already called Document.
 *
 * # Every field is optional, and absence shows as absence
 *
 * A document is allowed to say nothing about itself, so reading one shows only
 * the fields it carries: no title row on a document with no title, and no panel
 * at all on a document that says nothing. A row per absent field would be a
 * column of placeholders that tells the reader nothing they could not see from
 * its being empty.
 *
 * Editing shows every row, empty ones included, because an absent field is
 * exactly what the reader came here to fill in. Empty is normalized back to
 * absent on the way in (`document-fields.ts`), so a field
 * cleared to nothing leaves no `""` behind to make two documents that say the
 * same thing compare unequal.
 *
 * # Reading and editing
 *
 * Build edits, Play reads. That is the app's existing line, the Inspector takes
 * an `editor` only in Build, and a document's own fields are authoring like any
 * other.
 *
 * # One form, one record of when it changed
 *
 * Every keystroke reaches the document immediately. What waits is only the record
 * of when. `dct:modified` is stamped once, when focus leaves the panel, because
 * tabbing from the title to the creator is not finishing with it. Enter finishes
 * a one-line field by blurring it, so it arrives at the same place.
 *
 * # Which edits enter undo
 *
 * The text fields, through the transaction the field's own focus opens
 * (`EditBracket`), so a typing burst is one entry rather than one per letter.
 *
 * Where the document opens, too, through the Opens-at row's pin. Looking around
 * is not an edit, panning changes no document and records no history, so the
 * press is what makes it one, and undo takes it back like a title.
 *
 * `dct:created` and `dct:modified` are not edited here at all: created is stamped
 * once by whoever made the document, and modified is stamped when it is saved
 * (`builder/document-io.ts`). Showing them read-only is the honest presentation of a
 * field the reader does not own.
 */

import { useSyncExternalStore } from "react";
import type { Engine } from "../engine/engine.ts";
import type { AppMode } from "../state/app-state.ts";
import { stageCamera } from "../render/stage-camera.ts";
import { ClearGlyph, PinGlyph } from "./glyphs.tsx";
import { DEFAULT_STAGE_VIEW, formatStageZoom, initialStageView, sameStageView } from "../render/stage-view.ts";
import type { EditBracket } from "./inspector/edit-bracket.ts";
import type { BufferSourceInfo } from "../state/app-state.ts";
import { stateChipBase } from "./EntityChips.tsx";
import { Field, InlineTextField, TimeScrubInput } from "./inspector/fields.tsx";
import { valueMono, valueName, valueText } from "./inspector/styles.tsx";
import { c, SPACE } from "./tokens.ts";
import { useDocVersion } from "./useDocVersion.ts";

export function DocumentFields(
	{ engine, mode, editor, source, edited }: {
		engine: Engine;
		mode: AppMode;
		/** Present only where editing is allowed, which is Build. Absent makes every
		 *  row read-only without each row having to ask what mode it is in. */
		editor: EditBracket | undefined;
		/** What the buffer is. Null only before the first source resolves. */
		source: BufferSourceInfo | null;
		/** Whether Build has changed it since. */
		edited: boolean;
	},
) {
	// Every value here is read off the document, so this has to wake when the
	// document changes. Without it the fields are controlled inputs bound to a
	// value that never refreshes: a keystroke lands in the document and the field
	// redraws from the old one, so typing looks like it does nothing at all.
	useDocVersion(engine);
	const doc = engine.doc;
	const meta = doc.metadata;
	const editing = editor !== undefined && mode === "build";

	if (!editing) {
		// Reading: only what the document actually says. A row per absent field
		// would be a panel of placeholders that says nothing, and a document is
		// allowed to say nothing. Every one of these is optional.
		const said = [
			{ label: "Title", text: meta?.["dct:title"], style: valueName },
			{ label: "About", text: meta?.["dct:description"], style: prose },
			{ label: "By", text: meta?.["dct:creator"], style: valueName },
			{ label: "Created", text: meta?.["dct:created"], instant: true },
			{ label: "Modified", text: meta?.["dct:modified"], instant: true },
		].filter((row) => (row.text ?? "").trim() !== "");
		return (
			<>
				{said.map((row) => (
					<Field key={row.label} label={row.label}>
						{"instant" in row && row.instant
							? <Stamp at={row.text!} />
							: <span style={row.style}>{row.text}</span>}
					</Field>
				))}
				<OriginRow source={source} edited={edited} />
			</>
		);
	}

	// Editing: every row, including the empty ones, because an absent field is
	// exactly what the reader is here to fill in.
	return (
		<form style={formRows} {...formCommit(engine)}>
			<Field label="Title">
				<InlineTextField
					value={meta?.["dct:title"] ?? ""}
					onChange={(next) => engine.setDocumentTitle(next)}
					ariaLabel="Document title"
					editLabel="Set document title"
					editSession={editor}
					placeholder={doc.id}
					style={grow}
					submitOnEnter
				/>
			</Field>

			<Field label="About">
				<textarea
					className="ocv-input is-multiline"
					aria-label="Document description"
					value={meta?.["dct:description"] ?? ""}
					onChange={(ev) => engine.setDocumentDescription(ev.target.value)}
					onFocus={() => editor?.beginEdit("Set document description")}
					onBlur={() => editor?.endEdit()}
					placeholder="What happens here, and why it is worth watching."
					spellCheck
					style={grow}
				/>
			</Field>

			<Field label="By">
				<InlineTextField
					value={meta?.["dct:creator"] ?? ""}
					onChange={(next) => engine.setDocumentCreator(next)}
					ariaLabel="Document creator"
					editLabel="Set document creator"
					editSession={editor}
					placeholder="Nobody named"
					style={grow}
					submitOnEnter
				/>
			</Field>

			<Field label="Length">
				<TimeScrubInput
					value={doc.duration}
					min={engine.documentDurationFloor()}
					max={Math.max(doc.duration, 1000) * 2}
					onChange={(next) => engine.setDocumentDuration(next)}
					label="Timeline length"
					onScrubStart={() => editor?.beginEdit("Set timeline length")}
					onScrubEnd={() => editor?.endEdit()}
					style={grow}
				/>
			</Field>

			<Field label="Opens at">
				<OpeningView engine={engine} editor={editor} />
			</Field>

			{meta?.["dct:created"] && (
				<Field label="Created">
					<Stamp at={meta["dct:created"]} />
				</Field>
			)}
			{meta?.["dct:modified"] && (
				<Field label="Modified">
					<Stamp at={meta["dct:modified"]} />
				</Field>
			)}

			<OriginRow source={source} edited={edited} />
		</form>
	);
}

/**
 * The panel behaves as one form: finishing with it stamps `dct:modified` once.
 *
 * Per FIELD would be wrong, and it is the obvious thing to write. Tabbing from
 * the title to the creator is not finishing. It is still the same visit, so a
 * stamp per blur would record two modifications for one sitting, and typing in
 * three fields would record three. What ends the visit is focus leaving the form,
 * which is what `relatedTarget` still being inside it rules out.
 *
 * Nothing is deferred until then. Every keystroke is already in the document and
 * already bracketed for undo by the field that owns the caret. The only thing
 * waiting for the form to be done is the record of WHEN it was done.
 *
 * Enter finishes a one-line field by blurring it (`InlineTextField`'s
 * `submitOnEnter`), so pressing it inside the last field leaves the form and
 * stamps through this same path rather than a second one.
 *
 * `docVersion` at entry against `docVersion` at exit is how it knows anything
 * happened. Focusing a field and leaving without typing is not a modification,
 * and stamping it would move a timestamp on a document nobody changed.
 */
function formCommit(engine: Engine): {
	onFocus: (ev: React.FocusEvent) => void;
	onBlur: (ev: React.FocusEvent) => void;
	onSubmit: (ev: React.FormEvent) => void;
} {
	return {
		// A form submits implicitly when Enter is pressed in a text field, and a
		// form with nowhere to submit navigates the page. Enter here means "I am
		// done with this field", which `submitOnEnter` handles by blurring, so the
		// submit itself has to be refused or the panel reloads the app.
		onSubmit(ev) {
			ev.preventDefault();
		},
		onFocus(ev) {
			// Arriving from outside the form starts a visit; moving between its own
			// fields does not, so the version recorded is the one from the way in.
			if (ev.currentTarget.contains(ev.relatedTarget as Node | null)) {
				return;
			}
			entryVersion.set(ev.currentTarget, engine.docVersion);
		},
		onBlur(ev) {
			if (ev.currentTarget.contains(ev.relatedTarget as Node | null)) {
				return;
			}
			const entered = entryVersion.get(ev.currentTarget);
			entryVersion.delete(ev.currentTarget);
			if (entered === undefined || entered === engine.docVersion) return;
			engine.noteDocumentModified(new Date().toISOString());
		},
	};
}

/**
 * Where this buffer came from, and whether it has been changed since.
 *
 * Last, and a row like every other one. A line of small-caps text between the
 * picker and the fields would be the one thing in the panel that is neither a
 * control nor a labelled fact, and a reader scanning keys down the left would
 * have to step over it.
 *
 * "Origin" rather than "Source": the row above the fields is the Source, being the
 * one that CHANGES which document is loaded. This one says what that source turned
 * out to be, and two rows called the same thing would leave a reader working out
 * which was which.
 *
 * Last because it is the least urgent thing here: what a document IS comes before
 * where it came from, and a reader who wants the origin knows to look for it.
 *
 * `edited` is a badge rather than a word because it is a state rather than a
 * value, and `stateChipBase` is the app's badge box, the same one the Inspector's
 * lifecycle chips and the Reference's transport verdicts wear.
 */
function OriginRow(
	{ source, edited }: { source: BufferSourceInfo | null; edited: boolean },
) {
	if (!source) return null;
	return (
		<Field label="Origin">
			<span style={originRow}>
				<span style={valueName}>{sourceKindLabel(source)}</span>
				{edited && <span style={editedBadge}>edited</span>}
			</span>
		</Field>
	);
}

/** How each kind of buffer names itself. Every arm says how the thing came to be
 *  rather than what it is, so the four read as one set of answers to one
 *  question. */
function sourceKindLabel(source: BufferSourceInfo): string {
	switch (source.kind) {
		case "builtin":
			return "Built-in example";
		case "file":
			return "Opened file";
		case "new":
			return "Started empty";
		case "recording":
			return "Recorded from live";
	}
}

/**
 * An instant, as the document stores it.
 *
 * ISO-8601 in UTC, whole. It was briefly shown as its day alone with the rest on
 * hover, which was right while these rows shared a half-width column and wrapped
 * onto two lines. They are full-width rows, and twenty characters of mono fit
 * a rail at its usual width. Hiding a fact behind a hover needs a reason, and that
 * reason went away with the columns.
 *
 * Stored form rather than a friendlier one: a second spelling of the same moment
 * is a second thing to trust, and this is the one that matches the file a reader
 * can open in an editor.
 *
 * `valueMono` is the Inspector's face for a short token a reader compares digit by
 * digit, and its clamp is what keeps twenty characters inside a rail dragged down
 * to its narrowest: it ellipsizes rather than pushing the panel open. A local mono
 * style here did neither, so the date ran out through the panel's rounded edge and
 * was cut off by the pane.
 */
function Stamp({ at }: { at: string }) {
	return <span style={valueMono} title={at}>{at}</span>;
}

/** Where each open form's entry version waits. Keyed by the form element, so it
 *  cannot outlive the form and two panels cannot share one slot. */
const entryVersion = new WeakMap<Element, number>();

/**
 * Where this document opens, and the one press that changes it.
 *
 * The row reads the STORED view, not the camera. Looking around is reading: it
 * changes no document, records no history, and turns no badge on. So the way this
 * gets set is a press, and the press is an ordinary undoable edit like every other
 * row here (`writeOpeningView` in `document-fields.ts`).
 *
 * The button is the whole indication that there is anything to press. It comes
 * alive once the camera has come to rest somewhere other than where the document
 * opens, and goes inert again when they agree. So a reader who pans sees a
 * control light up rather than a badge claiming they changed something. That is
 * the app's existing rule for a command with nothing to do: stay put, go inert,
 * and say why (`ToolCommandButton`).
 *
 * `stageCamera.settled` is what it compares against, published once per gesture
 * rather than per frame, which is what makes reading the camera here cheap
 * (`render/stage-camera.ts`).
 *
 * A document with nothing stored says what it will do instead, because the absence
 * has a visible consequence and this is the only place that names it.
 */
function OpeningView(
	{ engine, editor }: { engine: Engine; editor: EditBracket | undefined },
) {
	// The settled view alone, not the whole readout: the readout's percentage
	// changes on most frames of a zoom, and this row does not show it. Subscribing
	// to the reference that only moves when the camera comes to rest is what keeps
	// a zoom gesture from re-rendering the document panel sixty times a second.
	const settled = useSyncExternalStore(
		stageCamera.subscribe,
		stageCamera.getSettledView,
		stageCamera.getSettledView,
	);
	// Absent means "wherever a document that says nothing opens", so the row reads
	// that rather than a special case. One form for both, which is also why there is
	// no word for the origin: "100% at 0, 0" says it, and a reader comparing this
	// row against the stage's own readout is comparing the same two numbers.
	const opensAt = initialStageView(engine.doc.initialView);
	const moved = !sameStageView(settled, opensAt);
	return (
		<span style={openingRow}>
			<span style={valueMono}>
				{`${formatStageZoom(opensAt.zoom)} at ${Math.round(opensAt.center.x)}, ${Math.round(opensAt.center.y)}`}
			</span>
			{editor !== undefined && (
				<span style={openingButtons}>
					<button
						type="button"
						className="ocv-btn is-icon"
						disabled={!moved}
						onClick={() => {
							// `undefined` for a camera parked exactly where a document naming
							// no view opens, so pinning there clears the field rather than
							// writing the default down. One transaction, so it is one step to
							// undo.
							editor.beginEdit("Set where the document opens");
							engine.setOpeningView(
								sameStageView(settled, DEFAULT_STAGE_VIEW) ? undefined : settled,
							);
							editor.endEdit();
						}}
						title={moved
							? "Pin the stage's current zoom and position as where this document opens"
							: "This document already opens where the stage is"}
						aria-label="Pin the current view as where this document opens"
					>
						<PinGlyph />
					</button>
					<button
						type="button"
						className="ocv-btn is-icon"
						disabled={!moved}
						// The camera, not the document. This abandons a change that has not
						// been pinned by taking the stage back to where the document opens,
						// which is why it is inert at exactly the same times as the pin: with
						// nothing pending there is nothing to pin and nothing to abandon.
						onClick={() => stageCamera.send({ kind: "go-to", view: opensAt })}
						title={moved
							? "Put the stage back where this document opens"
							: "The stage is already where this document opens"}
						aria-label="Put the stage back where this document opens"
					>
						<ClearGlyph />
					</button>
				</span>
			)}
		</span>
	);
}

/** The pair at the end of the row. Together rather than each pushed to the edge,
 *  so they read as two answers to one question, pin what is pending, or abandon
 *  it, and the ✕ lands where every other row's ✕ does. */
const openingButtons = {
	display: "flex",
	alignItems: "center",
	gap: 2,
	flex: "0 0 auto",
} satisfies React.CSSProperties;

/** The stored view and its button on one line, with the button pushed to the far
 *  end so it lands in the same column as the other rows' controls end. */
const openingRow = {
	display: "flex",
	alignItems: "center",
	justifyContent: "space-between",
	gap: SPACE.sm,
	minWidth: 0,
	flex: 1,
} satisfies React.CSSProperties;

/**
 * The editing form, made transparent to the grid it sits in.
 *
 * `.ocv-field` is a subgrid row: it spans its parent's tracks and re-inherits
 * them, which is what keeps every key in one column. A plain `<form>` between the
 * grid and the rows would be an opaque grid item, and the rows inside it would
 * invent their own tracks. So the source row's key and the title row's key would
 * stop lining up.
 *
 * So the form is itself a subgrid row: it spans the tracks and passes them
 * through. It exists at all because focus leaving it is what stamps the document
 * (`formCommit`), which is a property of the group rather than of any row.
 */
const formRows = {
	display: "grid",
	gridTemplateColumns: "subgrid",
	gridColumn: "1 / -1",
	rowGap: "inherit",
} satisfies React.CSSProperties;

const grow = { flex: 1, minWidth: 0 } satisfies React.CSSProperties;

/** A description is `valueText`, the Inspector's face for a value that is a
 *  sentence, and it keeps the line breaks a writer typed. It wraps where
 *  `valueName` would ellipsize, because a title can be clipped and still identify
 *  the thing while a paragraph cannot. */
const prose = {
	...valueText,
	whiteSpace: "pre-wrap",
	minWidth: 0,
	// A description is whatever the reader typed, so one pasted URL is a single
	// word wider than the rail. `pre-wrap` breaks at spaces and a long token has
	// none, so it needs leave to break anywhere rather than run out of the panel.
	overflowWrap: "anywhere",
} satisfies React.CSSProperties;

const originRow = {
	display: "flex",
	alignItems: "center",
	gap: SPACE.sm,
	minWidth: 0,
} satisfies React.CSSProperties;

/** Edited, as the app's badge in its warning tones: a fork that has not been
 *  saved is something to notice rather than a fact to read past. */
const editedBadge = {
	...stateChipBase,
	background: c.warningSoft,
	color: c.warning,
} satisfies React.CSSProperties;
