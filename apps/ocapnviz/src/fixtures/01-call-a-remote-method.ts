import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 01, Call a remote method.
 *
 * The phone calls `speaker.queue("Hot Knife")` on the kitchen speaker.
 * Speaker fulfills with a print-job-receipt-style export. Phone
 * tidies up with `op:gc-exports`. The simplest end-to-end CapTP call.
 *
 * On the wire: the phone is at `127.0.0.1:9101` and the speaker at
 * `127.0.0.1:9102`, over plain `tcp`. Each end of the session says who
 * it claims to be, and what backed the claim. The phone's own end is
 * its own report. Nothing on a cleartext `tcp` connection proves the
 * speaker's name, so the only thing that attaches that end is the
 * speaker publishing its own trace of the same session: two hosts
 * agreeing on one OCapN Session ID, which is the weakest attribution
 * the vocabulary has and the picture says so.
 * Both peers run glowcap, so this session settles on Cap'n Proto over
 * glowcap-next. That is the pairing a glowcap fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`). The
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/01-call-a-remote-method";

export const callARemoteMethod = TimelineDocument.parse({
	id: "01-call-a-remote-method",
	metadata: {
		"dct:title": "01 · Call a remote method",
		"dct:description":
			'A phone calls queue("Hot Knife") on a kitchen speaker, and the speaker answers. The phone then drops the reference it no longer needs. This is the whole shape of a CapTP call, and every program eventually makes it: op:deliver out, op:resolve back, op:gc-exports to tidy up.',
		"dct:creator": "glowcap project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 3500,
	events: [
		{
			id: "phone-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9101",
			label: "Phone",
			profile: "glowcap",
			designator: "127.0.0.1:9101",
		},
		{
			id: "speaker-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9102",
			label: "Speaker",
			profile: "glowcap",
			designator: "127.0.0.1:9102",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			a: {
				peer: "127.0.0.1:9101",
				designator: "127.0.0.1:9101",
				attributedBy: "self-reported",
			},
			b: {
				peer: "127.0.0.1:9102",
				designator: "127.0.0.1:9102",
				attributedBy: "viewer-correlated",
			},
			transport: "tcp",
			codec: "capnp",
			captpVersion: "next",
			initialState: "negotiating",
		},
		{
			id: "ss-out",
			t: 200,
			kind: "message-sent",
			messageId: "ss-out",
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			from: "127.0.0.1:9101",
			to: "127.0.0.1:9102",
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
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			from: "127.0.0.1:9102",
			to: "127.0.0.1:9101",
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
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			state: "open",
		},
		{
			id: "queue-call",
			t: 1100,
			kind: "message-sent",
			messageId: "queue-call",
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			from: "127.0.0.1:9101",
			to: "127.0.0.1:9102",
			arrivalT: 1500,
			label: "op:deliver queue('Hot Knife')",
		},
		{
			id: "queue-call-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "queue-call",
		},
		{
			id: "queue-resolve",
			t: 1800,
			kind: "message-sent",
			messageId: "queue-resolve",
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			from: "127.0.0.1:9102",
			to: "127.0.0.1:9101",
			arrivalT: 2200,
			label: "op:resolve fulfill(receipt)",
		},
		{
			id: "queue-resolve-d",
			t: 2200,
			kind: "message-delivered",
			messageId: "queue-resolve",
		},
		{
			id: "gc",
			t: 2600,
			kind: "message-sent",
			messageId: "gc",
			sessionId: "29317f81838957330cc843e1d9e4e7aae8052269296cff70b818e95d6ca9ba54",
			from: "127.0.0.1:9101",
			to: "127.0.0.1:9102",
			arrivalT: 2900,
			label: "op:gc-exports",
			...payloadOf(wireFrames.gcExportsCapnp, AGENT),
		},
		{
			id: "gc-d",
			t: 2900,
			kind: "message-delivered",
			messageId: "gc",
		},
	],
});
