/**
 * What "the same document" means.
 *
 * Three things read this answer — a transaction that changed nothing,
 * an undo round trip, and whether the buffer still says what it was
 * built from — so the cases below are the ones where the cheap
 * spelling, `JSON.stringify(a) === JSON.stringify(b)`, gives a
 * different answer from the right one.
 */

import { assert } from "@std/assert";
import { deepEqual } from "./deep-equal.ts";

Deno.test("key order is not part of the answer", () => {
	// The case that reaches the app: unpinning a peer deletes
	// `position` and re-pinning writes it back at the end of the
	// object. Same document, different text.
	const before = { profile: "glowcap", position: { x: 1, y: 2 }, label: "a" };
	const after = { profile: "glowcap", label: "a", position: { x: 1, y: 2 } };
	assert(deepEqual(before, after));
	assert(JSON.stringify(before) !== JSON.stringify(after));
});

Deno.test("a key carrying undefined and a key that is not there agree", () => {
	// The document uses both spellings for an absent field:
	// `restoreSnapshotInto` writes `recording = undefined` where a
	// freshly parsed document simply has no `recording`.
	assert(deepEqual({ recording: undefined, id: "d" }, { id: "d" }));
	assert(deepEqual({ id: "d" }, { recording: undefined, id: "d" }));
	assert(!deepEqual({ recording: { sources: [] }, id: "d" }, { id: "d" }));
});

Deno.test("a difference anywhere in the tree is a difference", () => {
	const doc = () => ({
		id: "d",
		duration: 10,
		entities: {
			peers: { a: { label: "Alice", timing: { start: { value: 0 } } } },
		},
		rowOrder: { peers: ["a", "b"] },
	});
	assert(deepEqual(doc(), doc()));

	const deeper = doc();
	deeper.entities.peers.a.timing.start.value = 1;
	assert(!deepEqual(doc(), deeper), "a leaf three levels down was missed");

	const renamed = doc();
	renamed.entities.peers.a.label = "Alicia";
	assert(!deepEqual(doc(), renamed));
});

Deno.test("arrays compare by order and length", () => {
	assert(deepEqual({ order: ["a", "b"] }, { order: ["a", "b"] }));
	assert(!deepEqual({ order: ["a", "b"] }, { order: ["b", "a"] }));
	assert(!deepEqual({ order: ["a"] }, { order: ["a", "b"] }));
	assert(!deepEqual({ order: ["a", "b"] }, { order: ["a"] }));
	// An array and an object with the same indices are not the same
	// value, whatever their contents encode to.
	assert(!deepEqual(["a"], { 0: "a" }));
});

Deno.test("null is a value, not an absence", () => {
	// The document says "state no transport" with `null`, which is a
	// thing a producer reported and not a missing field.
	assert(!deepEqual({ transport: null }, {}));
	assert(!deepEqual({ transport: null }, { transport: undefined }));
	assert(deepEqual({ transport: null }, { transport: null }));
});

Deno.test("values of different types are different", () => {
	assert(!deepEqual({ t: 0 }, { t: "0" }));
	assert(!deepEqual({ t: 0 }, { t: false }));
	assert(!deepEqual({ t: {} }, { t: null }));
});
