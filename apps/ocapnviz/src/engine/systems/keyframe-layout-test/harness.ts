// Shared Deno.test wrapper and world setup for keyframe layout cases.
//
// d3-force schedules a d3-timer via setTimeout under Deno (no rAF
// in the test env). `simulation.stop()` cancels the timer logically
// but the platform handle lingers past the synchronous test, which
// Deno's resource sanitizer flags as a leak. Harmless in the
// browser; same workaround as engine-test/harness.ts.

import { World } from "miniplex";
import type { Components, GameWorld, Vec2 } from "../../world.ts";

export function layoutTest(name: string, fn: () => void): void {
	Deno.test({
		name,
		sanitizeOps: false,
		sanitizeResources: false,
		fn,
	});
}

export function freshWorld(peerIds: string[]): GameWorld {
	const w = new World<Components>();
	for (const id of peerIds) {
		w.add({
			peer: { id, label: id, profile: "glowcap" },
			position: { x: 0, y: 0 },
		});
	}
	return w;
}

export function dist(a: Vec2, b: Vec2): number {
	return Math.hypot(a.x - b.x, a.y - b.y);
}
