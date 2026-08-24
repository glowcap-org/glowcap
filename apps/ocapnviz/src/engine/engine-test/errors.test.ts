import { assert, assertEquals } from "@std/assert";
import { Engine } from "../engine.ts";
import { attachedEndpoint } from "../../schema/session-end.ts";
import { primaryObservations } from "../temporal/recording-access.ts";
import { engineTest } from "./harness.ts";
import { emptyAuthoredDoc } from "./fixtures.ts";

// ---------------------------------------------------------------------------
// Error channel — `validate`, `onError`, drain/dispatch/subscriber capture
// ---------------------------------------------------------------------------

engineTest("validate accepts ordinary playback and builder intents", () => {
	const e = new Engine(emptyAuthoredDoc());
	const result = e.validate({ kind: "play" });
	assert(result.ok);

	const builderResult = e.validate({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	});
	assert(builderResult.ok);
});

engineTest("onError fires when an enqueued intent throws during drain", () => {
	const e = new Engine(emptyAuthoredDoc());
	const captured: string[] = [];
	e.onError((err) => captured.push(err.code));

	// Inject a poisoned intent that the engine can't dispatch. The
	// control-intent dispatcher does an exhaustive switch on `kind`,
	// and we can force a throw by stubbing one of the clock methods.
	const originalPlay = e.clock.play.bind(e.clock);
	e.clock.play = () => {
		throw new Error("simulated clock failure");
	};
	try {
		e.enqueue({ kind: "play" });
		e.tick(0);
	} finally {
		e.clock.play = originalPlay;
	}

	assertEquals(captured, ["internal"]);
});

engineTest(
	"onError fires when dispatch throws; subsequent dispatches still work",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const captured: string[] = [];
		e.onError((err) => captured.push(err.code));

		// Force a throw inside dispatch on the authoring path. Authoring no
		// longer calls the public `seekTo` hook directly; it asks the context
		// for a layout recompute and authoring seek.
		const originalRecompute = e.layout.recompute.bind(e.layout);
		let firstCall = true;
		e.layout.recompute = () => {
			if (firstCall) {
				firstCall = false;
				throw new Error("simulated mutation failure");
			}
			originalRecompute();
		};

		const first = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		});
		assertEquals(first, undefined);
		assertEquals(captured, ["internal"]);

		// Second dispatch succeeds — the engine is not wedged.
		const second = e.dispatch({
			kind: "add-peer",
			profile: "goblins",
			position: { x: 10, y: 10 },
		});
		assert(typeof second === "string");
		assertEquals(captured.length, 1);
	},
);

engineTest("onError fires when a post-tick subscriber throws", () => {
	const e = new Engine(emptyAuthoredDoc());
	const errors: string[] = [];
	e.onError((err) => errors.push(err.code));

	e.subscribe(() => {
		throw new Error("simulated subscriber failure");
	});
	// Touch the engine so #notify fires.
	e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	});

	assertEquals(errors, ["internal"]);
});

engineTest("onError unsubscribe stops further deliveries", () => {
	const e = new Engine(emptyAuthoredDoc());
	let count = 0;
	const unsubscribe = e.onError(() => {
		count += 1;
	});

	e.subscribe(() => {
		throw new Error("boom");
	});
	e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	});
	assertEquals(count, 1);

	unsubscribe();
	e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 10, y: 10 },
	});
	assertEquals(count, 1);
});

engineTest(
	"onError listeners are isolated — one throwing listener doesn't starve others",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		let goodCalls = 0;
		e.onError(() => {
			throw new Error("bad listener");
		});
		e.onError(() => {
			goodCalls += 1;
		});

		e.subscribe(() => {
			throw new Error("subscriber boom");
		});
		e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		});

		assertEquals(goodCalls, 1);
	},
);

engineTest(
	"dispatch throw rolls back partial mutation; no dead undo entry leaks",
	() => {
		const e = new Engine(emptyAuthoredDoc());

		// Pre-throw baseline: empty doc, no undo. Force the throw on the
		// FIRST dispatch so the canUndo assertion below stays crisp.
		assertEquals(e.canUndo, false);
		const baselineState = JSON.stringify({
			entities: e.doc.entities,
			events: primaryObservations(e.doc),
		});

		// Force a throw partway through dispatch. `add-peer` bumps
		// `#authoredCounter`, runs `#definePeer`, then calls
		// commitEntityAuthoring → recomputeLayout — stub recompute to
		// throw on the first call. Without rollback the counter + entities
		// advance and leak; without record-on-success the history
		// would gain a dead entry.
		const captured: string[] = [];
		e.onError((err) => captured.push(err.code));
		const originalRecompute = e.layout.recompute.bind(e.layout);
		let thrown = 0;
		e.layout.recompute = () => {
			if (thrown === 0) {
				thrown += 1;
				throw new Error("simulated mid-dispatch failure");
			}
			originalRecompute();
		};

		const first = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		});
		assertEquals(first, undefined);
		assertEquals(captured, ["internal"]);

		// Doc state byte-identical to baseline — full atomic rollback.
		assertEquals(
			JSON.stringify({
				entities: e.doc.entities,
				events: primaryObservations(e.doc),
			}),
			baselineState,
		);
		// No undo entry recorded — recordBefore only fires on success.
		assertEquals(e.canUndo, false);

		// Next dispatch succeeds and mints `peer-1` — the throw didn't
		// burn the counter (otherwise we'd see `peer-2`).
		const second = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 20, y: 20 },
		});
		assertEquals(second, "peer-1");
		assertEquals(e.canUndo, true);
	},
);

