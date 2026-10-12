import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { attachedEndpoint } from "../../schema/session-end.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

engineTest(
	"placement while paused refreshes in-flight message positions",
	() => {
		// `#refreshStageAtPlayhead` must run messages as well as layout. A
		// placement that only marked `#lastUpdateT` current left dots on the
		// pre-drag wire until the clock advanced.
		const e = new Engine(structuredClone(doc));
		e.seekTo(1125);
		const before = [...e.world.with("messageInFlight", "position")];
		assertEquals(before.length, 1, "message should be in flight at t=1125");
		const msgBefore = {
			x: before[0]!.position.x,
			y: before[0]!.position.y,
		};
		const peerA = findPeer(e.world, "a");
		const at = peerA?.position;
		assert(at !== undefined);
		e.repositionPeer("a", {
			x: at.x + 400,
			y: at.y + 200,
		});
		e.tick(0);
		const after = [...e.world.with("messageInFlight", "position")];
		assertEquals(after.length, 1);
		assert(
			Math.hypot(
				after[0]!.position.x - msgBefore.x,
				after[0]!.position.y - msgBefore.y,
			) > 1,
			"in-flight message stayed on the pre-drag curve after a paused placement",
		);
	},
);

engineTest(
	"a transaction coalesces layout recomputes for Unpin-all-shaped clears",
	() => {
		// Each clear-peer-position cold-anneals, so Unpin all on a pinned
		// composition would pay that per peer. Inside a transaction the writes
		// land
		// and one recompute runs at endTransaction.
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: 10, y: 10 },
		});
		e.dispatch({
			kind: "reposition-peer",
			peerId: "b",
			position: { x: 20, y: 20 },
		});
		let recomputes = 0;
		const orig = e.layout.recompute.bind(e.layout);
		e.layout.recompute = () => {
			recomputes += 1;
			orig();
		};
		e.beginTransaction("Unpin all");
		e.dispatch({ kind: "clear-peer-position", peerId: "a" });
		e.dispatch({ kind: "clear-peer-position", peerId: "b" });
		assertEquals(recomputes, 0, "clears inside a txn must not anneal yet");
		e.endTransaction();
		assertEquals(recomputes, 1, "the gesture must anneal once at close");
		assertEquals(e.doc.entities?.peers?.a?.position, undefined);
		assertEquals(e.doc.entities?.peers?.b?.position, undefined);
	},
);

engineTest(
	"a transaction coalesces seeks for multi-delete and refreshes layout",
	() => {
		// Deletes rematerialize the world once, and leave no deleted peers in
		// keyframes.
		const e = new Engine(structuredClone(doc));
		let recomputes = 0;
		const origRecompute = e.layout.recompute.bind(e.layout);
		e.layout.recompute = () => {
			recomputes += 1;
			origRecompute();
		};
		e.beginTransaction("Delete selection");
		e.dispatch({ kind: "delete-peer", peerId: "a" });
		e.dispatch({ kind: "delete-peer", peerId: "b" });
		assertEquals(recomputes, 0, "deletes inside a txn must not anneal yet");
		e.endTransaction();
		assertEquals(recomputes, 1, "multi-delete must anneal once at close");
		for (const kf of e.layout.keyframes) {
			assertEquals(
				kf.layout.has("a"),
				false,
				"deleted peer must leave the keyframes",
			);
			assertEquals(
				kf.layout.has("b"),
				false,
				"deleted peer must leave the keyframes",
			);
		}
		assertEquals(findPeer(e.world, "a"), undefined);
		assertEquals(findPeer(e.world, "b"), undefined);
	},
);

engineTest(
	"repositionNodes pins a multi-select group in one placement pass",
	() => {
		const e = new Engine(structuredClone(doc));
		e.beginTransaction("Move selection");
		e.repositionNodes([
			{ kind: "peer", id: "a", position: { x: 11, y: 22 } },
			{ kind: "peer", id: "b", position: { x: 33, y: 44 } },
		]);
		e.endTransaction();
		assertEquals(e.doc.entities?.peers?.a?.position, { x: 11, y: 22 });
		assertEquals(e.doc.entities?.peers?.b?.position, { x: 33, y: 44 });
		e.undo();
		assertEquals(e.doc.entities?.peers?.a?.position, undefined);
		assertEquals(e.doc.entities?.peers?.b?.position, undefined);
	},
);

