import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

// ─────────── Timeline row order and visibility ───────────
//
// `reorder-row` writes `doc.rowOrder[category]`; `set-row-vis-mode`
// writes `doc.rowHidden[category]`. Both fields are pruned to undefined
// when their list goes empty so unchanged docs round-trip cleanly.

engineTest("reorder-row sets per-category row order", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "reorder-row",
		category: "peers",
		order: ["b", "a"],
	});
	assertEquals(e.doc.rowOrder?.peers, ["b", "a"]);
	assertEquals(e.doc.rowOrder?.sessions, undefined);
});

engineTest("reorder-row with empty order clears that category override", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
	assertEquals(e.doc.rowOrder?.peers, ["b", "a"]);
	e.dispatch({ kind: "reorder-row", category: "peers", order: [] });
	// Per-category cleared AND no other category set ⇒ whole field
	// collapses to undefined (no `{ peers: undefined }` residue).
	assertEquals(e.doc.rowOrder, undefined);
});

engineTest("reorder-row only mentioning some entities is allowed", () => {
	// The intent doesn't require enumerating every entity. Listed
	// ids render first in that order; unlisted fall after by
	// first-event-t. The intent stores literally what the user
	// sent.
	const e = new Engine(structuredClone(doc));
	e.dispatch({ kind: "reorder-row", category: "peers", order: ["b"] });
	assertEquals(e.doc.rowOrder?.peers, ["b"]);
});

engineTest("reorder-row is undoable", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
	assertEquals(e.canUndo, true);
	e.undo();
	assertEquals(e.doc.rowOrder, undefined);
});

engineTest("reorder-row with same order is a no-op (no history push)", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
	const undosBefore = (() => {
		let n = 0;
		const e2 = new Engine(structuredClone(e.doc));
		while (e.canUndo) {
			e.undo();
			n += 1;
		}
		return { n, e2 };
	})();
	// Re-dispatch the same order on a fresh engine and confirm no
	// additional history entry accumulates.
	const e3 = new Engine(structuredClone(doc));
	e3.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
	e3.dispatch({ kind: "reorder-row", category: "peers", order: ["b", "a"] });
	// Still only one undoable step. The second dispatch was a no-op.
	e3.undo();
	assertEquals(e3.canUndo, false, "only one history entry was recorded");
	// Reference variable kept to avoid unused-var lint.
	assert(undosBefore.n >= 1);
});

engineTest("set-row-vis-mode hides + un-hides an entity", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "set-row-vis-mode",
		category: "peers",
		id: "a",
		mode: "both",
	});
	assertEquals(e.doc.rowHidden?.peers, ["a"]);
	e.dispatch({
		kind: "set-row-vis-mode",
		category: "peers",
		id: "a",
		mode: "visible",
	});
	// Cleaned up to undefined when the list goes empty so docs
	// without hidden rows don't carry empty-array residue.
	assertEquals(e.doc.rowHidden, undefined);
});

engineTest(
	"set-row-vis-mode transitions live between label / body / both / visible",
	() => {
		const e = new Engine(structuredClone(doc));
		// label-only → id sits in rowLabelHidden, others empty
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "label",
		});
		assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
		assertEquals(e.doc.rowHidden, undefined);
		assertEquals(e.doc.rowBodyHidden, undefined);
		// body-only → id moves to rowBodyHidden, label bucket clears
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "body",
		});
		assertEquals(e.doc.rowBodyHidden?.peers, ["a"]);
		assertEquals(e.doc.rowLabelHidden, undefined);
		// both → id moves to rowHidden, body bucket clears
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "both",
		});
		assertEquals(e.doc.rowHidden?.peers, ["a"]);
		assertEquals(e.doc.rowBodyHidden, undefined);
		// visible → id absent from all three
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "visible",
		});
		assertEquals(e.doc.rowHidden, undefined);
		assertEquals(e.doc.rowLabelHidden, undefined);
		assertEquals(e.doc.rowBodyHidden, undefined);
	},
);

