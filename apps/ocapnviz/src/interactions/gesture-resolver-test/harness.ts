// Test-side helpers for the gesture resolver: the total set of surface ids for
// exhaustiveness checks, and a minimal valid Hit for a surface. Production
// code uses surface-specific hit-testers and never needs either.

import { type BuilderTool, type EntityRef, type Hit, stageHitFor, type SurfaceId } from "../types.ts";

function assertNever(x: never): never {
	throw new Error(`unhandled discriminant: ${JSON.stringify(x)}`);
}

/** All surface ids — used by exhaustive-switch totality tests. */
export const ALL_SURFACES: ReadonlySet<SurfaceId> = new Set<SurfaceId>([
	"stage-empty",
	"stage-peer",
	"stage-endpoint",
	"stage-edge",
	"stage-message",
	"timeline-overview",
	"timeline-overview-edge",
	"timeline-ruler",
	"timeline-lane-empty",
	"timeline-lane-event",
	"timeline-lane-event-edge",
	"timeline-gutter-edge",
	"timeline-gutter-chevron",
	"timeline-gutter-eyeball",
	"timeline-gutter-label",
]);

/** All tools — used by exhaustive-switch totality tests. */
export const ALL_TOOLS: readonly BuilderTool[] = [
	"select",
	"hand",
	"add-peer",
	"open-session",
	"send-message",
];

/** Construct a minimal valid `Hit` for a given surface id. Test
 *  helper — production code uses surface-specific hit-testers. */
export function dummyHit(
	surface: SurfaceId,
	refs?: {
		peerId?: string;
		endpointId?: string;
		sessionId?: string;
		messageId?: string;
		eventId?: string;
		entityId?: string;
		t?: number;
		category?: "peers" | "sessions" | "messages";
	},
): Hit {
	const peerRef: EntityRef = { kind: "peer", id: refs?.peerId ?? "p1" };
	const sessRef: EntityRef = {
		kind: "session",
		id: refs?.sessionId ?? "s1",
	};
	const msgRef: EntityRef = {
		kind: "message",
		id: refs?.messageId ?? "m1",
	};
	switch (surface) {
		case "stage-empty":
			return { surface: "stage-empty" };
		// Through `stageHitFor`, so a helper that fabricates hits for the resolver's
		// own tests cannot fabricate a shape the Stage never produces.
		case "stage-peer":
			return stageHitFor(peerRef);
		case "stage-endpoint":
			return stageHitFor({
				kind: "endpoint",
				id: refs?.endpointId ?? "s1::b",
			});
		case "stage-edge":
			return stageHitFor(sessRef);
		case "stage-message":
			return stageHitFor(msgRef);
		case "timeline-overview":
			return { surface: "timeline-overview", t: refs?.t ?? 0 };
		case "timeline-overview-edge":
			return {
				surface: "timeline-overview-edge",
				edge: "start",
				t: refs?.t ?? 0,
			};
		case "timeline-ruler":
			return { surface: "timeline-ruler", t: refs?.t ?? 0 };
		case "timeline-lane-empty":
			return { surface: "timeline-lane-empty", t: refs?.t ?? 0 };
		case "timeline-lane-event":
			return {
				surface: "timeline-lane-event",
				eventId: refs?.eventId ?? "e1",
				entityRef: peerRef,
			};
		case "timeline-lane-event-edge":
			return {
				surface: "timeline-lane-event-edge",
				eventId: refs?.eventId ?? "e1",
				entityRef: msgRef,
			};
		case "timeline-gutter-edge":
			return { surface: "timeline-gutter-edge" };
		case "timeline-gutter-chevron":
			return {
				surface: "timeline-gutter-chevron",
				category: refs?.category ?? "peers",
			};
		case "timeline-gutter-eyeball":
			return {
				surface: "timeline-gutter-eyeball",
				scope: {
					kind: "row",
					category: refs?.category ?? "peers",
					entityId: refs?.entityId ?? peerRef.id,
				},
			};
		case "timeline-gutter-label":
			return {
				surface: "timeline-gutter-label",
				category: refs?.category ?? "peers",
				entityId: refs?.entityId ?? peerRef.id,
			};
		default:
			return assertNever(surface);
	}
}
