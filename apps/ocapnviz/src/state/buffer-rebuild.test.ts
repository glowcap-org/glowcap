/**
 * When a new source document means a new buffer.
 *
 * The buffer carries the undo history, so rebuilding it empties Undo.
 * These cases pin the two near-misses that used to do exactly that:
 * switching between Play and Build, and leaving Build, which hands the
 * working document back as the source so the picker names what you
 * built.
 *
 * Each case drives the tracker `useBufferEngine` holds, one reading per
 * time the hook's effect runs, so what the tracker remembers between
 * them is under test rather than restated here.
 */

import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../engine/timeline.ts";
import { Engine } from "../engine/engine.ts";
import { bufferSourceTracker } from "./hooks.ts";

function docTest(name: string, fn: () => void): void {
	Deno.test({ name, sanitizeOps: false, sanitizeResources: false, fn });
}

function parse(id: string): TimelineDocument {
	return TimelineDocument.parse({
		id,
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "pancake",
			},
		],
	});
}

docTest("no buffer yet means build one", () => {
	assert(bufferSourceTracker().needsRebuild(null, parse("fixture")));
});

docTest("the same source twice keeps the buffer", () => {
	const sources = bufferSourceTracker();
	const source = parse("fixture");
	assert(sources.needsRebuild(null, source));
	const buffer = new Engine(structuredClone(source));
	assertEquals(sources.needsRebuild(buffer, source), false);
});

docTest("the buffer's own document is not a new source", () => {
	const sources = bufferSourceTracker();
	const source = parse("fixture");
	assert(sources.needsRebuild(null, source));
	const buffer = new Engine(structuredClone(source));
	// What leaving Build hands back.
	assertEquals(sources.needsRebuild(buffer, buffer.doc), false);
});

docTest("a different document rebuilds", () => {
	const sources = bufferSourceTracker();
	const source = parse("fixture");
	assert(sources.needsRebuild(null, source));
	const buffer = new Engine(structuredClone(source));
	assert(sources.needsRebuild(buffer, parse("opened-file")));
});

docTest("undo survives a Play / Build round trip", () => {
	// The sequence the hook sees: build a buffer, edit it, leave Build
	// (the working doc becomes the source), come back.
	const sources = bufferSourceTracker();
	const source = parse("fixture");
	assert(sources.needsRebuild(null, source));
	const buffer = new Engine(structuredClone(source));

	buffer.dispatch({
		kind: "update-peer",
		peerId: "a",
		patch: { label: "edited" },
	});
	assert(buffer.canUndo, "the edit recorded an undo step");

	// Leaving Build.
	const afterLeaving = buffer.doc;
	assertEquals(sources.needsRebuild(buffer, afterLeaving), false);

	// Coming back. Nothing about the source changed, so nothing rebuilds
	// and the edit is still there to take back.
	assertEquals(sources.needsRebuild(buffer, afterLeaving), false);
	assert(buffer.canUndo, "a round trip through Play kept the undo step");
});

docTest("picking the fixture back after leaving Build rebuilds", () => {
	// The source the buffer was made from is not the source it is
	// playing once Build has handed its working document back, so
	// choosing that first source again in the picker is a real switch.
	// A tracker that wrote down only the sources it rebuilt for still
	// held the fixture here, and read the explicit pick as the document
	// already on screen: the picker named the fixture and the buffer
	// went on playing the edited fork.
	const sources = bufferSourceTracker();
	const fixture = parse("fixture");
	assert(sources.needsRebuild(null, fixture));
	const buffer = new Engine(structuredClone(fixture));

	buffer.dispatch({
		kind: "update-peer",
		peerId: "a",
		patch: { label: "edited" },
	});
	// Leaving Build with edits.
	assertEquals(sources.needsRebuild(buffer, buffer.doc), false);

	// The same fixture object the picker holds, chosen again.
	assert(
		sources.needsRebuild(buffer, fixture),
		"an explicit source switch replaces the buffer wholesale",
	);
});
