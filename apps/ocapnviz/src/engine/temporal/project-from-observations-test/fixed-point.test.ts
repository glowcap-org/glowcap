/**
 * A projection that changed nothing is not repeated. The playing tick and
 * every seek project again, so an unchanged document returns as itself
 * without its observations being read, and each write the document contract
 * names still reaches the projection.
 */

import { assert, assertEquals, assertNotStrictEquals, assertStrictEquals } from "@std/assert";
import type { TimelineEvent } from "../../timeline.ts";
import { projectFromObservations } from "../project-from-observations.ts";
import { primaryObservations } from "../recording-access.ts";
import { joinedPeerDoc } from "./harness.ts";

/** An observation that counts how often its kind is read. */
function watched(
	event: TimelineEvent,
): { event: TimelineEvent; reads: () => number } {
	let reads = 0;
	const kind = event.kind;
	const copy: TimelineEvent = { ...event };
	Object.defineProperty(copy, "kind", {
		enumerable: true,
		get: () => {
			reads += 1;
			return kind;
		},
	});
	return { event: copy, reads: () => reads };
}

Deno.test("project: an unchanged second call returns the document without reading observations", () => {
	const doc = joinedPeerDoc();
	const [joined] = primaryObservations(doc);
	if (joined === undefined) throw new Error("the document holds its join");
	const spy = watched(joined);
	primaryObservations(doc)[0] = spy.event;

	const once = projectFromObservations(doc);
	assertNotStrictEquals(once, doc);
	const again = projectFromObservations(once);
	assertStrictEquals(again, once);
	const readsAfterSettling = spy.reads();
	assert(readsAfterSettling > 0, "the projection reads the observation it indexes");

	assertStrictEquals(projectFromObservations(once), once);
	assertStrictEquals(projectFromObservations(once), once);
	assertEquals(spy.reads(), readsAfterSettling);
});

Deno.test("project: an observation appended in place is seen after a quiet call", () => {
	const settled = projectFromObservations(joinedPeerDoc());
	assertStrictEquals(projectFromObservations(settled), settled);

	primaryObservations(settled).push({
		id: "e2",
		kind: "peer-left",
		t: 30,
		peerId: "127.0.0.1:0",
	});
	const out = projectFromObservations(settled);
	assertNotStrictEquals(out, settled);
	assertEquals(out.entities?.peers?.["127.0.0.1:0"]?.timing?.duration, {
		value: 25,
		explicit: true,
	});
});

Deno.test("project: an in-place edit followed by the entities swap is seen", () => {
	const doc = joinedPeerDoc();
	primaryObservations(doc).push({
		id: "e2",
		kind: "peer-left",
		t: 30,
		peerId: "127.0.0.1:0",
	});
	const settled = projectFromObservations(doc);
	assertStrictEquals(projectFromObservations(settled), settled);

	// What the authoring path does: change an observation where it sits,
	// then replace `doc.entities` with a copy.
	const moved = primaryObservations(settled)[1];
	if (moved === undefined) throw new Error("the document holds a second observation");
	moved.t = 60;
	settled.entities = { ...settled.entities };
	const out = projectFromObservations(settled);
	assertNotStrictEquals(out, settled);
	assertEquals(out.entities?.peers?.["127.0.0.1:0"]?.timing?.duration, {
		value: 55,
		explicit: true,
	});
});

Deno.test("project: a document that was touched is projected again until it settles", () => {
	const doc = joinedPeerDoc();
	const once = projectFromObservations(doc);
	assertNotStrictEquals(once, doc);
	// The input never settled, so asking again reaches the same answer by
	// the same work and not a stale shortcut.
	assertEquals(projectFromObservations(doc).entities, once.entities);
});
