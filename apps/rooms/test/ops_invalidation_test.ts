/// <reference lib="dom" />

Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});

const { invalidateOperations, onOperationsInvalidated } = await import("../web/ui/ops/invalidation.ts");
const { RoomsPage } = await import("../web/ui/page.ts");
const { assertEquals } = await import("./assert.ts");

Deno.test("operations invalidation refreshes this controller and another tab", async () => {
	const page = new RoomsPage();
	let calls = 0;
	const external = new BroadcastChannel("glowcap-rooms-operations");
	const remote = Promise.withResolvers<void>();
	const stop = onOperationsInvalidated(page, (scope) => {
		assertEquals(scope, "ocapn://directory.iroh");
		calls += 1;
		if (calls === 2) remote.resolve();
	});
	try {
		await invalidateOperations(page, "ocapn://directory.iroh");
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
