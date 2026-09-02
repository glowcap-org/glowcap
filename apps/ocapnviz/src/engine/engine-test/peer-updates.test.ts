import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { attachedEndpoint } from "../../schema/session-end.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

// ─────────────────── peer renames (the trajectory) ───────────────────
//
// A peer's name over time is modeled on a session's state over time:
// the name it joined under is the genesis value, each later name is
// a moment of its own.

/** A peer that joined at t=100 under its locator and answers to
 *  "carol" from t=400. */
function renamedPeerDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "peer-renames",
		duration: 5000,
		events: [
			{
				id: "p1",
				t: 100,
				kind: "peer-joined",
				peerId: "127.0.0.1:0",
				profile: "glowcap",
				label: "127.0.0.1:0",
			},
			{
				id: "p2",
				t: 400,
				kind: "peer-updated",
				peerId: "127.0.0.1:0",
				label: "carol",
			},
		],
	});
}

const labelTrack = (e: Engine) => e.doc.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label;

engineTest("set-peer-update replaces the value stated at that moment", () => {
	const e = new Engine(renamedPeerDoc());
	e.dispatch({
		kind: "set-peer-update",
		peerId: "127.0.0.1:0",
		t: 400,
		property: "label",
		value: "carol-away",
	});
	assertEquals(labelTrack(e), [{ t: 400, value: "carol-away" }]);
	// One observation, replaced in place — not two renames at one t.
	const renames = primaryObservations(e.doc).filter((ev) => ev.kind === "peer-updated");
	assertEquals(renames.length, 1);
});

engineTest("renaming a moment keeps the moment's identity", () => {
	// The Inspector row and the timeline's focus halo both address a
	// rename by its event id. Minting a new one per keystroke unmounts
	// the row being typed into, and the field loses focus after one
	// character.
	const e = new Engine(renamedPeerDoc());
	const idAt400 = () => primaryObservations(e.doc).find((ev) => ev.kind === "peer-updated" && ev.t === 400)?.id;
	const before = idAt400();
	e.dispatch({
		kind: "set-peer-update",
		peerId: "127.0.0.1:0",
		t: 400,
		property: "label",
		value: "c",
	});
	assertEquals(idAt400(), before);
	e.dispatch({
		kind: "set-peer-update",
		peerId: "127.0.0.1:0",
		t: 400,
		property: "label",
		value: "ca",
	});
	assertEquals(idAt400(), before);
});

engineTest("set-peer-update at a fresh t states a new moment", () => {
	const e = new Engine(renamedPeerDoc());
	e.dispatch({
		kind: "set-peer-update",
		peerId: "127.0.0.1:0",
		t: 900,
		property: "label",
		value: "carol-away",
	});
	assertEquals(labelTrack(e), [
		{ t: 400, value: "carol" },
		{ t: 900, value: "carol-away" },
	]);
});

engineTest("a moment before the peer arrives is refused", () => {
	const e = new Engine(renamedPeerDoc());
	e.dispatch({
		kind: "set-peer-update",
		peerId: "127.0.0.1:0",
		t: 50,
		property: "label",
		value: "too-early",
	});
	assertEquals(labelTrack(e), [{ t: 400, value: "carol" }]);
});

engineTest("remove-peer-update drops that moment", () => {
	const e = new Engine(renamedPeerDoc());
	e.dispatch({
		kind: "remove-peer-update",
		peerId: "127.0.0.1:0",
		t: 400,
		property: "label",
	});
	assertEquals(labelTrack(e), undefined);
	assertEquals(
		primaryObservations(e.doc).some((ev) => ev.kind === "peer-updated"),
		false,
	);
	// The peer answers to its join name again.
	assertEquals(e.doc.entities?.peers?.["127.0.0.1:0"]?.label, "127.0.0.1:0");
});

