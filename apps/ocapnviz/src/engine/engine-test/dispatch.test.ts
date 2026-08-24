// Builder dispatch and undo.

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc, emptyAuthoredDoc } from "./fixtures.ts";

engineTest("dispatch add-peer creates a peer at the requested position", () => {
	const e = new Engine(emptyAuthoredDoc());
	const peerId = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 100, y: 50 },
	});
	assert(peerId, "dispatch should return the new peer id");
	const peer = findPeer(e.world, peerId);
	assert(peer, "new peer must be in the world");
	assertEquals(peer.position, { x: 100, y: 50 });
});

engineTest("undo reverses an add-peer; redo re-applies it", () => {
	const e = new Engine(emptyAuthoredDoc());
	const peerId = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 100, y: 50 },
	})!;
	assertEquals([...e.queries.peers].length, 1);
	assert(e.canUndo);
	assert(!e.canRedo);
	e.undo();
	assertEquals([...e.queries.peers].length, 0);
	assert(!e.canUndo);
	assert(e.canRedo);
	e.redo();
	assertEquals([...e.queries.peers].length, 1);
	const restored = findPeer(e.world, peerId);
	assert(restored);
	assertEquals(restored.position, { x: 100, y: 50 });
});

engineTest(
	"undo replaces the world entity; stale entity references go inert",
	() => {
		// Architectural invariant the Stage relies on: after undo, the
		// peer's entity in the world is FRESH — its position reflects
		// the restored doc, not whatever the previous drag last set on
		// the now-orphaned entity. Any Pixi sprite handler that
		// captures a particular entity object in its closure goes
		// stale across undo's `seekTo` / `resetWorld`. The Stage's
		// pointerdown handler avoids this by reading from the rendered
		// sprite (whose position is refreshed every frame) instead of
		// the closure's entity. This test pins the engine half of that
		// contract — a fresh-not-orphan entity per restored snapshot.
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 100, y: 50 },
		})!;
		const stale = findPeer(e.world, peerId);
		assert(stale);
		e.dispatch({
			kind: "reposition-peer",
			peerId,
			position: { x: 200, y: 100 },
		});
		e.undo();
		const live = findPeer(e.world, peerId);
		assert(live);
		assertEquals(live.position, { x: 100, y: 50 });
		assert(
			live !== stale,
			"post-undo entity must be a fresh object, not the orphan",
		);
	},
);

engineTest("undo restores a peer's previous position after reposition", () => {
	const e = new Engine(emptyAuthoredDoc());
	const peerId = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 100, y: 50 },
	})!;
	e.dispatch({
		kind: "reposition-peer",
		peerId,
		position: { x: 200, y: 80 },
	});
	assertEquals(findPeer(e.world, peerId)!.position, { x: 200, y: 80 });
	e.undo();
	assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
});

engineTest(
	"transactions coalesce many dispatches into one undo step",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		})!;
		// Simulate a peer drag: many reposition dispatches inside one
		// transaction. After endTransaction, history should grow by ONE.
		e.beginTransaction();
		for (let i = 1; i <= 10; i++) {
			e.dispatch({
				kind: "reposition-peer",
				peerId,
				position: { x: i * 10, y: i * 5 },
			});
		}
		e.endTransaction();
		assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
		// One undo should restore the pre-drag position (origin), not
		// walk back through every intermediate move.
		e.undo();
		assertEquals(findPeer(e.world, peerId)!.position, { x: 0, y: 0 });
		// And one redo restores the final drag position.
		e.redo();
		assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });
	},
);

engineTest("a fresh dispatch invalidates the redo stack", () => {
	const e = new Engine(emptyAuthoredDoc());
	e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 10, y: 10 },
	});
	e.undo();
	assert(e.canRedo);
	// A new mutation after an undo should drop the redo branch — same
	// behavior as a text editor.
	e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 20, y: 20 },
	});
	assert(!e.canRedo);
	assert(e.canUndo);
});

engineTest(
	"dispatch is a no-op when the intent wouldn't change state",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 100, y: 50 },
		})!;
		// History grew by 1 (the add-peer).
		assert(e.canUndo);
		e.undo();
		e.redo(); // restore add-peer baseline
		assert(e.canUndo);
		assert(!e.canRedo);

		// Reposition to the SAME position — should be a no-op: no
		// history push, no redo invalidation, the peer doesn't move.
		e.dispatch({
			kind: "reposition-peer",
			peerId,
			position: { x: 100, y: 50 },
		});
		assert(e.canUndo);
		assert(!e.canRedo);
		assertEquals(findPeer(e.world, peerId)!.position, { x: 100, y: 50 });

		// Update-peer with the SAME label — also a no-op.
		e.dispatch({
			kind: "update-peer",
			peerId,
			patch: { label: peerId },
		});
		assert(e.canUndo);
		assert(!e.canRedo);
	},
);

engineTest(
	"transactions skip the history push when no actual change occurred",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		});
		// Open and close a transaction without dispatching anything —
		// empty txn, no doc change → no history push.
		e.beginTransaction("No-op");
		e.endTransaction();
		// Past stack is at 1 (the add-peer); no extra entry from the
		// empty transaction.
		e.undo();
		assertEquals([...e.queries.peers].length, 0);
	},
);

engineTest(
	"history entries carry intent-derived labels",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		})!;
		assertEquals(e.nextUndoLabel, "Add peer");
		e.dispatch({
			kind: "update-peer",
			peerId,
			patch: { label: "Renamed" },
		});
		assertEquals(e.nextUndoLabel, "Rename peer");
		e.dispatch({
			kind: "update-peer",
			peerId,
			patch: { profile: "goblins" },
		});
		assertEquals(e.nextUndoLabel, "Change profile");
		e.dispatch({
			kind: "reposition-peer",
			peerId,
			position: { x: 50, y: 50 },
		});
		assertEquals(e.nextUndoLabel, "Move peer");
		// After undo, the just-undone label is what `redo` would
		// re-apply — labels follow the action's forward direction.
		e.undo();
		assertEquals(e.nextRedoLabel, "Move peer");
	},
);

engineTest(
	"transaction labels appear on history entries",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		})!;
		e.beginTransaction("Edit designator");
		e.dispatch({
			kind: "update-peer",
			peerId,
			patch: { designator: "abc123" },
		});
		e.endTransaction();
		assertEquals(e.nextUndoLabel, "Edit designator");
	},
);

engineTest(
	"a buffer over a fixture bakes in no positions",
	() => {
		// The editable buffer is an Engine over a clone of the source
		// (`useBufferEngine`). It keeps the source's layout mode and
		// leaves unplaced peers unauthored: an authored position is a
		// pin the force modes hold fixed, so baking one in at load
		// would freeze a fixture that is supposed to animate.
		const buffer = new Engine(structuredClone(doc));
		assertEquals(buffer.doc.layoutMode, undefined);
		for (const ev of primaryObservations(buffer.doc)) {
			if (ev.kind !== "peer-joined") continue;
			assertEquals(
				ev.position,
				undefined,
				`peer ${ev.peerId} must stay unauthored`,
			);
		}
	},
);
