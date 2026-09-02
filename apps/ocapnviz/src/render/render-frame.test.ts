/**
 * The scene graph holds sprites for what this frame drew, and nothing else.
 *
 * The sprite maps are the one thing in the renderer that outlives a frame.
 * The world is reconciled or rebuilt every tick, but a Pixi display object
 * is created once and destroyed once, so a sprite whose creation and whose
 * destruction answer to two different questions is a picture that keeps
 * something the world no longer holds — the same shape as a reconciler
 * adding on one test and removing on another, wearing a GPU resource.
 *
 * Validated by breaking the code it covers: marking a session live before
 * its curve resolves (which is what the sweep reads) leaves the previous
 * frame's edge on the stage, and the case below turns red.
 */

import { assert, assertEquals } from "@std/assert";
import { Container } from "pixi.js";
import { Engine } from "../engine/engine.ts";
import type { TimelineDocument } from "../engine/timeline.ts";
import { attachedEndpoint } from "../schema/session-end.ts";
import { installHeadlessCanvas } from "./headless-canvas.fixture.ts";
import { themedColors } from "./palette.ts";
import { EdgeStrokeBatch } from "./edge-stroke-batch.ts";
import { renderFrame } from "./render-frame.ts";
import type { EdgeSprite, EndpointSprite, MessageSprite, PeerSprite } from "./sprites/types.ts";
import type { PeerActivity } from "./types.ts";

installHeadlessCanvas();

/** Everything `renderFrame` writes into, held across frames the way the Stage
 *  holds it, plus the per-frame scratch it clears itself. */
function scene() {
	const peerSprites = new Map<string, PeerSprite>();
	const endpointSprites = new Map<string, EndpointSprite>();
	const edgeSprites = new Map<string, EdgeSprite>();
	const messageSprites = new Map<string, MessageSprite>();
	const edgeStrokeBatch = new EdgeStrokeBatch();
	const edgeLayer = new Container();
	edgeLayer.addChild(edgeStrokeBatch.gfx);
	const layers = {
		edgeLayer,
		peerLayer: new Container(),
		messageLayer: new Container(),
		peerLabelLayer: new Container(),
		sessionLabelLayer: new Container(),
		messageLabelLayer: new Container(),
	};
	const scratch = {
		scratchActivity: new Map<string, PeerActivity>(),
		scratchPeerIds: new Set<string>(),
		scratchEndpointIds: new Set<string>(),
		scratchSessionIds: new Set<string>(),
		scratchMessageIds: new Set<string>(),
	};
	return {
		peerSprites,
		endpointSprites,
		edgeSprites,
		messageSprites,
		edgeStrokeBatch,
		/** `scale` is the camera's, which the selection marks divide by. */
		paint(
			engine: Engine,
			scale = 1,
			selection: ReadonlySet<string> = new Set(),
		): void {
			renderFrame({
				engine,
				...layers,
				peerSprites,
				endpointSprites,
				edgeSprites,
				edgeStrokeBatch,
				messageSprites,
				onSelect: undefined,
				selection: selection as ReadonlySet<never>,
				anchor: null,
				previewSelection: new Set(),
				hover: null,
				enterHover: () => {},
				leaveHover: () => {},
				colors: themedColors("dark"),
				counterScale: 1 / scale,
				scale,
				startNodeDrag: () => {},
				claimsToward: engine.frameGeometry.claimsToward,
				sessionCurves: engine.frameGeometry.sessionCurves,
				...scratch,
			});
		},
		dispose(): void {
			edgeStrokeBatch.destroy();
			for (const layer of Object.values(layers)) {
				layer.destroy({ children: true });
			}
		},
	};
}

/**
 * A session whose `b` end changes hands, to a peer that then departs.
 *
 * The end was occupied throughout, so the session runs on; but from t=300 it
 * names `bob`, and `bob` is gone. There is no line to draw between a node and
 * nobody, and the frame has to stop drawing one.
 */
