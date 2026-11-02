// World setup for keyframe layout cases, and the engine test wrapper they
// run under (d3-force's lingering timer, see engine-test/harness.ts).

import { World } from "miniplex";
import type { Components, GameWorld, Vec2 } from "../../world.ts";

export { engineTest } from "../../engine-test/harness.ts";

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