engineTest(
	"placement inside a transaction does not bump the document version",
	() => {
		// Mid-drag wakes follow the world (`version`) so the stage and
		// inspector track the pin; document-shaped panels (`docVersion`)
		// wait for the gesture to close.
		const e = new Engine(structuredClone(doc));
		e.beginTransaction("Move peer");
		const docBefore = e.docVersion;
		const versionBefore = e.version;
		e.repositionNodes([
			{ kind: "peer", id: "a", position: { x: 5, y: 5 } },
		]);
		assertEquals(
			e.docVersion,
			docBefore,
			"a mid-drag pin bumped the document version",
		);
		assert(
			e.version > versionBefore,
			"a mid-drag pin woke nobody, so this test proves nothing",
		);
		e.endTransaction();
		assert(
			e.docVersion > docBefore,
			"closing the drag left the document version behind",
		);
	},
);

engineTest(
	"retiming a moment inside a transaction wakes version without rematerializing yet",
	() => {
		// Timeline pills and scrub fields follow the live doc mid-gesture.
		// Layout/seek still coalesce to endTransaction (Unpin-all / multi-
		// delete), but a silent authoring seek left diamonds and span edges
		// visually frozen until release.
		const e = new Engine(structuredClone(doc));
		const stateEv = observationsOf(e.doc).find(
			(ev) => ev.kind === "session-state-changed",
		);
		assert(stateEv, "fixture needs a state-change moment to retime");
		const fromT = stateEv.t;
		e.beginTransaction("Move keyframe");
		const docBefore = e.docVersion;
		const versionBefore = e.version;
		let recomputes = 0;
		const origRecompute = e.layout.recompute.bind(e.layout);
		e.layout.recompute = () => {
			recomputes += 1;
			origRecompute();
		};
		e.dispatch({
			kind: "move-event",
			move: {
				kind: "translate",
				eventId: stateEv.id,
				newT: fromT + 50,
			},
		});
		assertEquals(
			observationsOf(e.doc).find((ev) => ev.id === stateEv.id)?.t,
			fromT + 50,
			"the observation must move on the live doc mid-gesture",
		);
		assertEquals(
			e.docVersion,
			docBefore,
			"mid-gesture retime bumped the document version",
		);
		assert(
			e.version > versionBefore,
			"mid-gesture retime woke nobody — timeline paint stays frozen",
		);
		assertEquals(recomputes, 0, "layout must stay deferred inside the txn");
		e.endTransaction();
		assertEquals(recomputes, 1, "the gesture must anneal once at close");
		assert(
			e.docVersion > docBefore,
			"closing the retime left the document version behind",
		);
	},
);

engineTest(
	"clear-peer-position unpins: the layout places the peer again",
	() => {
		// Pin, then unpin. After the clear, neither position carrier
		// holds the authored point, the intent is a no-op the second
		// time, and undo restores the pin. The full inverse of
		// reposition-peer's pin.
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "reposition-peer",
			peerId: "a",
			position: { x: 777, y: -333 },
		});
		e.dispatch({ kind: "clear-peer-position", peerId: "a" });
		assertEquals(e.doc.entities?.peers?.a?.position, undefined);
		for (const ev of observationsOf(e.doc)) {
			if (ev.kind === "peer-joined" && ev.peerId === "a") {
				assertEquals(ev.position, undefined);
			}
		}
		// Unpinning an OUTLIER pin hands the peer back to the layout,
		// which pulls it toward the pack, visible motion here is the
		// correct feedback that the simulation owns it again.
		const freed = e.layout.keyframes[0]!.layout.get("a");
		assert(freed);
		assert(freed.x !== 777 || freed.y !== -333);
		// Unpinning an unpinned peer is a no-op (no undo step minted).
		const undoDepthBefore = e.canUndo;
		e.dispatch({ kind: "clear-peer-position", peerId: "a" });
		assertEquals(e.canUndo, undoDepthBefore);
		// Undo restores the pin exactly.
		e.undo();
		assertEquals(e.doc.entities?.peers?.a?.position, { x: 777, y: -333 });
	},
);

