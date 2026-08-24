/**
 * What a document says about itself: title, description, creator,
 * duration, opening view, and the modified stamp.
 *
 * The engine's tick loop does not own these. One setter per field
 * rather than one that takes a patch, because each is a separate
 * undo entry with its own label and a patch would need the caller to
 * say which. `dct:modified` is not among them: it is stamped when a
 * document is saved (`saveStampedDoc`), so no clock runs in the edit
 * path.
 *
 * `document-fields.test.ts` is the evidence. The engine's public
 * methods are the door the UI and those tests walk through; they
 * notify and bracket undo. This module is the write.
 */

import { latestStatedTime } from "./authoring/events.ts";
import type { Clock } from "./clock.ts";
import type { TimelineDocument } from "./timeline.ts";

/** An opening view as a document stores it: three numbers, or nothing said. */
export type StoredView =
	| { zoom: number; center: { x: number; y: number } }
	| undefined;

export type DocumentIdentityField =
	| "dct:title"
	| "dct:description"
	| "dct:creator";

/** Undo bracketing the duration write needs. The engine owns history. */
export type DocumentTxn = {
	begin(label: string): void;
	end(): void;
};

/**
 * Whether two documents name the same opening view, absence included. Absence is
 * a distinct answer rather than a stand-in for the default, because the caller
 * passes `undefined` for a camera sitting at the default
 * (`writeOpeningView`), so a document that says nothing and one that says
 * 1:1 centered cannot both occur.
 */
export function sameStoredView(a: StoredView, b: StoredView): boolean {
	if (a === undefined || b === undefined) return a === b;
	return a.zoom === b.zoom && a.center.x === b.center.x &&
		a.center.y === b.center.y;
}

/**
 * Write one identity-metadata field, treating blank as absent.
 *
 * Blank clears rather than storing `""`, because an empty string and a missing
 * field would both read as "no title" and only one of them survives a
 * round-trip through the schema, so keeping both would make two documents that
 * say the same thing compare unequal.
 *
 * The text is stored EXACTLY as typed. Trimming it here would eat the space a
 * reader is in the middle of typing: this runs per keystroke against a
 * controlled field that reads the stored value straight back, so "Hand off "
 * would be stored as "Hand off" and redrawn without the space, and the next
 * letter would arrive against the trimmed text. Only the decision to clear
 * looks past whitespace, so a field holding nothing but spaces is a field
 * holding nothing.
 *
 * No transaction is opened here. A typing burst is bracketed by the field that
 * owns the caret (`InlineTextField` through `EditBracket`), so opening one per
 * keystroke would make each letter its own undo step.
 *
 * Returns whether the document changed, so the engine notifies only then.
 */
export function writeMetadataField(
	doc: TimelineDocument,
	key: DocumentIdentityField,
	text: string,
): boolean {
	const next = text.trim() === "" ? "" : text;
	const current = doc.metadata?.[key];
	if ((current ?? "") === next) return false;
	const metadata = { ...doc.metadata };
	if (next === "") delete metadata[key];
	else metadata[key] = next;
	doc.metadata = Object.keys(metadata).length > 0 ? metadata : undefined;
	return true;
}

/**
 * Stamp `dct:modified` with `now`.
 *
 * Outside history by construction: it is called after the edit's transaction
 * has closed, and `endTransaction` is the only thing that records, so nothing
 * here can push an entry. `DocSnapshot` also leaves this one key out, so an
 * undo reverts the edit and not the record that an edit happened — reverting a
 * title should not claim the document was last modified before it was.
 *
 * `now` is a parameter rather than read from a clock here, so the edit path
 * stays free of one and a test can say what time it is.
 */
export function writeDocumentModified(
	doc: TimelineDocument,
	now: string,
): void {
	doc.metadata = { ...doc.metadata, "dct:modified": now };
}

/**
 * The floor a duration will not go below: the last moment the document states
 * anything at. `latestStatedTime` is the one answer; this name is the duration
 * field's.
 */
export function documentDurationFloor(doc: TimelineDocument): number {
	return latestStatedTime(doc);
}

/**
 * Set how long the timeline is.
 *
 * Refuses to shrink below what the document already states, because a
 * duration shorter than the last thing on it would hide events with no way to
 * reach them: the scrubber cannot travel past the end. Growing is always
 * allowed. `authoring/events.ts` grows it the other way, to fit an edit that
 * lands past the end, and the two must not disagree about the floor.
 *
 * Returns whether the document changed. The engine notifies after the
 * transaction closes.
 */
export function writeDocumentDuration(
	doc: TimelineDocument,
	clock: Clock,
	duration: number,
	txn: DocumentTxn,
): boolean {
	if (!Number.isFinite(duration)) return false;
	const floor = documentDurationFloor(doc);
	const next = Math.max(floor, Math.max(0, duration));
	if (next === doc.duration) return false;
	txn.begin("Set timeline length");
	(doc as { duration: number }).duration = next;
	clock.setDuration(next);
	txn.end();
	return true;
}

/**
 * Set where the document opens, or say it names no view at all.
 *
 * An ordinary document edit: pressed for, recorded in the history, taken back
 * by undo like a title. That is the whole reason it is a verb rather than
 * something the camera does — a document changes when a reader changes it, and
 * every change a reader makes is a step they can walk back.
 *
 * The camera does NOT write this as it moves. Looking around is reading, and a
 * reader who pans across a document should not be building a history or turning
 * the panel's edited badge on. What the camera does instead is offer: the
 * Opens-at row's button lights up once the view differs from what is stored, and
 * pressing it lands here (`ui/DocumentFields.tsx`).
 *
 * `undefined` means the document names no view and so opens where any document
 * that names none opens. The caller passes it when the camera is sitting exactly
 * there, because what that place IS belongs to the camera
 * (`render/stage-view.ts`'s `DEFAULT_STAGE_VIEW`), which is also why this takes
 * a plain view rather than reaching for it.
 *
 * Returns whether the document changed, so a still camera publishing the same
 * numbers does not notify the app.
 */
export function writeOpeningView(
	doc: TimelineDocument,
	view: StoredView,
): boolean {
	if (sameStoredView(doc.initialView, view)) return false;
	doc.initialView = view === undefined ? undefined : {
		zoom: view.zoom,
		center: { x: view.center.x, y: view.center.y },
	};
	return true;
}