engineTest(
	"renaming a peer edits the name it joined under, not its later ones",
	() => {
		// The session model: editing a session's initial state leaves its
		// state keyframes alone. Editing a peer's name does the same.
		const e = new Engine(renamedPeerDoc());
		e.dispatch({
			kind: "update-peer",
			peerId: "127.0.0.1:0",
			patch: { label: "relay-tab" },
		});
		assertEquals(
			e.doc.entities?.peers?.["127.0.0.1:0"]?.label,
			"relay-tab",
		);
		assertEquals(labelTrack(e), [{ t: 400, value: "carol" }]);
	},
);

engineTest(
	"updatePeer can edit eternal-start peers (no peer-joined event)",
	() => {
		const e = new Engine(structuredClone(doc));
		(e.doc as TimelineDocument).entities = {
			peers: { eternal: { profile: "glowcap", label: "before" } },
		};
		e.seekTo(0);
		e.dispatch({
			kind: "update-peer",
			peerId: "eternal",
			patch: { label: "after", profile: "goblins" },
		});
		assertEquals(e.doc.entities?.peers?.eternal?.label, "after");
		assertEquals(e.doc.entities?.peers?.eternal?.profile, "goblins");
	},
);

engineTest(
	"delete-peer also strips entities.peers and cascades to entities.sessions/messages",
	() => {
		// Regression: pre-fix, delete-peer dropped events but left
		// `entities.peers[id]` behind. Then `#applyEternalEntities`
		// re-added the "deleted" peer from its stranded definition
		// on the next world rebuild — the peer wouldn't actually
		// disappear from the stage.
		const e = new Engine(structuredClone(doc));
		// Confirm entities exists for 'a' before deletion (parse
		// transform populated it from the peer-joined event).
		assertEquals(e.doc.entities?.peers?.a !== undefined, true);
		// Add an eternal-only session referencing peer 'a' so we can
		// verify cascade-through-entities works too.
		(e.doc as TimelineDocument).entities = {
			...(e.doc.entities ?? {}),
			sessions: {
				...(e.doc.entities?.sessions ?? {}),
				eternal_s_on_a: {
					a: attachedEndpoint("a"),
					b: attachedEndpoint("b"),
					codec: "syrup",
					captpVersion: "v1_0",
				},
			},
		};
		e.dispatch({ kind: "delete-peer", peerId: "a" });
		assertEquals(e.doc.entities?.peers?.a, undefined);
		// Cascade: eternal session that referenced 'a' is gone too.
		assertEquals(
			e.doc.entities?.sessions?.eternal_s_on_a,
			undefined,
		);
		// World rebuild: the deleted peer must NOT re-appear via the
		// eternal-entities pass.
		e.seekTo(0);
		assertEquals(findPeer(e.world, "a"), undefined);
	},
);

engineTest(
	"delete-message strips entities.messages too",
	() => {
		const e = new Engine(structuredClone(doc));
		assertEquals(e.doc.entities?.messages?.m1 !== undefined, true);
		e.dispatch({ kind: "delete-message", messageId: "m1" });
		assertEquals(e.doc.entities?.messages?.m1, undefined);
	},
);

engineTest(
	"repositionPeer mirrors the new position into entities.peers",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: 42, y: 7 },
		});
		assertEquals(e.doc.entities?.peers?.a?.position, { x: 42, y: 7 });
	},
);

engineTest(
	"reposition-peer under per-topology mode pins the peer at the drop point",
	() => {
		// The shared `doc` has no layoutMode, so the default force mode
		// is in play. Dropping a peer writes its authored position, and
		// the recomputed keyframes must hold it there EXACTLY — the
		// force sim arranges the free peers around the pin instead of
		// dragging the pinned one back toward the pack.
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: 777, y: -333 },
		});
		const peer = findPeer(e.world, "a");
		assert(peer);
		assertEquals(peer.position, { x: 777, y: -333 });
		assert(e.layout.keyframes.length > 0);
		for (const kf of e.layout.keyframes) {
			assertEquals(kf.layout.get("a"), { x: 777, y: -333 });
		}
		// The unpinned partner still gets a force-computed position,
		// not the pin's.
		const other = e.layout.keyframes[0]!.layout.get("b");
		assert(other);
		assert(other.x !== 777 || other.y !== -333);
	},
);