engineTest(
	"set-peer-end works on eternal-start peers (cascade-aware validation)",
	() => {
		// An eternal-start peer lives in `entities.peers` with implicit
		// start. The cascade-aware validation accepts effective-start = 0
		// for eternal peers.
		const e = new Engine(structuredClone(doc));
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			peers: {
				...e.doc.entities?.peers,
				eternal_peer: { profile: "glowcap" },
			},
		};
		e.seekTo(0);
		e.dispatch({ kind: "set-peer-end", peerId: "eternal_peer", t: 2000 });
		// entity.timing.duration is now explicit (2000 − 0 = 2000).
		const def = e.doc.entities?.peers?.eternal_peer;
		assertEquals(def?.timing?.duration, { value: 2000, explicit: true });
	},
);

engineTest(
	"set-session-end works on eternal-start sessions",
	() => {
		const e = new Engine(structuredClone(doc));
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			sessions: {
				...e.doc.entities?.sessions,
				eternal_s: {
					a: attachedEndpoint("a"),
					b: attachedEndpoint("b"),
					codec: "syrup",
					captpVersion: "v1_0",
				},
			},
		};
		e.seekTo(0);
		e.dispatch({
			kind: "set-session-end",
			sessionId: "eternal_s",
			t: 3000,
		});
		const def = e.doc.entities?.sessions?.eternal_s;
		assertEquals(def?.timing?.duration, { value: 3000, explicit: true });
	},
);

engineTest(
	"eternal-entities pass does NOT inject sessions with future opened events",
	() => {
		// Regression: the parse transform populates
		// `entities.sessions` for sessions whose `session-opened`
		// event is later in the timeline. The eternal-entities pass
		// must not register them at t=0 just because they exist in
		// the entities map. They have an explicit creation event
		// that hasn't fired yet.
		const futureSessionDoc = TimelineDocument.parse({
			id: "test",
			duration: 5000,
			events: [
				{
					id: "p1",
					t: 0,
					kind: "peer-joined",
					peerId: "a",
					profile: "glowcap",
				},
				{
					id: "p2",
					t: 0,
					kind: "peer-joined",
					peerId: "b",
					profile: "goblins",
				},
				{
					id: "s_future",
					t: 3000, // FUTURE: session-opened hasn't replayed at t=0
					kind: "session-opened",
					sessionId: "future-session",
					a: { peer: "a" },
					b: { peer: "b" },
					codec: "syrup",
					captpVersion: "v1_0",
				},
			],
		});
		const e = new Engine(futureSessionDoc);
		// Entities populated by the transform, but the session
		// shouldn't be in the world yet at t=0.
		assertEquals(
			e.doc.entities?.sessions?.["future-session"] !== undefined,
			true,
		);
		assertEquals(
			[...e.world.with("session")].some(
				(s) => s.session.id === "future-session",
			),
			false,
		);
		// Seek past the opened event, now it should be in the world.
		e.seekTo(3500);
		assertEquals(
			[...e.world.with("session")].some(
				(s) => s.session.id === "future-session",
			),
			true,
		);
	},
);

engineTest(
	"clear-session-start makes session implicit but keeps it in world",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({ kind: "clear-session-start", sessionId: "s1" });
		// entity.timing.start is now implicit (inherits peer-overlap).
		assertEquals(
			e.doc.entities?.sessions?.s1?.timing?.start.explicit,
			false,
		);
		// Session entity still present (peer overlap covers t=0).
		assertEquals(
			[...e.world.with("session")].some((s) => s.session.id === "s1"),
			true,
		);
	},
);

