import { assertEquals } from "@std/assert";
import { layerInteractivity } from "./layer-interactivity.ts";
import { ALL_TOOLS } from "./gesture-resolver.ts";

Deno.test("Space held → every layer pointer-transparent", () => {
	for (const tool of ALL_TOOLS) {
		const r = layerInteractivity({ spaceHeld: true, activeTool: tool });
		assertEquals(r, { peers: "none", edges: "none", messages: "none" });
	}
});

Deno.test("Hand tool → all layers off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "hand" }),
		{ peers: "none", edges: "none", messages: "none" },
	);
});

Deno.test("Add Peer → all layers off (clicks land on empty stage)", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "add-peer" }),
		{ peers: "none", edges: "none", messages: "none" },
	);
});

Deno.test("Open Session → peers static, edges/messages off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "open-session" }),
		{ peers: "static", edges: "none", messages: "none" },
	);
});

Deno.test("Send Message → peers static, edges/messages off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "send-message" }),
		{ peers: "static", edges: "none", messages: "none" },
	);
});

Deno.test("Select tool → all layers static", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "select" }),
		{ peers: "static", edges: "static", messages: "static" },
	);
});
