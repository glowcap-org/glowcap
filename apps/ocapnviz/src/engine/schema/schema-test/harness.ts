/**
 * The document the walk and cascade suites share: two peers, one session
 * between them, one message in flight, and row order and hiding entries.
 */

import { TimelineDocument } from "../../timeline.ts";

export function smallFixture(): TimelineDocument {
	return TimelineDocument.parse({
		id: "doc-1",
		duration: 1000,
		events: [
			{
				id: "e1",
				t: 0,
				kind: "peer-joined",
				peerId: "alice",
				profile: "agent",
			},
			{
				id: "e2",
				t: 0,
				kind: "peer-joined",
				peerId: "bob",
				profile: "agent",
			},
			{
				id: "e3",
				t: 10,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "alice" },
				b: { peer: "bob" },
				codec: "capnp",
				captpVersion: "v1_0",
			},
			{
				id: "e4",
				t: 20,
				kind: "message-sent",
				messageId: "m1",
				sessionId: "s1",
				from: "alice",
				to: "bob",
				arrivalT: 22,
			},
			{ id: "e5", t: 22, kind: "message-delivered", messageId: "m1" },
		],
		rowOrder: { peers: ["alice", "bob"], sessions: ["s1"] },
		rowHidden: { peers: ["alice"] },
	});
}
