// `zig build bench-rooms-projection` counts visits in the production projection.
// No network, wall-clock claim or test timing threshold is involved.
Object.defineProperty(globalThis, "matchMedia", {
	configurable: true,
	value: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
});
const { initializeApplication } = await import("../../apps/rooms/test/support/application.ts");
await initializeApplication();
const { projectionCost } = await import("../../apps/rooms/test/support/projection_cost.ts");
for (const conversations of [16, 64, 256]) {
	console.log(JSON.stringify(projectionCost(conversations, 64)));
}
