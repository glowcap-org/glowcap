import { TimelineDocument } from "../engine/timeline.ts";
import { endpointStageId } from "../schema/session-end.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 07 — Speak Goblins (OCapN 1.0).
 *
 * The same call-and-answer pattern as chapter 01, but on the OCapN 1.0
 * baseline, where a resolution is not an `op:resolve` at all: the runtime
 * turns the application's answer into an `op:deliver` addressed to the
 * resolver callback the caller stashed. The application code is one
 * argument different and the wire bytes differ from byte one.
 *
 * On the wire: Alice is at `127.0.0.1:9701` and Bob at
 * `127.0.0.1:9702`, over plain `tcp`. Bob does not publish a trace —
 * Goblins has no tap this viewer reads — so nothing correlates his
 * end. Plain TCP proves nothing about the designator in his hello, so
 * that far end remains a loose claim.
 * Bob is a Goblins vat, and Goblins states no profile in its hello, so both
 * axes settle back to the baseline: Syrup over OCapN 1.0.
 */

const AGENT = "ocapnviz:fixtures/07-speak-goblins";

/** The OCapN Session ID this recording carries, 64 lowercase hex digits the
 *  way a real one is. Named rather than written at each use because it is now
 *  read twice over: once as the session's own id, and again through
 *  `endpointStageId` for the far end nothing has attributed. A second copy of
 *  it silently detaches those messages from their session. */
const SESSION_ID = "28b3b6d21bd71a8329bf2d8dc419f3e4afecca921cc10c3beff7780d9ce2e94a";

export const speakGoblins = TimelineDocument.parse({
	id: "07-speak-goblins",
	metadata: {
		"dct:title": "07 · Speak Goblins (OCapN 1.0)",
		"dct:description":
			"A pancake peer talks to a Spritely Goblins peer, so the session settles on the OCapN 1.0 baseline in Syrup. The application still just resolves an answer. The runtime turns that into the op:deliver to a resolver callback that Goblins expects, so one line differs at the call site and every byte differs on the wire.",
		"dct:creator": "pancake project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 3500,
	events: [
		{
			id: "alice-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9701",
			label: "Alice (pancake)",
			profile: "pancake",
			designator: "127.0.0.1:9701",
		},
		{
			id: "bob-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9702",
			label: "Bob (Goblins)",
			profile: "goblins",
			designator: "127.0.0.1:9702",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: SESSION_ID,
			a: {
				peer: "127.0.0.1:9701",
				designator: "127.0.0.1:9701",
				attributedBy: "self-reported",
			},
			b: {
				designator: "127.0.0.1:9702",
			},
			transport: "tcp",
			codec: "syrup",
			captpVersion: "v1_0",
			initialState: "negotiating",
		},
		{
			id: "ss-out",
			t: 200,
			kind: "message-sent",
			messageId: "ss-out",
			sessionId: SESSION_ID,
			from: "127.0.0.1:9701",
			to: endpointStageId(SESSION_ID, "b"),
			arrivalT: 400,
			label: "op:start-session",
			...payloadOf(wireFrames.startSession, AGENT),
		},
		{
			id: "ss-out-d",
			t: 400,
			kind: "message-delivered",
			messageId: "ss-out",
		},
		{
			id: "ss-back",
			t: 500,
			kind: "message-sent",
			messageId: "ss-back",
			sessionId: SESSION_ID,
			from: endpointStageId(SESSION_ID, "b"),
			to: "127.0.0.1:9701",
			arrivalT: 700,
			label: "op:start-session",
			...payloadOf(wireFrames.startSession, AGENT),
		},
		{
			id: "ss-back-d",
			t: 700,
			kind: "message-delivered",
			messageId: "ss-back",
		},
		{
			id: "session-open",
			t: 700,
			kind: "session-state-changed",
			sessionId: SESSION_ID,
			state: "open",
		},
		{
			id: "deliver",
			t: 1100,
			kind: "message-sent",
			messageId: "deliver",
			sessionId: SESSION_ID,
			from: "127.0.0.1:9701",
			to: endpointStageId(SESSION_ID, "b"),
			arrivalT: 1500,
			label: "op:deliver  (with synthesized resolve_me_desc)",
			...payloadOf(wireFrames.deliverWithResolveMeDesc, AGENT),
		},
		{
			id: "deliver-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "deliver",
		},
		{
			id: "callback",
			t: 1900,
			kind: "message-sent",
			messageId: "callback",
			sessionId: SESSION_ID,
			from: endpointStageId(SESSION_ID, "b"),
			to: "127.0.0.1:9701",
			arrivalT: 2300,
			label: "op:deliver to resolver-callback  (== Resolve)",
		},
		{
			id: "callback-d",
			t: 2300,
			kind: "message-delivered",
			messageId: "callback",
		},
	],
});
