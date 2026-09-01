// What a durable session remembers about one live room.
//
// A live reader learns a room's standing facts from the line that states them,
// usually the welcome. An attached reader who reloads never sees that line: it
// rebuilds the room from the view projected here. So anything a roster draws
// from those facts has to survive in this state, and the bug that prompted
// these was a bridged room whose foreign members lost their badges on refresh
// while a fresh join kept them.

import { applyRoomView, freshRoomView, projectRoomView } from "../../session/room_view.ts";
import type { Message } from "../../lib/room/message.ts";
import type { RoomFacts } from "../../lib/room/message.ts";
import { assertEquals } from "../assert.ts";

const policy = { visibility: "listed", entry: "open", speaking: "open" } as const;
const fresh = () => freshRoomView("participant", policy);

const bridge = { prefix: "irc/", badge: "IRC", said: "Bridged from libera.", scope: "Libera" };

function line(facts?: RoomFacts): Message {
	return { from: "room", text: "hello", system: false, attachments: [], ...(facts == null ? {} : { facts }) };
}

Deno.test("standing facts a room states survive into the view an attached reader rebuilds from", () => {
	const view = fresh();
	assertEquals(view.bridge, null);
	assertEquals(view.topic, null);

	applyRoomView(view, line({ topic: "Shared work", lineBytes: 4096, bridge }));
	assertEquals(view.bridge, bridge);
	assertEquals(view.topic, "Shared work");
	assertEquals(view.lineBytes, 4096);

	// The projection is what an attached reader actually receives, so the facts
	// have to reach it and not merely be held here.
	const projected = projectRoomView("conv", view);
	assertEquals(projected.bridge, bridge);
	assertEquals(projected.topic, "Shared work");
});

Deno.test("ordinary lines leave the standing facts alone", () => {
	const view = fresh();
	applyRoomView(view, line({ bridge }));
	// Every line after the welcome carries no facts at all, which must not read
	// as the room taking its bridge back.
	applyRoomView(view, line());
	applyRoomView(view, line({ topic: "Later" }));
	assertEquals(view.bridge, bridge);
	assertEquals(view.topic, "Later");
});
