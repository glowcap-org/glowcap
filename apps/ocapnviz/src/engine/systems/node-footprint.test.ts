/**
 * Gathering every node's box from the document, without going through the
 * solver. `separation.test.ts` proves the box matches what is drawn;
 * these prove which label the gatherer measures.
 */

import { assertEquals } from "@std/assert";
import { attachedEndpoint, endpointStageId, unattributedEndpoint } from "../../schema/session-end.ts";
import { peerLabelText } from "../../render/stage-labels.ts";
import { TimelineDocument } from "../timeline.ts";
import { nodeFootprint, nodeFootprints } from "./node-footprint.ts";

Deno.test("a peer is measured by the widest name the document ever gives it", () => {
	const doc = {
		id: "widest",
		duration: 1000,
		entities: {
			peers: {
				alice: {
					profile: "pancake",
					label: "al",
					keyframes: {
						label: [{ t: 10, value: "alice-the-exporter" }],
					},
				},
			},
		},
	} as unknown as TimelineDocument;
	const boxes = nodeFootprints(doc);
	assertEquals(
		boxes.get("alice"),
		nodeFootprint(peerLabelText("alice-the-exporter"), false),
	);
});

Deno.test("an unattributed end is keyed by its stage id", () => {
	const doc = TimelineDocument.parse({
		id: "loose",
		duration: 1000,
		recording: {
			sources: [{
				id: "feed",
				meta: { kind: "fixture" },
				observations: [
					{
						id: "p1",
						t: 0,
						kind: "peer-joined",
						peerId: "rooms",
						profile: "pancake",
					},
					{
						id: "s1",
						t: 0,
						kind: "session-opened",
						sessionId: "s",
						a: attachedEndpoint("rooms"),
						b: unattributedEndpoint("carol"),
						codec: "syrup",
						captpVersion: "v1_0",
						initialState: "open",
					},
				],
			}],
		},
	});
	const boxes = nodeFootprints(doc);
	assertEquals(boxes.has("rooms"), true);
	assertEquals(boxes.has(endpointStageId("s", "b")), true);
	assertEquals(boxes.has(endpointStageId("s", "a")), true);
});