engineTest(
	"message cascade: implicit start = session.effectiveStart; rejects out-of-bounds",
	() => {
		const e = new Engine(structuredClone(doc));
		// Define message m_new on session s1 with no message-sent
		// event, implicit start should cascade to session s1's
		// effective start.
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			messages: {
				...e.doc.entities?.messages,
				m_new: {
					sessionId: "s1",
					from: "a",
					to: "b",
					timing: {
						// Implicit start cascades from session.effectiveStart.
						start: { value: 0, explicit: false },
						// Duration explicit (messages always carry it). 200ms
						// flight stays well within the session's window.
						duration: { value: 200, explicit: true },
					},
				},
			},
		};
		// Session s1 in fixture: opened at t=0, no close → effective
		// end = doc.duration = 5000. Message inherits session.start as
		// its implicit start; its effective end = start + duration.
		assertEquals(e.effectiveStart("messages", "m_new"), 0);
		assertEquals(e.effectiveEnd("messages", "m_new"), 200);
		// Setting message start at t=2000 lies within session bounds,
		// accepted; entity.timing.start becomes explicit.
		e.dispatch({ kind: "set-message-start", messageId: "m_new", t: 2000 });
		assertEquals(
			e.doc.entities?.messages?.m_new?.timing?.start,
			{ value: 2000, explicit: true },
		);
		// Clearing returns the message to implicit-start without
		// losing its definition.
		e.dispatch({ kind: "clear-message-start", messageId: "m_new" });
		assertEquals(
			e.doc.entities?.messages?.m_new?.timing?.start.explicit,
			false,
		);
		assertEquals(e.doc.entities?.messages?.m_new !== undefined, true);
	},
);

engineTest(
	"set-message-end writes entity.timing.duration",
	() => {
		const e = new Engine(structuredClone(doc));
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			messages: {
				...e.doc.entities?.messages,
				m_end: {
					sessionId: "s1",
					from: "a",
					to: "b",
					timing: {
						start: { value: 1000, explicit: true },
						duration: { value: 200, explicit: true },
					},
				},
			},
		};
		// Move arrival to t=1500 → duration becomes 500 (1500 - 1000).
		e.dispatch({ kind: "set-message-end", messageId: "m_end", t: 1500 });
		assertEquals(
			e.doc.entities?.messages?.m_end?.timing?.duration,
			{ value: 500, explicit: true },
		);
		// Reject arrival before start.
		e.dispatch({ kind: "set-message-end", messageId: "m_end", t: 500 });
		assertEquals(
			e.doc.entities?.messages?.m_end?.timing?.duration,
			{ value: 500, explicit: true },
		);
	},
);

engineTest(
	"set-session-start rejects t before both endpoints exist",
	() => {
		const e = new Engine(structuredClone(doc));
		// Add the new session to the existing (projected) entities map,
		// replacing it wholesale would drop the projector's peer defs
		// and break bound resolution downstream.
		(e.doc as TimelineDocument).entities = {
			...e.doc.entities,
			sessions: {
				...e.doc.entities?.sessions,
				s_new: {
					a: attachedEndpoint("a"),
					b: attachedEndpoint("b"),
					codec: "syrup",
					captpVersion: "v1_0",
				},
			},
		};
		e.dispatch({ kind: "set-peer-start", peerId: "a", t: 200 });
		e.dispatch({ kind: "set-peer-start", peerId: "b", t: 800 });
		// Both endpoints exist at t>=800. Trying to set session
		// start at t=300 (before b joins) must be rejected.
		e.dispatch({ kind: "set-session-start", sessionId: "s_new", t: 300 });
		// s_new still has no explicit start (rejected). Either no
		// timing yet OR timing exists with implicit start.
		const afterReject = e.doc.entities?.sessions?.s_new?.timing?.start;
		if (afterReject !== undefined) {
			assertEquals(afterReject.explicit, false);
		}
		// t=900 lies after both endpoints, accepted.
		e.dispatch({ kind: "set-session-start", sessionId: "s_new", t: 900 });
		assertEquals(
			e.doc.entities?.sessions?.s_new?.timing?.start,
			{ value: 900, explicit: true },
		);
	},
);