engineTest(
	"pinning a peer at its current layout position is a real change",
	() => {
		// The reposition no-op guard compares against the AUTHORED
		// position, not the live world one (the layout always fills the
		// world position, so a world comparison would swallow the
		// Inspector's "Pin here" — the defect this test was validated
		// against). Pinning an unpinned peer where it already sits must
		// write the pin and mint an undo step.
		const e = new Engine(structuredClone(doc));
		const placed = findPeer(e.world, "a")?.position;
		assert(placed);
		assert(!e.canUndo);
		// The detail-oriented half of the contract: pinning changes who
		// OWNS the position, so the stage must not visibly re-settle.
		// The warm re-derivation continues the annealing from the
		// current arrangement, so any residual motion is sub-visual —
		// held to under half a world unit here.
		const othersBefore = e.layout.keyframes.map((kf) =>
			new Map(
				[...kf.layout.entries()].filter(([id]) => id !== "a"),
			)
		);
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: placed.x, y: placed.y },
		});
		assert(e.canUndo);
		assertEquals(e.doc.entities?.peers?.a?.position, {
			x: placed.x,
			y: placed.y,
		});
		e.layout.keyframes.forEach((kf, i) => {
			for (const [id, pos] of kf.layout) {
				if (id === "a") continue;
				const before = othersBefore[i]!.get(id);
				assert(before);
				assert(
					Math.abs(pos.x - before.x) < 0.05 &&
						Math.abs(pos.y - before.y) < 0.05,
					`peer ${id} moved visibly on an ownership-only pin`,
				);
			}
		});
		// Re-pinning at the SAME authored coords is the true no-op.
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: placed.x, y: placed.y },
		});
		e.undo();
		assertEquals(e.doc.entities?.peers?.a?.position, undefined);
	},
);

engineTest(
	"pin-here then unpin is visually still end to end",
	() => {
		// The ownership-only round trip: pin a peer exactly where the
		// layout placed it, then unpin. Both edits change who owns the
		// position, not the position — so every peer, in every
		// keyframe, stays within sub-visual annealing residue of where
		// it started.
		const e = new Engine(structuredClone(doc));
		const before = e.layout.keyframes.map((kf) => new Map(kf.layout));
		const placed = findPeer(e.world, "a")?.position;
		assert(placed);
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: placed.x, y: placed.y },
		});
		e.dispatch({ kind: "clear-peer-position", peerId: "a" });
		// Exactly still, not approximately: the pin-add reused the era
		// verbatim, and the unpin's cold recompute reproduces the
		// pre-pin derivation bit for bit.
		e.layout.keyframes.forEach((kf, i) => {
			for (const [id, pos] of kf.layout) {
				assertEquals(
					pos,
					before[i]!.get(id),
					`peer ${id} moved across an ownership-only round trip`,
				);
			}
		});
	},
);

engineTest(
	"a transaction coalesces a scrub's dispatches into one undo step",
	() => {
		// The inspector scrubs and the stage drag both bracket their
		// continuous dispatches in one labeled transaction; the history
		// must see the gesture, not the pointer events.
		const e = new Engine(structuredClone(doc));
		e.beginTransaction("Move peer");
		for (let i = 1; i <= 5; i += 1) {
			e.dispatch({
				kind: "reposition-peer",
				peerId: "a",
				position: { x: i * 10, y: -i },
			});
		}
		e.endTransaction();
		assert(e.canUndo);
		e.undo();
		// One undo unwinds the whole gesture.
		assertEquals(e.doc.entities?.peers?.a?.position, undefined);
		assert(!e.canUndo);
	},
);
