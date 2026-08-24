/**
 * Snapshot round-trip tests. The load-bearing invariant: whatever
 * authoring writes via `primaryObservations(doc)` must round-trip
 * through `takeSnapshot` / `restoreSnapshotInto`. Observations live
 * only in `doc.recording.sources[]` post-parse.
 */

import { assertEquals } from "@std/assert";
import { restoreSnapshotInto, takeSnapshot } from "./snapshot.ts";
import type { TimelineDocument } from "./timeline.ts";

function emptyDoc(): TimelineDocument {
	return {
		id: "test",
		duration: 1000,
		entities: { peers: {}, sessions: {}, messages: {} },
		rowOrder: { peers: [], sessions: [], messages: [] },
		rowHidden: { peers: [], sessions: [], messages: [] },
		rowLabelHidden: { peers: [], sessions: [], messages: [] },
		rowBodyHidden: { peers: [], sessions: [], messages: [] },
		allVisMode: "visible",
		categoryVisMode: {
			peers: "visible",
			sessions: "visible",
			messages: "visible",
		},
	};
}

Deno.test("snapshot round-trips recording.sources observations", () => {
	const doc = emptyDoc();
	doc.recording = {
		sources: [{
			id: "primary",
			meta: { kind: "authored" },
			observations: [
				{
					id: "e1",
					t: 0,
					kind: "peer-joined",
					peerId: "alice",
					profile: "pancake",
				},
			],
		}],
	};
	const snap = takeSnapshot(doc);

	// Mutate the primary source after snapshot.
	doc.recording.sources[0]!.observations.push(
		{
			id: "e2",
			t: 100,
			kind: "peer-joined",
			peerId: "bob",
			profile: "pancake",
		},
	);
	assertEquals(doc.recording.sources[0]!.observations.length, 2);

	restoreSnapshotInto(doc, snap);
	assertEquals(doc.recording!.sources[0]!.observations.length, 1);
	assertEquals(doc.recording!.sources[0]!.observations[0]!.id, "e1");
});

Deno.test("restore from a snapshot taken before recording was set clears it", () => {
	const doc = emptyDoc();
	const snap = takeSnapshot(doc); // no recording

	doc.recording = {
		sources: [{
			id: "primary",
			meta: { kind: "authored" },
			observations: [{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "pancake",
			}],
		}],
	};

	restoreSnapshotInto(doc, snap);
	assertEquals(doc.recording, undefined);
});

Deno.test("snapshot is independent — mutating snap doesn't reach doc", () => {
	const doc = emptyDoc();
	doc.recording = {
		sources: [{
			id: "primary",
			meta: { kind: "authored" },
			observations: [{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "pancake",
			}],
		}],
	};
	const snap = takeSnapshot(doc);

	// Mutate the snapshot's recording — doc must not change.
	snap.recording!.sources[0]!.observations.length = 0;
	assertEquals(doc.recording.sources[0]!.observations.length, 1);
});

Deno.test("snapshot round-trips doc.duration", () => {
	// Authoring grows `doc.duration` when an edit lands past the end
	// (`growDurationToFit` / `commitEntityAuthoring`), so undo must
	// restore it with everything else — a snapshot without it leaves
	// the timeline permanently extended after the edit is undone.
	const doc = emptyDoc();
	const snap = takeSnapshot(doc);
	doc.duration = 5000;
	restoreSnapshotInto(doc, snap);
	assertEquals(doc.duration, 1000);
});
