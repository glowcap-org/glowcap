import { ALL_TOOLS } from "./gesture-resolver-test/harness.ts";
import { assertEquals } from "@std/assert";
import { layerInteractivity } from "./layer-interactivity.ts";

Deno.test("holding space makes every layer pointer-transparent", () => {
	for (const tool of ALL_TOOLS) {
		const r = layerInteractivity({ spaceHeld: true, activeTool: tool });
		assertEquals(r, { peers: "none", edges: "none", messages: "none" });
	}
});

Deno.test("the Hand tool turns all layers off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "hand" }),
		{ peers: "none", edges: "none", messages: "none" },
	);
});

Deno.test("Add Peer turns all layers off so clicks land on the empty stage", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "add-peer" }),
		{ peers: "none", edges: "none", messages: "none" },
	);
});

Deno.test("Open Session keeps peers static and turns edges and messages off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "open-session" }),
		{ peers: "static", edges: "none", messages: "none" },
	);
});

Deno.test("Send Message keeps peers static and turns edges and messages off", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "send-message" }),
		{ peers: "static", edges: "none", messages: "none" },
	);
});

Deno.test("the Select tool makes all layers static", () => {
	assertEquals(
		layerInteractivity({ spaceHeld: false, activeTool: "select" }),
		{ peers: "static", edges: "static", messages: "static" },
	);
});
