import { assert } from "@std/assert";
import { runForce } from "./force-layout.ts";

Deno.test("runForce: a peer whose id starts with an inherited name is placed like any other", () => {
	const layout = runForce(
		["constructor-1", "__proto__-2", "alice"],
		[],
		{
			chargeStrength: -300,
			linkDistance: 100,
			linkStrength: 0.5,
			nodeSpacing: 20,
			iterations: 50,
			centerStrength: 0.1,
		},
		new Map(),
		new Map(),
		new Map(),
	);
	assert(layout.size === 3, "every peer is placed");
	for (const [id, at] of layout) {
		assert(Number.isFinite(at.x) && Number.isFinite(at.y), `${id} has no finite position`);
	}
});