engineTest(
	"failed transaction dispatch clears deferred layout and seek stage",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		const a = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		})!;
		const b = e.dispatch({
			kind: "add-peer",
			profile: "goblins",
			position: { x: 10, y: 10 },
		})!;
		const sid = e.dispatch({
			kind: "open-session",
			a: attachedEndpoint(a),
			b: attachedEndpoint(b),
		})!;
		e.seekTo(e.doc.duration);

		let recomputes = 0;
		const originalRecompute = e.layout.recompute.bind(e.layout);
		e.layout.recompute = () => {
			recomputes += 1;
			originalRecompute();
		};

		const captured: string[] = [];
		e.onError((err) => captured.push(err.code));
		e.beginTransaction("Failed gesture");
		e.dispatch({ kind: "clear-peer-position", peerId: a });
		const beforeFailure = recomputes;

		const originalSetDuration = e.clock.setDuration.bind(e.clock);
		let failSetDuration = true;
		e.clock.setDuration = (duration) => {
			if (failSetDuration) {
				failSetDuration = false;
				throw new Error("simulated duration failure");
			}
			originalSetDuration(duration);
		};
		const failed = e.dispatch({
			kind: "send-message",
			sessionId: sid,
			from: a,
			to: b,
			flightMs: 1000,
		});
		assertEquals(failed, undefined);
		assertEquals(captured, ["internal"]);
		assertEquals(
			recomputes,
			beforeFailure + 1,
			"rollback should recompute once, not replay stale deferred work",
		);

		e.endTransaction();
		assertEquals(
			recomputes,
			beforeFailure + 1,
			"transaction close replayed staged work from the failed dispatch",
		);
		assertEquals(e.doc.entities?.peers?.[a]?.position, { x: 0, y: 0 });
		assertEquals(e.canUndo, true);
	},
);

engineTest(
	"delete-peer dispatches for eternal-start peers (no peer-joined event)",
	() => {
		const e = new Engine(emptyAuthoredDoc());
		// Create a peer the normal way, then clear-peer-start to make
		// it eternal (entities-only, no peer-joined event).
		const peerId = e.dispatch({
			kind: "add-peer",
			profile: "pancake",
			position: { x: 0, y: 0 },
		});
		assert(typeof peerId === "string");
		e.dispatch({ kind: "clear-peer-start", peerId });
		assert(
			!primaryObservations(e.doc).some(
				(ev) => ev.kind === "peer-joined" && ev.peerId === peerId,
			),
			"precondition: peer-joined event removed",
		);
		assert(
			e.doc.entities?.peers?.[peerId] !== undefined,
			"precondition: entities entry still present",
		);

		// Before the fix this short-circuited as no-op.
		e.dispatch({ kind: "delete-peer", peerId });
		assertEquals(e.doc.entities?.peers?.[peerId], undefined);
	},
);

// ---------------------------------------------------------------------------
// Rename — engine/authoring/identity.ts
// ---------------------------------------------------------------------------

engineTest("renamePeer rewrites entities + events + row state", () => {
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const sid = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint(a),
		b: attachedEndpoint(b),
	})!;
	e.dispatch({
		kind: "send-message",
		sessionId: sid,
		from: a,
		to: b,
		label: "ping",
	});
	e.dispatch({ kind: "reorder-row", category: "peers", order: [b, a] });

	e.dispatch({ kind: "rename-peer", oldId: a, newId: "alice" });

	// Entities map keyed by new id.
	assert(e.doc.entities?.peers?.alice !== undefined);
	assertEquals(e.doc.entities?.peers?.[a], undefined);
	// entities-cross-ref updated on session definition.
	const sessionDef = e.doc.entities?.sessions?.[sid];
	assertEquals(sessionDef?.a?.peer, "alice");
	// message-sent endpoint cross-ref on entities.
	const msgDef = Object.values(e.doc.entities?.messages ?? {})[0];
	assertEquals(msgDef?.from, "alice");
	// rowOrder updated.
	assertEquals(e.doc.rowOrder?.peers, [b, "alice"]);
});

