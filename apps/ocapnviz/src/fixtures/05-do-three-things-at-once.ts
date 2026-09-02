import { TimelineDocument } from "../engine/timeline.ts";
import { payloadOf, wireFrames } from "./wire-frames.ts";

/**
 * Chapter 05 — Do three things at once (multi-hop pipelining).
 *
 * `directory.lookupByName('alice').getCalendar().eventsToday()` —
 * three calls, two of them anchored on a still-unresolved promise.
 * On Cap'n Proto the chain is one frame; on Syrup the runtime
 * decomposes into chained intermediates. The application code is
 * the same on both.
 *
 * On the wire: the client is at `127.0.0.1:9501` and the directory
 * server at `127.0.0.1:9502`, over plain `tcp`. The client's end is
 * its own report; the server's end is attached only because both hosts
 * publish traces of the same OCapN Session ID.
 * Both peers run glowcap, so this session settles on Cap'n Proto over
 * glowcap-next. That is the pairing a glowcap fleet configures
 * (`HostRuntime.Options.codec` / `.captp_version` in `src/driver/host_runtime.zig`); the
 * Syrup / OCapN 1.0 baseline is what a session settles on the moment a peer
 * at either end cannot follow.
 */

const AGENT = "ocapnviz:fixtures/05-do-three-things-at-once";

export const doThreeThingsAtOnce = TimelineDocument.parse({
	id: "05-do-three-things-at-once",
	metadata: {
		"dct:title": "05 · Do three things at once",
		"dct:description":
			"Three calls chained together: look up a name, ask that person for their calendar, ask the calendar for today. Only the first has anything to address yet, and all three ship together anchored on one answer. Cap'n Proto carries the whole chain as a single frame.",
		"dct:creator": "glowcap project",
		"dct:created": "2026-05-14T00:00:00Z",
	},
	provenance: { "prov:wasAttributedTo": AGENT },
	duration: 4000,
	events: [
		{
			id: "client-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9501",
			label: "Calendar app",
			profile: "glowcap",
			designator: "127.0.0.1:9501",
		},
		{
			id: "server-joins",
			t: 0,
			kind: "peer-joined",
			peerId: "127.0.0.1:9502",
			label: "Directory server",
			profile: "glowcap",
			designator: "127.0.0.1:9502",
		},
		{
			id: "session-opens",
			t: 0,
			kind: "session-opened",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			a: {
				peer: "127.0.0.1:9501",
				designator: "127.0.0.1:9501",
				attributedBy: "self-reported",
			},
			b: {
				peer: "127.0.0.1:9502",
				designator: "127.0.0.1:9502",
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
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9501",
			to: "127.0.0.1:9502",
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
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9502",
			to: "127.0.0.1:9501",
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
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			state: "open",
		},
		{
			id: "anchor",
			t: 1100,
			kind: "message-sent",
			messageId: "anchor",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9501",
			to: "127.0.0.1:9502",
			arrivalT: 1500,
			label: "op:deliver lookupByName('alice')",
		},
		{
			id: "chain",
			t: 1150,
			kind: "message-sent",
			messageId: "chain",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9501",
			to: "127.0.0.1:9502",
			arrivalT: 1550,
			label: "op:deliver promise(user)→getCalendar→eventsToday",
		},
		{
			id: "anchor-d",
			t: 1500,
			kind: "message-delivered",
			messageId: "anchor",
		},
		{
			id: "chain-d",
			t: 1550,
			kind: "message-delivered",
			messageId: "chain",
		},
		{
			id: "anchor-resolve",
			t: 1900,
			kind: "message-sent",
			messageId: "anchor-resolve",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9502",
			to: "127.0.0.1:9501",
			arrivalT: 2300,
			label: "op:resolve fulfill(user)",
		},
		{
			id: "anchor-resolve-d",
			t: 2300,
			kind: "message-delivered",
			messageId: "anchor-resolve",
		},
		{
			id: "step-1",
			t: 2400,
			kind: "message-sent",
			messageId: "step-1",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9502",
			to: "127.0.0.1:9501",
			arrivalT: 2700,
			label: "op:deliver user.getCalendar()  (drained)",
		},
		{
			id: "step-1-d",
			t: 2700,
			kind: "message-delivered",
			messageId: "step-1",
		},
		{
			id: "step-2",
			t: 2900,
			kind: "message-sent",
			messageId: "step-2",
			sessionId: "8e3abae6a7d41db2323b0ed15305c09903ae6b9676c850b2f01ae28e72bf0d6b",
			from: "127.0.0.1:9502",
			to: "127.0.0.1:9501",
			arrivalT: 3200,
			label: "op:deliver calendar.eventsToday()  (drained)",
		},
		{
			id: "step-2-d",
			t: 3200,
			kind: "message-delivered",
			messageId: "step-2",
		},
	],
});
