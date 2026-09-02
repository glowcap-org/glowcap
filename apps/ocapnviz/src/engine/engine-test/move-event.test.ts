import { assert, assertEquals } from "@std/assert";
import { TimelineDocument } from "../timeline.ts";
import { Engine } from "../engine.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

// ─────────────────────── move-event intent ───────────────────────

engineTest("move-event slides a session-state-changed in time", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "e6", newT: 3000 },
	});
	const moved = primaryObservations(e.doc).find((ev) => ev.id === "e6");
	assertEquals(moved?.t, 3000);
	// Doc must remain sorted by t.
	const ts = primaryObservations(e.doc).map((ev) => ev.t);
	for (let i = 1; i < ts.length; i++) assert(ts[i]! >= ts[i - 1]!);
});

engineTest(
	"move-event on message-sent slides paired message-delivered (flight preserved)",
	() => {
		const e = new Engine(structuredClone(doc));
		// e4 is message-sent at t=1000, arrivalT=1500. Move to t=2500
		// → arrivalT should become 3000 (flight stays 500 ms),
		// delivered (e5) should follow.
		e.dispatch({
			kind: "move-event",
			move: { kind: "translate", eventId: "e4", newT: 2500 },
		});
		const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
		const delivered = primaryObservations(e.doc).find((ev) => ev.id === "e5");
		assertEquals(sent?.t, 2500);
		assertEquals(
			sent?.kind === "message-sent" ? sent.arrivalT : undefined,
			3000,
		);
		assertEquals(delivered?.t, 3000);
	},
);

engineTest(
	"move-event arrivalT override adjusts flight time without moving sent",
	() => {
		const e = new Engine(structuredClone(doc));
		// Right-edge drag: keep sent at 1000 but extend arrivalT to 2200.
		e.dispatch({
			kind: "move-event",
			move: { kind: "resize-end", eventId: "e4", newArrivalT: 2200 },
		});
		const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
		const delivered = primaryObservations(e.doc).find((ev) => ev.id === "e5");
		assertEquals(sent?.t, 1000);
		assertEquals(
			sent?.kind === "message-sent" ? sent.arrivalT : undefined,
			2200,
		);
		assertEquals(delivered?.t, 2200);
	},
);

engineTest(
	"move-event rejects session-state-changed moved before its session-opened",
	() => {
		const e = new Engine(structuredClone(doc));
		// e3 (session-opened) is at t=0; e6 (state-changed) wants
		// to go to t=-1 — should also reject negative t.
		e.dispatch({
			kind: "move-event",
			move: { kind: "translate", eventId: "e6", newT: -100 },
		});
		const ev = primaryObservations(e.doc).find((x) => x.id === "e6");
		assertEquals(ev?.t, 2000, "rejected move leaves event untouched");
	},
);

engineTest(
	"move-event rejects arrivalT < sentT",
	() => {
		const e = new Engine(structuredClone(doc));
		e.dispatch({
			kind: "move-event",
			move: { kind: "resize-end", eventId: "e4", newArrivalT: 500 },
		});
		const sent = primaryObservations(e.doc).find((ev) => ev.id === "e4");
		assertEquals(
			sent?.kind === "message-sent" ? sent.arrivalT : undefined,
			1500,
			"rejected — original arrivalT preserved",
		);
	},
);

engineTest("move-event slides a peer's renames with the peer", () => {
	// Dragging a peer's pill moves the whole peer: its departure and
	// the moments it changed name keep their spacing from the join,
	// the way a session's state keyframes ride along with it. A
	// rename left behind would rename the peer before it arrived.
	const peerDoc = TimelineDocument.parse({
		id: "peer-slide",
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
				t: 300,
				kind: "peer-updated",
				peerId: "127.0.0.1:0",
				label: "carol",
			},
			{ id: "p3", t: 900, kind: "peer-left", peerId: "127.0.0.1:0" },
		],
	});
	const e = new Engine(peerDoc);
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "p1", newT: 1100 },
	});
	const at = (id: string) => primaryObservations(e.doc).find((ev) => ev.id === id)?.t;
	assertEquals(at("p1"), 1100);
	assertEquals(at("p2"), 1300);
	assertEquals(at("p3"), 1900);
	assertEquals(
		e.doc.entities?.peers?.["127.0.0.1:0"]?.keyframes?.label,
		[{ t: 1300, value: "carol" }],
	);
});

engineTest("move-event slides a whole peer earlier", () => {
	// Ordering is judged against the finished gesture. Checking a slid
	// departure against where the join still sits would refuse every
	// backward drag, because the join has not been written yet.
	const peerDoc = TimelineDocument.parse({
		id: "peer-slide-back",
		duration: 5000,
		events: [
			{
				id: "p1",
				t: 1100,
				kind: "peer-joined",
				peerId: "x",
				profile: "glowcap",
			},
			{
				id: "p2",
				t: 1300,
				kind: "peer-updated",
				peerId: "x",
				label: "carol",
			},
			{ id: "p3", t: 1900, kind: "peer-left", peerId: "x" },
		],
	});
	const e = new Engine(peerDoc);
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "p1", newT: 100 },
	});
	const at = (id: string) => primaryObservations(e.doc).find((ev) => ev.id === id)?.t;
	assertEquals(at("p1"), 100);
	assertEquals(at("p2"), 300);
	assertEquals(at("p3"), 900);
});

engineTest("move-event refuses a rename dragged before its peer joins", () => {
	const peerDoc = TimelineDocument.parse({
		id: "peer-rename-order",
		duration: 5000,
		events: [
			{
				id: "p1",
				t: 1000,
				kind: "peer-joined",
				peerId: "x",
				profile: "glowcap",
			},
			{
				id: "p2",
				t: 1300,
				kind: "peer-updated",
				peerId: "x",
				label: "carol",
			},
		],
	});
	const e = new Engine(peerDoc);
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "p2", newT: 500 },
	});
	assertEquals(
		primaryObservations(e.doc).find((ev) => ev.id === "p2")?.t,
		1300,
		"refused — the rename stays inside the peer's life",
	);
});

engineTest("move-event past doc.duration auto-extends duration", () => {
	const e = new Engine(structuredClone(doc));
	// doc.duration is 5000; move e6 to 7000.
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "e6", newT: 7000 },
	});
	assertEquals(e.doc.duration, 7000);
	assertEquals(e.clock.duration, 7000);
});

engineTest("move-event same t is a no-op (no history entry)", () => {
	const e = new Engine(structuredClone(doc));
	assertEquals(e.canUndo, false);
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "e6", newT: 2000 },
	});
	assertEquals(e.canUndo, false, "no-op intent didn't push history");
});

engineTest("move-event is undoable", () => {
	const e = new Engine(structuredClone(doc));
	e.dispatch({
		kind: "move-event",
		move: { kind: "translate", eventId: "e6", newT: 3000 },
	});
	assertEquals(e.canUndo, true);
	e.undo();
	const ev = primaryObservations(e.doc).find((x) => x.id === "e6");
	assertEquals(ev?.t, 2000, "undo restores original t");
});
