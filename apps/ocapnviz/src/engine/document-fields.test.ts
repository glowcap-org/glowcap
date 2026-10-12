/**
 * What a document says about itself, and what editing it costs.
 *
 * The writes live in `document-fields.ts`. These tests walk through the engine
 * because undo, notify, and the clock bound are what editing costs.
 *
 * Every claim below was wrong once in a way nothing else here would have caught:
 *
 *   - Text is stored exactly as typed. These setters run per keystroke against a
 *     controlled field that reads the stored value straight back, so trimming
 *     here ate the space a reader was in the middle of typing.
 *   - Empty normalizes to absent, all the way up. A cleared field must not leave
 *     `""` behind, and a metadata block emptied of every field must not leave an
 *     empty object, or two documents that say the same thing compare unequal and
 *     `endTransaction` records a history entry for a no-op.
 *   - The edits undo. They are document edits like any other, which is what
 *     putting `metadata` into `DocSnapshot` is for.
 *   - A duration will not go below the last thing on the timeline, because the
 *     scrubber cannot travel past the end and the event would be unreachable.
 *   - The opening view is an ordinary undoable edit. Looking around is not,
 *     which is why the camera never writes it.
 */

import { assert, assertEquals } from "@std/assert";
import { Engine } from "./engine.ts";
import { TimelineDocument } from "./timeline.ts";

function engineTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** A document with one peer at t=0 and one at t=4000, so the duration floor is a
 *  real number rather than zero. */
function docEngine(): Engine {
	return new Engine(TimelineDocument.parse({
		id: "doc-fields",
		duration: 10_000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "glowcap",
			},
			{
				id: "e2",
				t: 4000,
				kind: "peer-joined",
				peerId: "b",
				profile: "goblins",
			},
		],
	}));
}

engineTest("a title is stored exactly as typed", () => {
	// Including the trailing space, because this runs on every keystroke and the
	// field reads the stored value back: trimming would redraw "Hand off " as
	// "Hand off" and the next letter would arrive against the trimmed text, so a
	// reader could not type a space at all.
	const e = docEngine();
	e.setDocumentTitle("Hand off ");
	assertEquals(e.doc.metadata?.["dct:title"], "Hand off ");
	e.setDocumentTitle("Hand off a thing");
	assertEquals(e.doc.metadata?.["dct:title"], "Hand off a thing");
});

engineTest("clearing a field leaves no trace of it", () => {
	// Absent, not empty. `""` and missing both read as "no title", and only one of
	// them survives a round trip through the schema.
	const e = docEngine();
	e.setDocumentTitle("Something");
	e.setDocumentCreator("Somebody");
	e.setDocumentTitle("");
	assertEquals(e.doc.metadata?.["dct:title"], undefined);
	assert(
		!("dct:title" in (e.doc.metadata ?? {})),
		"the key was kept with an empty value",
	);
	// Whitespace is nothing said.
	e.setDocumentCreator("   ");
	assertEquals(e.doc.metadata?.["dct:creator"], undefined);
	// And a block emptied of every field is a block that is not there.
	assertEquals(e.doc.metadata, undefined);
});

engineTest("a title edit undoes", () => {
	// The point of putting `metadata` in `DocSnapshot`. A transaction is what the
	// field's focus opens, so the test opens one the same way.
	const e = docEngine();
	e.beginTransaction("Set document title");
	e.setDocumentTitle("First");
	e.endTransaction();
	assertEquals(e.doc.metadata?.["dct:title"], "First");
	assert(e.canUndo, "a document edit left nothing to undo");
	e.undo();
	assertEquals(
		e.doc.metadata?.["dct:title"],
		undefined,
		"undo did not reach the title",
	);
	e.redo();
	assertEquals(e.doc.metadata?.["dct:title"], "First");
});

engineTest("a transaction that changed nothing is not history", () => {
	// Focusing a field and leaving it is not an edit. This is the case a clock in
	// the edit path would break: a `dct:modified` stamped per keystroke would make
	// the two snapshots differ and push an entry for a no-op.
	const e = docEngine();
	e.setDocumentTitle("Held");
	const before = e.canUndo;
	e.beginTransaction("Set document title");
	e.setDocumentTitle("Held");
	e.endTransaction();
	assertEquals(e.canUndo, before, "a no-op edit pushed a history entry");
});

engineTest("a timeline will not be shorter than the last thing on it", () => {
	// The floor is where the marks are. Below it the scrubber cannot reach the
	// event, so the document would be hiding something with no way to find it.
	const e = docEngine();
	assertEquals(e.documentDurationFloor(), 4000);
	e.setDocumentDuration(1000);
	assertEquals(
		e.doc.duration,
		4000,
		"the duration went under its own content",
	);
	// Growing is free.
	e.setDocumentDuration(30_000);
	assertEquals(e.doc.duration, 30_000);
	// And the clock's bound follows, or the transport plays past the end.
	assertEquals(e.clock.duration, 30_000);
});

