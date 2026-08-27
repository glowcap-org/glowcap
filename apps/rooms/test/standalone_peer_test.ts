import type { Session } from "@pancake/runtime";
import { type ClosingServer, serveStandalone } from "../lib/standalone_peer.ts";
import { assertEquals } from "./assert.ts";

Deno.test("a standalone peer reports both a connection failure and its close consequence", async () => {
	const messages: string[] = [];
	const prior = console.error;
	console.error = (...values: unknown[]) => messages.push(values.map(String).join(" "));
	try {
		const session = {
			serve: () => Promise.reject(new Error("serve broke")),
			close: () => Promise.reject(new Error("close broke")),
		} as unknown as Session;
		const server = {
			close: () => {},
			async *[Symbol.asyncIterator]() {
				yield session;
			},
		} satisfies ClosingServer;
		await serveStandalone(server, "test peer");
		await new Promise((resolve) => setTimeout(resolve, 0));
	} finally {
		console.error = prior;
	}
	assertEquals(messages, [
		"test peer: a peer connection ended unexpectedly: serve broke",
		"test peer: closing that connection also failed: close broke",
	]);
});