engineTest("rename-* rejects collisions; doc untouched", () => {
	const e = new Engine(emptyAuthoredDoc());
	const captured: string[] = [];
	e.onError((err) => captured.push(err.code));
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const baseline = JSON.stringify({
		entities: e.doc.entities,
		events: primaryObservations(e.doc),
	});

	// Try to rename a → b. Collision → error on the bus; doc unchanged.
	e.dispatch({ kind: "rename-peer", oldId: a, newId: b });

	assertEquals(captured, ["collision"]);
	assertEquals(
		JSON.stringify({
			entities: e.doc.entities,
			events: primaryObservations(e.doc),
		}),
		baseline,
	);
});

engineTest("validate(rename-*) surfaces collision without mutating", () => {
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const baseline = JSON.stringify({
		entities: e.doc.entities,
		events: primaryObservations(e.doc),
	});

	// Collision target.
	const collide = e.validate({ kind: "rename-peer", oldId: a, newId: b });
	assert(!collide.ok);
	assertEquals(collide.error.code, "collision");

	// Same-id "rename" is a no-op, validate passes.
	const noop = e.validate({ kind: "rename-peer", oldId: a, newId: a });
	assert(noop.ok);

	// Fresh id passes validation.
	const fresh = e.validate({ kind: "rename-peer", oldId: a, newId: "alice" });
	assert(fresh.ok);

	// Doc unchanged through all three checks.
	assertEquals(
		JSON.stringify({
			entities: e.doc.entities,
			events: primaryObservations(e.doc),
		}),
		baseline,
	);
});

engineTest("renameSession rewrites events + cross-refs", () => {
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const sid = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint(a),
		b: attachedEndpoint(b),
	})!;
	e.dispatch({ kind: "send-message", sessionId: sid, from: a, to: b });

	e.dispatch({ kind: "rename-session", oldId: sid, newId: "main-chan" });

	assert(e.doc.entities?.sessions?.["main-chan"] !== undefined);
	assertEquals(e.doc.entities?.sessions?.[sid], undefined);
	// entities.messages[*].sessionId follows.
	const msgDefs = Object.values(e.doc.entities?.messages ?? {});
	assert(msgDefs.every((d) => d.sessionId === "main-chan"));
});

engineTest("renameMessage rewrites sent + delivered events", () => {
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const sid = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint(a),
		b: attachedEndpoint(b),
	})!;
	const mid = e.dispatch({
		kind: "send-message",
		sessionId: sid,
		from: a,
		to: b,
	})!;

	e.dispatch({ kind: "rename-message", oldId: mid, newId: "ping-1" });

	assert(e.doc.entities?.messages?.["ping-1"] !== undefined);
	// Entity def re-keyed; old id is gone.
	assertEquals(e.doc.entities?.messages?.[mid], undefined);
});

engineTest("update-message swap after rename mutates entity from/to", () => {
	// Regression: the update-message no-op guard previously looked up
	// the message via observation events, but cascadeRewrite leaves
	// observations untouched. After rename, the renamed id wasn't
	// findable that way, so every subsequent update-message silently
	// no-op'd — including direction-swap from the Inspector.
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const b = e.dispatch({
		kind: "add-peer",
		profile: "goblins",
		position: { x: 10, y: 10 },
	})!;
	const sid = e.dispatch({
		kind: "open-session",
		a: attachedEndpoint(a),
		b: attachedEndpoint(b),
	})!;
	const mid = e.dispatch({
		kind: "send-message",
		sessionId: sid,
		from: a,
		to: b,
	})!;

	e.dispatch({ kind: "rename-message", oldId: mid, newId: "ping-1" });
	e.dispatch({
		kind: "update-message",
		messageId: "ping-1",
		patch: { swapDirection: true },
	});

	const def = e.doc.entities?.messages?.["ping-1"];
	assertEquals(def?.from, b);
	assertEquals(def?.to, a);
});

engineTest("rename undo restores everything", () => {
	const e = new Engine(emptyAuthoredDoc());
	const a = e.dispatch({
		kind: "add-peer",
		profile: "pancake",
		position: { x: 0, y: 0 },
	})!;
	const baseline = JSON.stringify({
		entities: e.doc.entities,
		events: primaryObservations(e.doc),
	});

	e.dispatch({ kind: "rename-peer", oldId: a, newId: "alice" });
	assert(e.doc.entities?.peers?.alice !== undefined);

	e.undo();
	assertEquals(
		JSON.stringify({
			entities: e.doc.entities,
			events: primaryObservations(e.doc),
		}),
		baseline,
	);
});