engineTest("where a document opens is an edit like any other", () => {
	// The rule the whole shape answers to: the document changes when a reader
	// changes it, and every change is a step they can walk back. Looking around is
	// not one, which is why nothing here is called from the camera, the Opens-at
	// row's button is, and it opens a transaction the way every other row does.
	const e = docEngine();
	assertEquals(e.doc.initialView, undefined);
	e.beginTransaction("Set where the document opens");
	e.setOpeningView({ zoom: 0.5, center: { x: 120, y: -40 } });
	e.endTransaction();
	assertEquals(e.doc.initialView, { zoom: 0.5, center: { x: 120, y: -40 } });
	assert(e.canUndo, "setting the opening view left nothing to undo");

	e.undo();
	assertEquals(e.doc.initialView, undefined, "undo did not reach the view");
	e.redo();
	assertEquals(e.doc.initialView?.zoom, 0.5);
});

engineTest("a document naming no view is a document naming no view", () => {
	// `undefined` rather than a written-down copy of the default, so `initialView`
	// is present exactly when a reader has chosen something. The caller passes it
	// for a camera parked where a document that says nothing would open, because
	// that place is the camera's fact (`render/stage-view.ts`).
	const e = docEngine();
	e.setOpeningView({ zoom: 3, center: { x: 1, y: 2 } });
	assert(e.doc.initialView !== undefined);
	e.setOpeningView(undefined);
	assertEquals(e.doc.initialView, undefined, "it kept a copy of the default");
	// Setting what is already set changes nothing, in both directions, so the
	// button pressed twice is not two history entries.
	const version = e.docVersion;
	e.setOpeningView(undefined);
	assertEquals(e.docVersion, version, "clearing nothing still notified");
	e.setOpeningView({ zoom: 3, center: { x: 1, y: 2 } });
	const set = e.docVersion;
	e.setOpeningView({ zoom: 3, center: { x: 1, y: 2 } });
	assertEquals(e.docVersion, set, "re-setting the same view still notified");
});

engineTest("a view set and set back is not history", () => {
	// `endTransaction`'s no-op detection has to see this field, which is what
	// putting `initialView` in `DocSnapshot` is for. Without it, a reader who
	// pressed Set where the document already opens would bank an entry for nothing.
	const e = docEngine();
	e.setOpeningView({ zoom: 2, center: { x: 0, y: 0 } });
	const before = e.canUndo;
	e.beginTransaction("Set where the document opens");
	e.setOpeningView({ zoom: 2, center: { x: 0, y: 0 } });
	e.endTransaction();
	assertEquals(e.canUndo, before, "a no-op press pushed a history entry");
});

engineTest("the modified stamp is not undone with the edit", () => {
	// Undo reverts what a reader typed, not the record that they typed something.
	// Putting the stamp back would claim the document was last modified before the
	// change being undone, which is a time it was not.
	const e = docEngine();
	e.beginTransaction("Set document title");
	e.setDocumentTitle("Named");
	e.endTransaction();
	e.noteDocumentModified("2026-08-06T12:00:00Z");
	assertEquals(e.doc.metadata?.["dct:modified"], "2026-08-06T12:00:00Z");

	e.undo();
	assertEquals(
		e.doc.metadata?.["dct:title"],
		undefined,
		"the edit did not undo",
	);
	assertEquals(
		e.doc.metadata?.["dct:modified"],
		"2026-08-06T12:00:00Z",
		"undo reverted the record that an edit happened",
	);
});

engineTest("stamping is not itself an edit", () => {
	// It runs after the transaction has closed, and `endTransaction` is the only
	// thing that records, so there is nothing for it to push. If the stamp were in
	// the snapshot it would also make a no-op transaction differ from itself.
	const e = docEngine();
	assert(!e.canUndo, "the fixture should start with nothing to undo");
	e.noteDocumentModified("2026-08-06T12:00:00Z");
	assertEquals(e.canUndo, false, "a stamp became an undoable edit");
});

engineTest("a stamp does not make an empty edit look like a change", () => {
	// The case the stamp-in-snapshot version broke: focus a field, type nothing,
	// leave. Nothing a reader typed changed, so no history entry, even though a
	// stamp had landed since the snapshot was taken.
	const e = docEngine();
	e.setDocumentTitle("Held");
	e.noteDocumentModified("2026-08-06T12:00:00Z");
	const before = e.canUndo;
	e.beginTransaction("Set document title");
	e.setDocumentTitle("Held");
	e.endTransaction();
	assertEquals(e.canUndo, before, "a no-op edit pushed a history entry");
});
