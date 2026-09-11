import { INTERNAL } from "@glowcap/abi";
import { DriverLoop } from "../driver_loop.ts";
import type { DriverListener } from "../driver_loop.ts";
import { GlowcapError } from "../errors.ts";
import { Host } from "../host.ts";
import { DriverServer } from "../internal/server.ts";
import { assert } from "../../dogfood/assert.ts";

Deno.test("a server retiring a failed loop latches the refusal it does not wait for", async () => {
	// A server requests its owned loop's retirement without waiting for it, so
	// the loop's refusal has no caller. It must land in the Host's callerless
	// journal, not become an unhandled rejection that kills the process.
	const host = new Host();
	const loop = DriverLoop.takeHost(host);
	const failure = new GlowcapError(INTERNAL, "driver loop failed");
	(loop as unknown as { _failBackground(error: unknown): void })._failBackground(failure);
	// A stub listener: admission is already stopped, and only the owned loop's
	// retirement is under test.
	const listener = { host, close: () => Promise.resolve() } as unknown as DriverListener;
	const server = new DriverServer({ listener, ownedLoop: loop });
	await server.close();
	await new Promise((resolve) => setTimeout(resolve, 0));
	const retained = host.takeFailures();
	assert(
		retained.length === 1 && retained[0].operation === "driver-server.loop.retire",
		`the refusal was not latched: ${JSON.stringify(retained.map((f) => f.operation))}`,
	);
	assert(retained[0].primaryMessage === failure.message, "the latched failure is not the loop's");
});