engineTest("set-row-vis-mode re-applying the same mode is a no-op", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "set-row-vis-mode",
		category: "peers",
		id: "a",
		mode: "both",
	});
	const beforeCanUndo = e.canUndo;
	e.dispatch({
		kind: "set-row-vis-mode",
		category: "peers",
		id: "a",
		mode: "both",
	});
	// No additional history entry: undo once returns to pre-hide.
	e.undo();
	assertEquals(e.doc.rowHidden, undefined);
	assertEquals(beforeCanUndo, true);
});

engineTest("set-row-vis-mode is undoable", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "set-row-vis-mode",
		category: "peers",
		id: "a",
		mode: "both",
	});
	assertEquals(e.canUndo, true);
	e.undo();
	assertEquals(e.doc.rowHidden, undefined);
});

engineTest(
	"set-category-vis-mode stores a flag at the doc level, doesn't touch entities",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "both",
		});
		assertEquals(e.doc.categoryVisMode?.peers, "both");
		// Per-entity arrays UNTOUCHED. The cascade composes at
		// render time; the category flag doesn't blast through to
		// individual entities anymore.
		assertEquals(e.doc.rowHidden, undefined);
		assertEquals(e.doc.rowLabelHidden, undefined);
		assertEquals(e.doc.rowBodyHidden, undefined);
	},
);

engineTest(
	"set-category-vis-mode 'visible' clears its flag entry",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "label",
		});
		assertEquals(e.doc.categoryVisMode?.peers, "label");
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "visible",
		});
		// Flag is absent → category mode reads as "visible" (default).
		assertEquals(e.doc.categoryVisMode, undefined);
		assertEquals(e.categoryVisMode("peers"), "visible");
	},
);

engineTest(
	"set-category-vis-mode preserves per-entity overrides (independent flags)",
	() => {
		const e = new Engine(structuredClone(doc));
		// Set an entity flag first.
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "label",
		});
		assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
		// Setting the category flag does NOT wipe entity state.
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "body",
		});
		assertEquals(e.doc.categoryVisMode?.peers, "body");
		assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
		// Cycle category back to visible, entity flag survives.
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "visible",
		});
		assertEquals(e.doc.categoryVisMode, undefined);
		assertEquals(e.doc.rowLabelHidden?.peers, ["a"]);
	},
);

engineTest(
	"set-all-vis-mode stores a single doc-level flag",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({ kind: "set-all-vis-mode", mode: "both" });
		assertEquals(e.doc.allVisMode, "both");
		assertEquals(e.allVisMode(), "both");
		// Per-category and per-entity arrays UNTOUCHED.
		assertEquals(e.doc.categoryVisMode, undefined);
		assertEquals(e.doc.rowHidden, undefined);
		// Cycle back to visible, flag clears.
		e.dispatch({ kind: "set-all-vis-mode", mode: "visible" });
		assertEquals(e.doc.allVisMode, undefined);
		assertEquals(e.allVisMode(), "visible");
	},
);

engineTest(
	"categoryVisMode returns the stored flag, NOT a survey of entities",
	() => {
		// With independent flags, the category mode doesn't read
		// entity state at all, it's just the user's own setting.
		const e = new Engine(structuredClone(doc));
		assertEquals(e.categoryVisMode("peers"), "visible");
		// Setting per-entity flags doesn't change the category flag.
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "label",
		});
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "b",
			mode: "both",
		});
		assertEquals(e.categoryVisMode("peers"), "visible");
		// Only setCategoryVisMode changes the category flag.
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "body",
		});
		assertEquals(e.categoryVisMode("peers"), "body");
	},
);

engineTest(
	"effectiveRowVisMode composes the all → category → entity cascade as union-of-hides",
	() => {
		const e = new Engine(structuredClone(doc));
		// All defaults → fully visible.
		assertEquals(e.effectiveRowVisMode("peers", "a"), "visible");
		// Entity flag alone → entity flag is the only contributor.
		e.dispatch({
			kind: "set-row-vis-mode",
			category: "peers",
			id: "a",
			mode: "label",
		});
		assertEquals(e.effectiveRowVisMode("peers", "a"), "label");
		assertEquals(e.effectiveRowVisMode("peers", "b"), "visible"); // unrelated
		// Category=body unions with entity=label → both hides apply.
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "body",
		});
		assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
		// Peer b has no entity flag; only category=body contributes.
		assertEquals(e.effectiveRowVisMode("peers", "b"), "body");
		// All=both saturates, already-hidden axes stay hidden, the rest hide too.
		e.dispatch({ kind: "set-all-vis-mode", mode: "both" });
		assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
		assertEquals(e.effectiveRowVisMode("sessions", "s1"), "both");
		// Clear the all flag, union of (category=body, entity=label) re-emerges as both.
		e.dispatch({ kind: "set-all-vis-mode", mode: "visible" });
		assertEquals(e.effectiveRowVisMode("peers", "a"), "both");
		// Clear the category, entity flag (label on a) is the only contributor again.
		e.dispatch({
			kind: "set-category-vis-mode",
			category: "peers",
			mode: "visible",
		});
		assertEquals(e.effectiveRowVisMode("peers", "a"), "label");
		assertEquals(e.effectiveRowVisMode("peers", "b"), "visible");
	},
);