function endChangesHands(): TimelineDocument {
	return {
		id: "hands",
		metadata: { "dct:title": "an end that changed hands" },
		duration: 1000,
		recording: {
			sources: [{
				id: "live",
				meta: { kind: "glowcap-host" },
				observations: [
					{ id: "j1", t: 0, kind: "peer-joined", peerId: "rooms" },
					{ id: "j2", t: 0, kind: "peer-joined", peerId: "carol" },
					{ id: "j3", t: 0, kind: "peer-joined", peerId: "bob" },
					{
						id: "o1",
						t: 0,
						kind: "session-opened",
						sessionId: "s1",
						a: attachedEndpoint("rooms"),
						b: attachedEndpoint("carol"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
					{
						id: "a1",
						t: 100,
						kind: "session-endpoint-attributed",
						sessionId: "s1",
						side: "b",
						peerId: "bob",
						attributedBy: "verified-handoff",
					},
					{ id: "l1", t: 300, kind: "peer-left", peerId: "bob" },
				],
			}],
		},
	} as unknown as TimelineDocument;
}

Deno.test("an edge with nowhere to be drawn leaves no sprite behind", () => {
	const engine = new Engine(endChangesHands());
	const stage = scene();

	engine.seekTo(200);
	stage.paint(engine);
	assert(
		stage.edgeSprites.has("s1"),
		"the session was drawn while both its ends were on stage",
	);

	// Same session, still alive, but its `b` end now names a peer that left.
	engine.seekTo(500);
	assertEquals(
		[...engine.queries.sessions].map((e) => e.session.id),
		["s1"],
		"the session is still standing, which is what makes this the hard case",
	);
	stage.paint(engine);
	assertEquals(
		[...stage.edgeSprites.keys()],
		[],
		"the edge kept the geometry of a frame whose far end has since gone",
	);

	stage.dispose();
});

Deno.test("sprites follow the world through a session opening and closing", () => {
	// The ordinary reconciliation, so the sweep above is not the only thing
	// holding the maps: every kind of sprite arrives with its entity and goes
	// with it.
	const engine = new Engine(endChangesHands());
	const stage = scene();

	engine.seekTo(50);
	stage.paint(engine);
	assertEquals([...stage.peerSprites.keys()].sort(), [
		"bob",
		"carol",
		"rooms",
	]);
	assertEquals([...stage.edgeSprites.keys()], ["s1"]);

	engine.seekTo(500);
	stage.paint(engine);
	assertEquals(
		[...stage.peerSprites.keys()].sort(),
		["carol", "rooms"],
		"a peer that departed kept its sprite",
	);

	stage.dispose();
});

/** A peer, a loose end, the wire between them, and a message in flight — one of
 *  every stage entity that wears a selection mark. */
function oneOfEach(): TimelineDocument {
	return {
		id: "marks",
		metadata: { "dct:title": "one of every markable entity" },
		duration: 1000,
		recording: {
			sources: [{
				id: "live",
				meta: { kind: "glowcap-host" },
				observations: [
					{ id: "j1", t: 0, kind: "peer-joined", peerId: "rooms" },
					{
						id: "o1",
						t: 0,
						kind: "session-opened",
						sessionId: "s1",
						a: attachedEndpoint("rooms"),
						b: { designator: "carol" },
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
					{
						id: "m1",
						t: 10,
						kind: "message-sent",
						messageId: "m1",
						sessionId: "s1",
						direction: "a-to-b",
						op: "op:deliver-only",
					},
				],
			}],
		},
	} as TimelineDocument;
}

Deno.test("a zoom repaints every selection mark", () => {
	// The compensation is inert without this. A stage's world geometry does not
	// change when the camera zooms — a peer sits where it sits, a curve keeps its
	// control points — so every other input to a sprite's repaint gate is
	// unchanged, and a mark whose geometry now depends on the zoom would keep the
	// world units it was given at the old one. The mark would go on scaling with
	// the camera, which is the whole defect, with the arithmetic to fix it already
	// in place and never re-run.
	//
	// Read off the drawn graphics rather than the bookkeeping, so it is the
	// picture being checked and not the flag.
	const s = scene();
	try {
		const engine = new Engine(oneOfEach());
		engine.seekTo(15);
		const selection = new Set([
			"peer:rooms",
			"endpoint:s1::b",
			"session:s1",
			"message:m1",
		]);
		s.paint(engine, 1, selection);
		const marks = () => [
			...[...s.peerSprites.values()].map((x) => x.haloGfx),
			...[...s.endpointSprites.values()].map((x) => x.haloGfx),
			...[...s.edgeSprites.values()].map((x) => x.haloGfx),
			...[...s.messageSprites.values()].map((x) => x.haloGfx),
		];
		const drawn = marks();
		assertEquals(drawn.length, 4, "one mark per markable entity");
		const atFull = drawn.map((g) => g.getLocalBounds().width);
		for (const [i, w] of atFull.entries()) {
			assert(w > 0, `mark ${i} drew nothing to compare`);
		}

		s.paint(engine, 0.1, selection);
		const atTenth = marks().map((g) => g.getLocalBounds().width);
		for (const [i, w] of atTenth.entries()) {
			// Grew, and that is the whole assertion: a mark that was not repainted is
			// EXACTLY the size it was, so any change separates the two cases. Not a
			// ratio, because these bounds also contain the body the mark rings, and
			// the body is a world thing that does not scale — a peer's ring grows by
			// less than half again while a message's grows nearly fivefold, and
			// pinning either number here would be pinning the body's size.
			assert(
				w > atFull[i]! + 1,
				`mark ${i} kept its world size across a zoom (${atFull[i]!.toFixed(1)} then ${
					w.toFixed(1)
				}), so it was never repainted and still shrinks ` +
					`with the camera`,
			);
		}
	} finally {
		s.dispose();
	}
});

Deno.test("a mark that goes away is cleared, and an absent one is not repainted", () => {
	// The repaint gate reads the camera, so an unmarked stage used to clear an
	// empty Graphics per sprite on every frame of every zoom to draw nothing into
	// it. The gate now asks whether there is a mark — but it has to ask about the
	// PREVIOUS frame too, or the frame that takes a mark away is skipped and the
	// ring stays on screen after the selection is gone. That second half is what
	// this covers, because it is the one a cheaper guard gets wrong.
	//
	// Validated by injection: a guard that reads the previous frame but requires
	// BOTH of its conditions leaves the ring up, and the last case below turns
	// red. Dropping the previous frame's terms outright does not compile, because
	// the parameters go unread, so it proves nothing and is not the check.
	const s = scene();
	try {
		const engine = new Engine(oneOfEach());
		engine.seekTo(15);
		const marks = () => [
			...[...s.peerSprites.values()].map((x) => x.haloGfx),
			...[...s.endpointSprites.values()].map((x) => x.haloGfx),
			...[...s.edgeSprites.values()].map((x) => x.haloGfx),
			...[...s.messageSprites.values()].map((x) => x.haloGfx),
		];

		// Nothing picked: every mark is empty, and a zoom leaves them that way.
		s.paint(engine, 1, new Set());
		for (const [i, g] of marks().entries()) {
			assertEquals(
				g.getLocalBounds().width,
				0,
				`mark ${i} drew unpicked`,
			);
		}
		s.paint(engine, 0.1, new Set());
		for (const [i, g] of marks().entries()) {
			assertEquals(
				g.getLocalBounds().width,
				0,
				`mark ${i} drew on a zoom`,
			);
		}

		// Picked, then let go at the same zoom: the ring must not survive.
		const selection = new Set([
			"peer:rooms",
			"endpoint:s1::b",
			"session:s1",
			"message:m1",
		]);
		s.paint(engine, 0.1, selection);
		for (const [i, g] of marks().entries()) {
			assert(g.getLocalBounds().width > 0, `mark ${i} never appeared`);
		}
		s.paint(engine, 0.1, new Set());
		for (const [i, g] of marks().entries()) {
			assertEquals(
				g.getLocalBounds().width,
				0,
				`mark ${i} stayed on screen after its selection went away`,
			);
		}
	} finally {
		s.dispose();
	}
});

Deno.test(
	`"body" vis mode clears stroked geometry and unhide restores it`,
	() => {
		// Invisible = no retained tessellated buffers. Mode `"body"` keeps the
		// label and drops the mark; sync* must clear Graphics and invalidate
		// dirty keys so the next visible frame cannot early-out on a stale
		// stroke. Validated by injection: skipping the clear leaves bounds
		// warm, and skipping the invalidate leaves the body empty after unhide.
		const s = scene();
		try {
			const engine = new Engine(oneOfEach());
			engine.seekTo(15);
			s.paint(engine);

			const peer = s.peerSprites.get("rooms");
			const end = s.endpointSprites.get("s1::b");
			const edge = s.edgeSprites.get("s1");
			const message = s.messageSprites.get("m1");
			assert(
				peer && end && edge && message,
				"expected one of each sprite",
			);

			assert(peer.bodyGfx.getLocalBounds().width > 0, "peer body drew");
			assert(end.bodyGfx.getLocalBounds().width > 0, "end body drew");
			assert(
				s.edgeStrokeBatch.gfx.getLocalBounds().width > 0,
				"edge stroked",
			);
			assert(
				message.body.getLocalBounds().width > 0,
				"message body drew",
			);
			const hit = edge.hitArea.hitArea;
			assert(
				hit != null &&
					typeof (hit as { contains?: unknown }).contains ===
						"function",
				"edge has a curve hit proxy",
			);
			const curve = engine.frameGeometry.sessionCurves.get("s1");
			assert(curve, "session curve for hit check");
			assert(
				(hit as { contains: (x: number, y: number) => boolean })
					.contains(
						(curve.ax + curve.bx) / 2,
						(curve.ay + curve.by) / 2,
					),
				"mid-chord is pickable",
			);
			assert(
				edge.hitArea.boundsArea != null &&
					edge.hitArea.boundsArea.width > 0,
				"cull bounds cover the wire, not the empty origin",
			);

			engine.setRowVisMode("peers", "rooms", "body");
			engine.setRowVisMode("sessions", "s1", "body");
			engine.setRowVisMode("messages", "m1", "body");
			s.paint(engine);

			assertEquals(
				peer.bodyGfx.getLocalBounds().width,
				0,
				"peer body cleared",
			);
			assertEquals(
				peer.haloGfx.getLocalBounds().width,
				0,
				"peer halo cleared",
			);
			assertEquals(peer.lastColor, -1, "peer body dirty-key invalidated");
			assertEquals(
				end.bodyGfx.getLocalBounds().width,
				0,
				"end body cleared",
			);
			assertEquals(
				s.edgeStrokeBatch.gfx.getLocalBounds().width,
				0,
				"edge line cleared",
			);
			assert(
				Number.isNaN(edge.lastAx),
				"edge curve dirty-key invalidated",
			);
			assertEquals(
				message.body.getLocalBounds().width,
				0,
				"message body cleared",
			);
			assert(
				message.lastBodyCleared,
				"message body-clear flag set for unhide",
			);
			// Labels stay: that is what `"body"` mode means.
			assert(peer.label.visible, "peer label kept");
			assert(edge.label.visible, "edge label kept");
			assert(message.label.visible, "message label kept");

			engine.setRowVisMode("peers", "rooms", "visible");
			engine.setRowVisMode("sessions", "s1", "visible");
			engine.setRowVisMode("messages", "m1", "visible");
			s.paint(engine);

			assert(
				peer.bodyGfx.getLocalBounds().width > 0,
				"peer body restored",
			);
			assert(end.bodyGfx.getLocalBounds().width > 0, "end body restored");
			assert(
				s.edgeStrokeBatch.gfx.getLocalBounds().width > 0,
				"edge stroke restored",
			);
			assert(
				message.body.getLocalBounds().width > 0,
				"message body restored",
			);
			assertEquals(
				message.lastBodyCleared,
				false,
				"message body-clear flag consumed",
			);
		} finally {
			s.dispose();
		}
	},
);
