import { invalidateOperations, onOperationsInvalidated } from "../web/ui/ops/invalidation.ts";
import { assertEquals } from "./assert.ts";

Deno.test("operations invalidation refreshes this controller and another tab", async () => {
	let calls = 0;
	const external = new BroadcastChannel("pancake-rooms-operations");
	const remote = Promise.withResolvers<void>();
	const stop = onOperationsInvalidated((scope) => {
		assertEquals(scope, "ocapn://directory.iroh");
		calls += 1;
		if (calls === 2) remote.resolve();
	});
	try {
		await invalidateOperations("ocapn://directory.iroh");
		assertEquals(calls, 1);
		external.postMessage({ source: "another-tab", scope: "ocapn://directory.iroh" });
		await Promise.race([
			remote.promise,
			new Promise<never>((_, reject) =>
				setTimeout(() => reject(new Error("cross-tab invalidation timed out")), 1000)
			),
		]);
		assertEquals(calls, 2);
	} finally {
		stop();
		external.close();
	}
});