engineTest(
	"effectiveRowVisMode: parametric matrix — every (all, cat, entity) triple unions to OR of axis bits",
	() => {
		// The 4×4×4 = 64 triples are too many to enumerate; this test
		// covers the asymmetric cases the bug fix is specifically about
		// (orthogonal-axis combinations that a winner-take-all model gets
		// wrong) plus a few sanity rows.
		const cases: Array<
			{
				all: "visible" | "label" | "body" | "both";
				cat: typeof cases[0]["all"];
				entity: typeof cases[0]["all"];
				expected: typeof cases[0]["all"];
			}
		> = [
			// Each level contributes ZERO non-trivial bits → visible.
			{
				all: "visible",
				cat: "visible",
				entity: "visible",
				expected: "visible",
			},
			// Orthogonal axes union: label here + body there → both.
			{ all: "label", cat: "visible", entity: "body", expected: "both" },
			{ all: "visible", cat: "label", entity: "body", expected: "both" },
			{ all: "body", cat: "label", entity: "visible", expected: "both" },
			// All=both saturates, entity can't un-hide.
			{
				all: "both",
				cat: "visible",
				entity: "visible",
				expected: "both",
			},
			// Category=both saturates regardless of entity.
			{ all: "visible", cat: "both", entity: "label", expected: "both" },
			// Same-axis stacking is idempotent.
			{ all: "label", cat: "label", entity: "label", expected: "label" },
			// Identity row. Only entity contributes.
			{
				all: "visible",
				cat: "visible",
				entity: "both",
				expected: "both",
			},
		];
		for (const c of cases) {
			const e = new Engine(structuredClone(doc));
			e.dispatch({ kind: "set-all-vis-mode", mode: c.all });
			e.dispatch({
				kind: "set-category-vis-mode",
				category: "peers",
				mode: c.cat,
			});
			e.dispatch({
				kind: "set-row-vis-mode",
				category: "peers",
				id: "a",
				mode: c.entity,
			});
			assertEquals(
				e.effectiveRowVisMode("peers", "a"),
				c.expected,
				`all=${c.all} cat=${c.cat} entity=${c.entity}`,
			);
		}
	},
);

engineTest(
	"add-peer writes the peer definition without inventing an observation",
	() => {
		// Build-mode edits write the identity source directly; capture events are
		// reserved for facts a source actually observed.
		const e = new Engine(structuredClone(doc));
		const observationsBefore = observationsOf(e.doc).length;
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			label: "Carol",
			position: { x: 10, y: 20 },
		}) as string;
		const def = e.doc.entities?.peers?.[peerId];
		assertEquals(def?.profile, "glowcap");
		assertEquals(def?.label, "Carol");
		assertEquals(def?.position, { x: 10, y: 20 });
		assertEquals(observationsOf(e.doc).length, observationsBefore);
	},
);

engineTest(
	"clear-peer-start makes a peer eternal but keeps it on the stage",
	() => {
		const e = new Engine(structuredClone(doc));
		// Engine constructor projected entities + timing from the
		// peer-joined observations; peer 'a' is already in the world.
		assertEquals(findPeer(e.world, "a") !== undefined, true);
		e.dispatch({ kind: "clear-peer-start", peerId: "a" });
		// Timing's start is now implicit (eternal-start).
		assertEquals(
			e.doc.entities?.peers?.a?.timing?.start.explicit,
			false,
		);
		// But the peer is still in the world (eternal-start = world.start = 0).
		assertEquals(findPeer(e.world, "a") !== undefined, true);
	},
);

