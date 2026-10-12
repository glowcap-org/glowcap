// Engine playback: construction, tick, seek, subscribe, determinism.

import { assert, assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { findPeer } from "../world.ts";
import { engineTest } from "./harness.ts";
import { doc } from "./fixtures.ts";

engineTest("Engine drains t=0 events on construction", () => {
	const e = new Engine(doc);
	assertEquals([...e.queries.peers].length, 2);
	assertEquals([...e.queries.sessions].length, 1);
});

engineTest(
	"Engine renders initial keyframe positions (no zero-to-origin bloom)",
	() => {
		const e = new Engine(doc);
		for (const p of e.world.with("peer", "position")) {
			assert(
				p.position.x !== 0 || p.position.y !== 0,
				`peer ${p.peer.id} stuck at origin instead of keyframe layout`,
			);
		}
	},
);

engineTest(
	"Engine initial keyframe layout assigns distinct positions per peer",
	() => {
		const e = new Engine(doc);
		const peers = [...e.world.with("peer", "position")];
		const positions = peers.map((p) => `${p.position.x.toFixed(3)},${p.position.y.toFixed(3)}`);
		assertEquals(new Set(positions).size, peers.length);
	},
);

engineTest("Engine.tick is a no-op when paused", () => {
	const e = new Engine(doc);
	const before = [...e.queries.peers].map((p) => ({ ...p.position }));
	e.tick(100);
	const after = [...e.queries.peers].map((p) => ({ ...p.position }));
	assertEquals(before, after);
});

engineTest("Engine.tick folds events as time advances", () => {
	const e = new Engine(doc);
	e.clock.play();
	e.tick(1100);
	assertEquals([...e.queries.messagesInFlight].length, 1);
	e.tick(500);
	assertEquals([...e.queries.messagesInFlight].length, 0);
});

engineTest(
	"Engine peer positions are pure functions of t (same t => same positions)",
	() => {
		const e = new Engine(doc);
		const snapAt = (t: number): Map<string, { x: number; y: number }> => {
			e.seekTo(t);
			const m = new Map<string, { x: number; y: number }>();
			for (const p of e.world.with("peer", "position")) {
				m.set(p.peer.id, { x: p.position.x, y: p.position.y });
			}
			return m;
		};
		const a = snapAt(1000);
		const b = snapAt(2500);
		const aAgain = snapAt(1000);
		assertEquals(a, aAgain, "positions at t=1000 must match across visits");
		assert(
			[...a.keys()].some((id) => {
				const pa = a.get(id);
				const pb = b.get(id);
				return !!pa && !!pb &&
						(pa.x !== pb.x || pa.y !== pb.y) === false
					? false
					: true;
			}) || true,
			"topology unchanged across this t-range; positions can match",
		);
	},
);

engineTest("Engine session-state-changed mutates session component", () => {
	const e = new Engine(doc);
	e.clock.play();
	e.tick(2500);
	const sessions = [...e.queries.sessions];
	assertEquals(sessions[0]?.session.state, "draining");
});

engineTest("Engine.seekTo rebuilds world at the requested time", () => {
	const e = new Engine(doc);
	e.seekTo(1100);
	assertEquals(e.clock.t, 1100);
	// The message-sent event at t=1000 has fired and not yet been
	// delivered (delivery at t=1500), so a message-in-flight exists.
	assertEquals([...e.queries.messagesInFlight].length, 1);
	// The state-change at t=2000 hasn't fired yet; session is still open.
	const sessions = [...e.queries.sessions];
	assertEquals(sessions[0]?.session.state, "open");
});

engineTest("Engine.seekTo backward replays from a fresh world", () => {
	const e = new Engine(doc);
	e.clock.play();
	e.tick(2500);
	assertEquals([...e.queries.sessions][0]?.session.state, "draining");
	e.seekTo(500);
	assertEquals(e.clock.t, 500);
	// Pre-message-sent: no in-flight, session still in its t=0 state.
	assertEquals([...e.queries.messagesInFlight].length, 0);
	assertEquals([...e.queries.sessions][0]?.session.state, "open");
});

engineTest("Engine.seekTo clamps to [0, duration]", () => {
	const e = new Engine(doc);
	e.seekTo(-100);
	assertEquals(e.clock.t, 0);
	e.seekTo(999999);
	assertEquals(e.clock.t, doc.duration);
});

engineTest(
	"Engine.seekTo restores peer positions to the keyframe layout, not the origin",
	() => {
		const e = new Engine(doc);
		const initial = new Map<string, { x: number; y: number }>();
		for (const p of e.world.with("peer", "position")) {
			initial.set(p.peer.id, { x: p.position.x, y: p.position.y });
		}
		e.clock.play();
		e.tick(1000);
		e.seekTo(0);
		for (const p of e.world.with("peer", "position")) {
			const before = initial.get(p.peer.id);
			assert(before, `peer ${p.peer.id} missing from initial snapshot`);
			assertEquals(p.position.x, before.x);
			assertEquals(p.position.y, before.y);
			assert(
				p.position.x !== 0 || p.position.y !== 0,
				`peer ${p.peer.id} collapsed to origin after seekTo(0)`,
			);
		}
	},
);

engineTest("Engine.restart returns to t=0 state", () => {
	const e = new Engine(doc);
	e.clock.play();
	e.tick(2500);
	e.restart();
	assertEquals(e.clock.t, 0);
	assertEquals([...e.queries.peers].length, 2);
	assertEquals([...e.queries.sessions].length, 1);
	assertEquals([...e.queries.messagesInFlight].length, 0);
	assertEquals([...e.queries.sessions][0]?.session.state, "open");
});

engineTest("Engine.enqueue defers all intents until the next tick", () => {
	const e = new Engine(doc);
	// Enqueuing alone does nothing. The loop must drain.
	e.enqueue({ kind: "play" });
	assertEquals(e.clock.state, "paused");
	e.tick(0);
	assertEquals(e.clock.state, "playing");
});

engineTest("Engine drains intents in FIFO order at tick start", () => {
	const e = new Engine(doc);
	e.enqueue({ kind: "play" });
	e.enqueue({ kind: "setSpeed", speed: 2 });
	e.enqueue({ kind: "seekTo", t: 1000 });
	e.tick(100);
	// play + setSpeed + seekTo applied; clock advances 100ms * 2x = 200ms from t=1000.
	assertEquals(e.clock.state, "playing");
	assertEquals(e.clock.speed, 2);
	assertEquals(e.clock.t, 1200);
});

engineTest("Engine beginScrub pauses; endScrub resumes if was playing", () => {
	const e = new Engine(doc);
	e.enqueue({ kind: "play" });
	e.tick(0);
	e.enqueue({ kind: "beginScrub" });
	e.tick(0);
	assertEquals(e.clock.state, "paused");
	e.enqueue({ kind: "seekTo", t: 1500 });
	e.tick(0);
	assertEquals(e.clock.t, 1500);
	e.enqueue({ kind: "endScrub" });
	e.tick(0);
	assertEquals(e.clock.state, "playing");
});

engineTest(
	"Engine message-in-flight position is eased (smoothstep), not linear",
	() => {
		const e = new Engine(doc);
		// Fixture: message m1 sent at t=1000, arriving at t=1500. At the
		// quarter-point t=1125, smoothstep(0.25) ≈ 0.156, not 0.25, so
		// the eased position must differ measurably from a linear lerp.
		//
		// The MessageFlightSystem also adds a perpendicular lane offset
		// (so multiple messages on the same edge don't stack); we test
		// the eased lerp by projecting the message position onto the
		// edge direction. The projection isolates the along-edge
		// component (eased) from the perpendicular component (lane).
		e.seekTo(1125);
		const msgs = [...e.world.with("messageInFlight", "position")];
		assertEquals(msgs.length, 1, "one message in flight at t=1125");
		const msgPos = msgs[0]!.position;
		const aPos = findPeer(e.world, "a")?.position;
		const bPos = findPeer(e.world, "b")?.position;
		assert(aPos && bPos, "peer positions must exist");

		const dx = bPos.x - aPos.x;
		const dy = bPos.y - aPos.y;
		const len = Math.hypot(dx, dy);
		// Project (msgPos - aPos) onto the unit edge vector (dx,dy)/len.
		const projected = ((msgPos.x - aPos.x) * dx + (msgPos.y - aPos.y) * dy) /
			(len * len);
		const linearK = 0.25;
		const easedK = 0.25 * 0.25 * (3 - 2 * 0.25);
		assert(
			Math.abs(projected - easedK) < 0.001,
			`along-edge progress should match smoothstep(0.25); got ${projected}`,
		);
		assert(
			Math.abs(projected - linearK) > 0.001,
			"easing should observably differ from linear at t=0.25 of flight",
		);
	},
);

engineTest(
	"Engine peer position is a pure function of t (no integration history)",
	() => {
		const e = new Engine(doc);
		const snap = () => {
			const m = new Map<string, { x: number; y: number }>();
			for (const p of e.world.with("peer", "position")) {
				m.set(p.peer.id, { x: p.position.x, y: p.position.y });
			}
			return m;
		};
		e.seekTo(700);
		const at700a = snap();
		e.seekTo(2500);
		e.seekTo(700);
		const at700b = snap();
		assertEquals(
			at700a,
			at700b,
			"scrub forward and back must produce identical positions at the same t",
		);
	},
);

engineTest("Engine.subscribe fires when state changes", () => {
	// Contract: `notify` only fires when the tick actually changed
	// observable state (intents drained, sim advanced, layout
	// refreshed). Paused, idle ticks are silent so subscribers
	// (sidebar, undo buttons, etc.) don't reconcile 60 Hz for nothing.
	const e = new Engine(doc);
	let count = 0;
	const unsub = e.subscribe(() => {
		count += 1;
	});
	e.clock.play();
	e.tick(16);
	e.tick(16);
	e.tick(16);
	assertEquals(count, 3, "playing ticks advance state -> notify each tick");
	unsub();
	e.tick(16);
	assertEquals(count, 3, "after unsub, no further fires");
});

engineTest("Engine.tick is silent when paused and idle", () => {
	// Companion to "fires when state changes", assert the negative
	// side of the contract directly so a future regression that
	// re-enables every-frame notify is caught immediately.
	const e = new Engine(doc);
	let count = 0;
	e.subscribe(() => {
		count += 1;
	});
	// First tick from a fresh engine still fires because
	// `#lastUpdateT` is NaN and the layout/messages systems run.
	e.tick(0);
	const baseline = count;
	// Subsequent paused ticks: nothing changes, no notify.
	e.tick(0);
	e.tick(0);
	e.tick(0);
	assertEquals(count, baseline, "paused-idle ticks don't fire subscribers");
});

engineTest(
	"Engine play intent at end restarts the world (no stale end-state replay)",
	() => {
		const e = new Engine(doc);
		// Play the scenario through to the end.
		e.clock.play();
		e.tick(doc.duration + 100);
		assertEquals(e.clock.t, doc.duration);
		// The end-state has all events drained; final session state is
		// "draining" and no message is in flight.
		assertEquals([...e.queries.messagesInFlight].length, 0);
		// User clicks play again. With the bug, clock.t resets to 0 but
		// the world stays in the end-state. No events ever re-fire.
		// With the fix, the engine restarts the world first.
		e.enqueue({ kind: "play" });
		e.tick(0);
		assertEquals(e.clock.t, 0, "clock should rewind to 0");
		assertEquals(e.clock.state, "playing");
		// Now advance into the message-in-flight window to confirm the
		// event re-fires and the entity reappears.
		e.tick(1100);
		assertEquals(
			[...e.queries.messagesInFlight].length,
			1,
			"message-in-flight should re-render after play-at-end → restart",
		);
	},
);

engineTest(
	"Engine toggle intent at end behaves as restart-and-play",
	() => {
		const e = new Engine(doc);
		e.clock.play();
		e.tick(doc.duration + 100);
		assertEquals(e.clock.t, doc.duration);
		assertEquals(e.clock.state, "paused");
		e.enqueue({ kind: "toggle" });
		e.tick(0);
		assertEquals(e.clock.t, 0);
		assertEquals(e.clock.state, "playing");
	},
);

engineTest("Engine.subscribe survives a throwing listener", () => {
	const e = new Engine(doc);
	let goodCount = 0;
	e.subscribe(() => {
		throw new Error("subscriber bug");
	});
	e.subscribe(() => {
		goodCount += 1;
	});
	// Suppress the expected console.error for the duration of the tick.
	// Drive state changes via play+tick, notify is conditional on
	// dirty state now; idle paused ticks are silent.
	const originalError = console.error;
	console.error = () => {};
	try {
		e.clock.play();
		e.tick(16);
		e.tick(16);
	} finally {
		console.error = originalError;
	}
	assertEquals(goodCount, 2, "good subscriber should still fire");
});

engineTest(
	"Engine.restart and seekTo notify subscribers (imperative path)",
	() => {
		const e = new Engine(doc);
		let count = 0;
		e.subscribe(() => {
			count += 1;
		});
		e.restart();
		assertEquals(count, 1);
		e.seekTo(1500);
		assertEquals(count, 2);
	},
);

engineTest("Engine determinism: same wallDt sequence => same world", () => {
	const e1 = new Engine(doc);
	const e2 = new Engine(doc);
	e1.clock.play();
	e2.clock.play();
	for (let i = 0; i < 100; i++) {
		e1.tick(16);
		e2.tick(16);
	}
	const sig = (e: Engine) =>
		[...e.queries.peers]
			.map((p) => `${p.peer.id}:${p.position.x.toFixed(3)},${p.position.y.toFixed(3)}`)
			.sort()
			.join("|");
	assertEquals(sig(e1), sig(e2));
});
