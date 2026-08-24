import { assertEquals } from "@std/assert";
import type { Hit, SurfaceGestureCtx } from "../../interactions/types.ts";
import { resolveTimelineGesture } from "./timeline-gesture.ts";

const SELECT: SurfaceGestureCtx = {
	activeTool: "select",
	spaceHeld: false,
	modifiers: { shift: false, cmd: false, alt: false },
};

const MUTATING_HITS: readonly Hit[] = [
	{ surface: "timeline-gutter-edge" },
	{ surface: "timeline-gutter-chevron", category: "peers" },
	{
		surface: "timeline-gutter-eyeball",
		scope: { kind: "row", category: "peers", entityId: "alice" },
	},
	{
		surface: "timeline-lane-event-edge",
		eventId: "left",
		entityRef: { kind: "peer", id: "alice" },
	},
];

Deno.test("Hand and Space turn every Timeline mutation target into a pan", () => {
	for (const hit of MUTATING_HITS) {
		const hand = resolveTimelineGesture(hit, {
			...SELECT,
			activeTool: "hand",
		});
		assertEquals(hand?.tier, "hand-tool", hit.surface);
		const space = resolveTimelineGesture(hit, {
			...SELECT,
			spaceHeld: true,
		});
		assertEquals(space?.tier, "space-pan", hit.surface);
	}
	assertEquals(
		resolveTimelineGesture(null, { ...SELECT, activeTool: "hand" })?.tier,
		"hand-tool",
	);
});

Deno.test("Option pans empty lanes but never steals a pill or Shift+Option marquee", () => {
	const empty: Hit = { surface: "timeline-lane-empty", t: 50 };
	const option = resolveTimelineGesture(empty, {
		...SELECT,
		modifiers: { shift: false, cmd: false, alt: true },
	});
	assertEquals(
		option?.tier === "default" ? option.verb.kind : null,
		"pan-view",
	);

	const remove = resolveTimelineGesture(empty, {
		...SELECT,
		modifiers: { shift: true, cmd: false, alt: true },
	});
	assertEquals(
		remove?.tier === "default" ? remove.verb.kind : null,
		"rubber-band",
	);

	const pill = resolveTimelineGesture({
		surface: "timeline-lane-event",
		eventId: "joined",
		entityRef: { kind: "peer", id: "alice" },
	}, {
		...SELECT,
		modifiers: { shift: false, cmd: false, alt: true },
	});
	assertEquals(
		pill?.tier === "default" ? pill.verb.kind : null,
		"select-or-drag-event",
	);
});
