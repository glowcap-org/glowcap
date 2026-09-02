/**
 * Pin writes are document mutations. The engine's same-frame refresh
 * is a separate subject, proven in `engine-test/placement.test.ts`.
 */

import { assertEquals } from "@std/assert";
import { endpointStageId } from "../../schema/session-end.ts";
import { observationsOf } from "../temporal/recording-access.ts";
import { TimelineDocument, type TimelineEvent } from "../timeline.ts";
import {
	clearEndpointPositionOnDoc,
	clearPeerPositionOnDoc,
	writeEndpointPosition,
	writePeerPosition,
} from "./placement.ts";

function pinDoc(): TimelineDocument {
	return TimelineDocument.parse({
		id: "pin-writes",
		duration: 1000,
		entities: {
			peers: { a: { profile: "glowcap" } },
			sessions: {
				s1: {
					a: { peer: "a" },
					b: { designator: "127.0.0.1:9000" },
					codec: "syrup",
					captpVersion: "v1_0",
					initialState: "open",
				},
			},
		},
		events: [
			{
				id: "p1",
				t: 0,
				kind: "peer-joined",
				peerId: "a",
				profile: "glowcap",
			},
			{
				id: "so",
				t: 0,
				kind: "session-opened",
				sessionId: "s1",
				a: { peer: "a" },
				b: { designator: "127.0.0.1:9000" },
				codec: "syrup",
				captpVersion: "v1_0",
				initialState: "open",
			},
		],
	});
}

function joinedPosition(doc: TimelineDocument, peerId: string) {
	for (const ev of observationsOf(doc) as TimelineEvent[]) {
		if (ev.kind === "peer-joined" && ev.peerId === peerId) {
			return ev.position;
		}
	}
	return undefined;
}

Deno.test("writePeerPosition pins the entity and the join event together", () => {
	const doc = pinDoc();
	writePeerPosition(doc, "a", { x: 40, y: 80 });
	assertEquals(doc.entities?.peers?.a?.position, { x: 40, y: 80 });
	assertEquals(joinedPosition(doc, "a"), { x: 40, y: 80 });
});

Deno.test("clearPeerPositionOnDoc drops both pin sites", () => {
	const doc = pinDoc();
	writePeerPosition(doc, "a", { x: 1, y: 2 });
	clearPeerPositionOnDoc(doc, "a");
	assertEquals(doc.entities?.peers?.a?.position, undefined);
	assertEquals(joinedPosition(doc, "a"), undefined);
});

Deno.test("writeEndpointPosition pins the session end the id names", () => {
	const doc = pinDoc();
	const end = endpointStageId("s1", "b");
	writeEndpointPosition(doc, end, { x: 9, y: 11 });
	assertEquals(doc.entities?.sessions?.s1?.endpointPosition?.b, {
		x: 9,
		y: 11,
	});
});

Deno.test("clearEndpointPositionOnDoc drops only that side's pin", () => {
	const doc = pinDoc();
	writeEndpointPosition(doc, endpointStageId("s1", "a"), { x: 1, y: 1 });
	writeEndpointPosition(doc, endpointStageId("s1", "b"), { x: 2, y: 2 });
	assertEquals(
		clearEndpointPositionOnDoc(doc, endpointStageId("s1", "b")),
		true,
	);
	assertEquals(doc.entities?.sessions?.s1?.endpointPosition?.a, {
		x: 1,
		y: 1,
	});
	assertEquals(doc.entities?.sessions?.s1?.endpointPosition?.b, undefined);
});

Deno.test("an unknown endpoint id is a no-op", () => {
	const doc = pinDoc();
	writeEndpointPosition(doc, "not-an-end", { x: 1, y: 1 });
	assertEquals(doc.entities?.sessions?.s1?.endpointPosition, undefined);
	assertEquals(clearEndpointPositionOnDoc(doc, "s1::z"), false);
});
