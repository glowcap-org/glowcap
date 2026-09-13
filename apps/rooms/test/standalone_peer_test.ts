// Standalone peer shutdown preserves the primary connection outcome together with any cleanup failure.
import { GlowcapError, type Session } from "@glowcap/runtime";
import { IO } from "@glowcap/abi";
import { type ClosingServer, serveStandalone } from "./support/standalone_server.ts";
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

Deno.test("a standalone peer treats connection loss as departure but still reports cleanup failure", async () => {
	const messages: string[] = [];
	const prior = console.error;
	console.error = (...values: unknown[]) => messages.push(values.map(String).join(" "));
	try {
		const session = {
			serve: () => Promise.reject(new GlowcapError(IO, "session failed: ConnectionLost")),
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
	assertEquals(messages, ["test peer: closing that connection also failed: close broke"]);
});
