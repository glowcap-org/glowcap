import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 04 — Skip the round-trip (promise pipelining).
 *
 * Email client wants `fetch the message` AND `mark it read` in one
 * round-trip. Two Delivers ship at once: the second targets the
 * promise of the first. The server queues the second on the first
 * answer's row; on resolve, the runtime drains the queue and
 * re-emits the queued call against the resolved reference.
 *
 * On the wire: this one crosses the internet, so it runs over `iroh`
 * and each peer's designator IS its Ed25519 endpoint key. The client's
 * end is its own report; the server's end is attached because the QUIC
 * handshake proved the server holds the key the locator named. That is
 * the strongest attribution the vocabulary has, and it is the
 * difference a keyed netlayer makes.
 * Both peers run pancake, so this session settles on Cap'n Proto over
 * pancake-next. That is the pairing a pancake fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`); the
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/04-skip-the-roundtrip";

export const skipTheRoundtrip = TimelineDocument.parse({
	id: "04-skip-the-roundtrip",
	metadata: {
		"dct:title": "04 · Skip the round-trip",
		"dct:description":
			"The client sends two calls at once: fetch message 314, then mark it read. The second is addressed to the answer of the first, which does not exist yet. The server holds it until the first resolves and then delivers it to whatever came back. One round-trip buys any number of follow-ups.",
		"dct:creator": "pancake project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 3500,
	events: [
		{
			id: "client-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			label: "Email client",
			profile: "pancake",
			designator: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
		},
		{
			id: "server-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			label: "Mail server",
			profile: "pancake",
			designator: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			a: {
				peer: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
				designator: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
				attributedBy: "self-reported",
			},
			b: {
				peer: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
				designator: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
				attributedBy: "authenticated-transport",
			},
			transport: "iroh",
			codec: "capnp",
			captpVersion: "next",
			initialState: "negotiating",
		},
		{
			id: "ss-out",
			t: 200,
			kind: "message-sent",
			messageId: "ss-out",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			to: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
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
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			to: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
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
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			state: "open",
		},
		{
			id: "fetch",
			t: 1100,
			kind: "message-sent",
			messageId: "fetch",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			to: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			arrivalT: 1500,
			label: "op:deliver mailbox.message(314)",
		},
		{
			id: "mark-read",
			t: 1150,
			kind: "message-sent",
			messageId: "mark-read",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			to: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			arrivalT: 1550,
			label: "op:deliver promise(message).mark_read()",
		},
		{
			id: "fetch-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "fetch",
		},
		{
			id: "mark-read-d",
			t: 1550,
			kind: "message-delivered",
			messageId: "mark-read",
		},
		{
			id: "fetch-resolve",
			t: 1900,
			kind: "message-sent",
			messageId: "fetch-resolve",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			to: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			arrivalT: 2300,
			label: "op:resolve fulfill(message)",
		},
		{
			id: "fetch-resolve-d",
			t: 2300,
			kind: "message-delivered",
			messageId: "fetch-resolve",
		},
		{
			id: "drain-fire",
			t: 2400,
			kind: "message-sent",
			messageId: "drain-fire",
			sessionId: "332f4138c6990da916bec312c33424116cb5091816660df8c595e969606d1d73",
			from: "b7e0432fa15c98d6e3170b4a8c2f5d91e6407a3bd58cf12e094a7b3d6f815c2a",
			to: "4f1c9e2a7b3d5086c1a4f7e29b0d6538a2c7e14b90f3d68a5c2b7e04f19d3a6c",
			arrivalT: 2700,
			label: "op:deliver message.mark_read()  (drained)",
		},
		{
			id: "drain-fire-d",
			t: 2700,
			kind: "message-delivered",
			messageId: "drain-fire",
		},
	],
});
