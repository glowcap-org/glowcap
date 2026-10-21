/**
 * "Discard all edits" puts back the WHOLE document.
 *
 * The command's name is a promise, and the way to break it quietly is
 * to restore through `DocSnapshot`: a document field the snapshot does
 * not carry would survive, and the composition would come back mostly
 * reset, with nothing on screen reporting the part that did not. So
 * every claim here is measured against the whole document, and one
 * test drives the failure directly, it takes a snapshot round trip
 * past a field outside the snapshot's list and watches the edit
 * survive, then watches the discard remove it.
 *
 * The other half is what "all edits" means. It is everything since
 * this engine was built from its document, which is the baseline the
 * engine clones at construction and never moves. Not the app's current
 * source: leaving Build with edits hands the buffer's own working
 * document back as the source, so by then the source a caller can see
 * IS the edited document, and a discard measured against it would find
 * nothing to do while Undo still held every edit.
 *
 * It is the strong half of a pair. `Engine.undoAll` walks the history
 * back and keeps it, so a reader can walk forward again. This one goes
 * back to the whole document however long ago it arrived, and empties
 * the history because the steps in it lead through a document that is
 * gone. The cases below hold both halves of that split.
 *
 * Validated against two injected defects, both of which leave a
 * partial reset: a `resetDocumentTo` that writes the source over the
 * document without first taking the document's own keys off it, and
 * one that restores through `takeSnapshot` / `restoreSnapshotInto`.
 * The test edits both a field the source carries and one it lacks,
 * because a changed field and an added one fail differently.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "./timeline.ts";
import { Engine } from "./engine.ts";
import { restoreSnapshotInto, takeSnapshot } from "./snapshot.ts";

function engineTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

/** Two peers on a session, plus a provenance claim. A document field
 *  `DocSnapshot` does not carry, which one test below needs.
 *
 *  `provenance` and `layoutMode` sit outside the snapshot (the document's own
 *  fields live under `metadata` and are inside it), so they are what the test
 *  can say
 *  this about. */
const source = {
	id: "discard-edits",
	provenance: { "dct:source": "the document the buffer was built from" },
	duration: 10000,
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
			t: 0,
			kind: "peer-joined",
			peerId: "b",
			profile: "goblins",
		},
		{
			id: "e3",
			t: 0,
			kind: "session-opened",
			sessionId: "s1",
			a: { peer: "a" },
			b: { peer: "b" },
			codec: "syrup",
			captpVersion: "v1_0",
			initialState: "open",
		},
	],
};

function freshEngine(): Engine {
	return new Engine(TimelineDocument.parse(structuredClone(source)));
}

/** The whole document as comparable text. Not
 *  `takeSnapshot`, see this file's header. */
function docText(e: Engine): string {
	return JSON.stringify(e.doc);
}

/** What an untouched buffer built from `source` says. Read off a
 *  fresh engine rather than off the raw fixture, because construction
 *  projects `entity.timing` and that projection is part of the
 *  document every reader first sees. */
function sourceText(): string {
	return docText(freshEngine());
}

engineTest("a discard puts the whole document back", () => {
	const e = freshEngine();
	e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 5, y: 6 },
	});
	e.dispatch({
		kind: "update-peer",
		peerId: "a",
		patch: { label: "renamed" },
	});
	e.dispatch({ kind: "delete-session", sessionId: "s1" });
	e.dispatch({
		kind: "reposition-peer",
		peerId: "b",
		position: { x: 9, y: 9 },
	});
	assert(docText(e) !== sourceText(), "the edits changed nothing");

	e.discardAllEdits();
	assertEquals(docText(e), sourceText());
});

engineTest(
	"a document field the snapshot does not carry does not survive",
	() => {
		// Two shapes, because a partial reset can leave a field standing
		// in two different ways and only one of them is the one that is
		// easy to picture. A field the source HAS, changed: a restore that
		// writes back a listed set of fields misses it. A field the source
		// does NOT have, added: a restore that writes the source over the
		// document without first taking the document's own keys off it
		// misses that one instead, and writing every field back by name
		// would not have saved it either.
		const e = freshEngine();
		// An ordinary edit first, so there is history for the command to
		// be offered on, which is also the shape this arises in, a
		// document carrying both kinds of difference at once.
		e.dispatch({
			kind: "update-peer",
			peerId: "a",
			patch: { label: "Al" },
		});
		const beforeTheEdit = takeSnapshot(e.doc);
		e.doc.provenance = {
			"dct:source": "edited outside the snapshot's fields",
		};
		e.doc.layoutMode = "static-union";

		// What undo can reach: restoring the snapshot taken before the
		// edits leaves both standing, because `DocSnapshot` never carried
		// either field. This is the failure the command has to avoid,
		// driven here rather than argued.
		restoreSnapshotInto(e.doc, beforeTheEdit);
		assertEquals(
			e.doc.provenance?.["dct:source"],
			"edited outside the snapshot's fields",
			"the snapshot round trip was expected to leave this field alone",
		);
		assertEquals(
			e.doc.layoutMode,
			"static-union",
			"the snapshot round trip was expected to leave this field alone",
		);

		// What the discard reaches: all of it, in both shapes.
		e.discardAllEdits();
		assertEquals(
			e.doc.provenance?.["dct:source"],
			"the document the buffer was built from",
			"a changed field outside the snapshot survived the discard",
		);
		assertEquals(
			e.doc.layoutMode,
			undefined,
			"a field the source never had survived the discard",
		);
		assertEquals(docText(e), sourceText());
	},
);