engineTest(
	"set-peer-start sets explicit start on an eternal peer's entity",
	() => {
		const e = new Engine(structuredClone(doc));
		// Define peer 'c' as eternal (no explicit start), then pin a
		// start time. Identity stays on the entity def; setPeerStart
		// mutates entity.timing.start.
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			peers: {
				...e.doc.entities?.peers,
				c: {
					profile: "goblins",
					label: "Carol",
					position: { x: 5, y: 7 },
				},
			},
		};
		e.seekTo(0); // Force a world rebuild so 'c' lands in world.
		assertEquals(findPeer(e.world, "c")?.peer.label, "Carol");
		e.dispatch({ kind: "set-peer-start", peerId: "c", t: 250 });
		const def = e.doc.entities?.peers?.c;
		assertEquals(def?.timing?.start, { value: 250, explicit: true });
		assertEquals(def?.profile, "goblins");
		assertEquals(def?.label, "Carol");
		assertEquals(def?.position, { x: 5, y: 7 });
	},
);

engineTest(
	"undo/redo round-trips entities map",
	() => {
		// Fixture has peer-joined events for 'a' and 'b'. The parse
		// transform auto-populates entities.peers for them, so the
		// baseline isn't empty. The new peer added by `add-peer`
		// appears / disappears across undo / redo.
		const e = new Engine(structuredClone(doc));
		const before = structuredClone(e.doc.entities);
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "glowcap",
			label: "Test",
			position: { x: 0, y: 0 },
		}) as string;
		assertEquals(e.doc.entities?.peers?.[peerId] !== undefined, true);
		e.undo();
		assertEquals(
			JSON.stringify(e.doc.entities),
			JSON.stringify(before),
		);
		e.redo();
		assertEquals(e.doc.entities?.peers?.[peerId] !== undefined, true);
	},
);

engineTest(
	"effectiveStart cascades: peer→world, session→peers, message→session",
	() => {
		// Fixture peer 'a' joined at t=0; session s1 opened at t=0;
		// message m1 sent at t=1000. All explicit.
		const e = new Engine(structuredClone(doc));
		assertEquals(e.effectiveStart("peers", "a"), 0);
		assertEquals(e.effectiveStart("sessions", "s1"), 0);
		assertEquals(e.effectiveStart("messages", "m1"), 1000);
		// Make peer 'a' eternal-start (no peer-joined event). Define
		// it in entities first so the eternal-replay pass keeps it
		// in the world.
		(e.doc as TimelineDocument).entities = {
			peers: { a: { profile: "glowcap" } },
		};
		e.dispatch({ kind: "clear-peer-start", peerId: "a" });
		// Peer 'a' now implicit-start = 0 (world start). Session s1
		// still has an explicit start at 0 so unchanged.
		assertEquals(e.effectiveStart("peers", "a"), 0);
		assertEquals(e.effectiveStart("sessions", "s1"), 0);
	},
);

engineTest(
	"session-start cascade: implicit start = max(endpoint starts)",
	() => {
		const e = new Engine(structuredClone(doc));
		// Engine constructor already projected entities + timing from
		// the event stream, peer a, peer b, session s1 are already
		// defined with timing derived from the peer-joined / session-
		// opened observations. Move peer 'b' to an explicit later
		// start, clear session start, session's effective start
		// should follow peer 'b'.
		e.dispatch({ kind: "set-peer-start", peerId: "b", t: 500 });
		e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
		// Peer a still at 0, peer b at 500 → session inherits max(0, 500) = 500.
		assertEquals(e.effectiveStart("sessions", "s1"), 500);
	},
);

engineTest(
	"updatePeer mirrors edits into entities.peers (source of truth)",
	() => {
		// Regression: updatePeer must patch entities.peers as well as the
		// event payload. Sidebar reads from entities.peers,
		// so the mirror is required or the user's edit appears to
		// vanish on next render.
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "update-peer",
			peerId: "a",
			patch: { label: "Renamed", profile: "goblins" },
		});
		assertEquals(e.doc.entities?.peers?.a?.label, "Renamed");
		assertEquals(e.doc.entities?.peers?.a?.profile, "goblins");
	},
);
