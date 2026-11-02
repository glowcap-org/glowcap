/**
 * The hit-test result a surface reports (§ 2.3 of `docs/interaction-model.md`),
 * and the Stage's own family of surfaces.
 */

import type { EntityRef } from "./entity-ref.ts";

export type LaneCategory = "peers" | "sessions" | "messages";

export type Hit =
	| { surface: "stage-empty" }
	| { surface: "stage-peer"; peerId: string }
	| { surface: "stage-endpoint"; endpointId: string }
	| { surface: "stage-edge"; sessionId: string }
	| { surface: "stage-message"; messageId: string }
	| { surface: "timeline-overview"; t: number }
	/** A grip on one end of the overview's visible-window rect. Its own
	 *  surface, not a flag on `timeline-overview`, for the same reason a lane
	 *  event edge is its own: the resolver branches on `surface`. */
	| { surface: "timeline-overview-edge"; edge: "start" | "end"; t: number }
	| { surface: "timeline-ruler"; t: number }
	| { surface: "timeline-lane-empty"; t: number }
	| {
		surface: "timeline-lane-event";
		/** The observation event the pill paints, or null when the pill is the
		 *  entity's own span and no observation names it. An authored peer or
		 *  session is the second case: the engine retimes it by entity rather
		 *  than by event, and the pointer picks it exactly the same way. */
		eventId: string | null;
		entityRef: EntityRef;
	}
	| {
		surface: "timeline-lane-event-edge";
		eventId: string | null;
		entityRef: EntityRef;
	}
	/** The draggable seam between the row gutter and the plot area. Its own
	 *  surface because the drag it starts resizes the gutter and nothing else,
	 *  and it takes precedence over whatever row it crosses. */
	| { surface: "timeline-gutter-edge" }
	| { surface: "timeline-gutter-chevron"; category: LaneCategory }
	| { surface: "timeline-gutter-eyeball"; scope: VisibilityScope }
	| {
		surface: "timeline-gutter-label";
		category: LaneCategory;
		entityId: string;
	};

/**
 * The rows a gutter eyeball governs.
 *
 * A row's own eyeball, a category header's, and the overview's all-rows
 * eyeball are one control repeated down one column, so they are one surface
 * and this is the part of the picture a click acts on.
 */
export type VisibilityScope =
	| { kind: "row"; category: LaneCategory; entityId: string }
	| { kind: "category"; category: LaneCategory }
	| { kind: "all" };

export type SurfaceId = Hit["surface"];

/**
 * The Stage's own surfaces, which are the surfaces a build tool can act on.
 *
 * The build tools exist only in Build mode and every one of them acts on the
 * canvas: `add-peer` on empty space, the two-click tools on a peer or a session
 * end. Nothing any of them does lands on the Timeline, so the Timeline's
 * surfaces are not in this set and cannot be talked about in a build tool's
 * terms.
 *
 * It is the whole family and not just the surfaces a tool has a verb for,
 * because a tool's resting cursor is its statement of which tool is active and
 * has to hold across the canvas rather than blink out when the pointer crosses
 * an edge or a message.
 *
 * Written out rather than tested by name prefix: the prefix is a naming
 * convention and this is a claim about what a tool can reach, so a surface
 * added to one family without a thought about the other should be a decision
 * somebody makes here.
 */
export const STAGE_SURFACES: ReadonlySet<SurfaceId> = new Set<SurfaceId>([
	"stage-empty",
	"stage-peer",
	"stage-endpoint",
	"stage-edge",
	"stage-message",
]);

/** Whether this surface is one the Stage owns, and so one a build tool may
 *  speak about. */
export function isStageSurface(surface: SurfaceId): boolean {
	return STAGE_SURFACES.has(surface);
}

/**
 * The Stage hit that names `ref`, for the four stage surfaces.
 *
 * The Stage needs it because its hover is an entity and the resolver speaks
 * `Hit`s: an affordance can only ask what a click would do by handing over the
 * hit that click would produce. Here rather than in the Stage so a new entity
 * kind has one exhaustive place to acquire its surface vocabulary.
 */
export function stageHitFor(ref: EntityRef): Hit {
	switch (ref.kind) {
		case "peer":
			return { surface: "stage-peer", peerId: ref.id };
		case "endpoint":
			return { surface: "stage-endpoint", endpointId: ref.id };
		case "session":
			return { surface: "stage-edge", sessionId: ref.id };
		case "message":
			return { surface: "stage-message", messageId: ref.id };
	}
}