engineTest("a discard empties the history it swept past", () => {
	const e = freshEngine();
	e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 1, y: 2 },
	});
	e.dispatch({ kind: "update-peer", peerId: "b", patch: { label: "Bee" } });
	assert(e.canUndo);

	e.discardAllEdits();
	assertEquals(docText(e), sourceText());
	// Not a step in the history: the steps it swept past lead back
	// through a document that is no longer there, so they go with it and status-allow: lifecycle transition
	// the buffer is left exactly as a freshly built one.
	assert(!e.canUndo, "the discard left steps behind it");
	assert(!e.canRedo, "the discard left a way forward");
});

engineTest("undo all reaches the same place and keeps the way back", () => {
	const e = freshEngine();
	e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 1, y: 2 },
	});
	e.dispatch({ kind: "update-peer", peerId: "b", patch: { label: "Bee" } });
	e.dispatch({
		kind: "set-session-initial-state",
		sessionId: "s1",
		state: "negotiating",
	});
	const edited = docText(e);

	e.undoAll();
	// The same document the discard reaches, while the history has not
	// overflowed, which is what makes the two commands a pair rather
	// than two spellings of one.
	assertEquals(docText(e), sourceText());

	// And every step crossed to the redo side, so the author walks
	// forward again exactly as they walked back.
	assert(e.canRedo, "undo all left no way forward");
	assert(!e.canUndo, "undo all did not reach the bottom");
	e.redo();
	e.redo();
	e.redo();
	assertEquals(docText(e), edited, "redo did not walk the whole way forward");
});

engineTest("undo all with nothing to undo changes nothing", () => {
	const e = freshEngine();
	e.undoAll();
	assertEquals(docText(e), sourceText());
	assert(!e.canRedo, "an empty undo all banked a step to redo");
});

engineTest("a discard with no history at all touches nothing", () => {
	const e = freshEngine();
	assert(!e.hasHistory, "a fresh engine already had history");

	e.discardAllEdits();
	assertEquals(docText(e), sourceText());
	assert(!e.canUndo, "the refused discard recorded a history entry anyway");
});

engineTest("the two commands do not ask the same question", () => {
	// At the beginning of the history there is nothing left to undo, and
	// there is still a history. That is the whole difference between
	// them: "undo all" walks steps back and has none left, while
	// "discard all" throws a history away and there is one to throw.
	const e = freshEngine();
	e.dispatch({
		kind: "update-peer",
		peerId: "a",
		patch: { label: "renamed" },
	});
	assert(e.canUndo && e.hasHistory);

	e.undoAll();
	assertEquals(docText(e), sourceText());
	assert(!e.canUndo, "undo all did not reach the beginning");
	assert(
		e.hasHistory,
		"the history vanished when the reader reached its start",
	);

	e.discardAllEdits();
	assert(!e.hasHistory, "the discard left the history it was offered on");
	assert(!e.canRedo, "the discard left a way forward");
});

engineTest("the discard goes to the source, not to the last state", () => {
	const e = freshEngine();
	e.dispatch({ kind: "update-peer", peerId: "a", patch: { label: "first" } });
	const afterFirst = docText(e);
	e.dispatch({
		kind: "update-peer",
		peerId: "a",
		patch: { label: "second" },
	});

	// The baseline is the document the engine was built from and no
	// later state ever becomes it, so the discard goes all the way back
	// rather than to the edit before this one.
	e.discardAllEdits();
	assert(docText(e) !== afterFirst, "the discard stopped at an earlier edit");
	assertEquals(docText(e), sourceText());
});

engineTest("a discard re-seeks, so the world agrees with the document", () => {
	const e = freshEngine();
	e.seekTo(0);
	const added = e.dispatch({
		kind: "add-peer",
		profile: "glowcap",
		position: { x: 3, y: 4 },
	});
	assert(added !== undefined);
	assert([...e.queries.peers].some((p) => p.peer.id === added));

	e.discardAllEdits();
	assert(
		![...e.queries.peers].some((p) => p.peer.id === added),
		"the discarded peer was still on stage",
	);
});
