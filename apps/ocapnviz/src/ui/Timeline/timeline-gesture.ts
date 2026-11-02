/**
 * Timeline gesture controller.
 *
 * Overview and Scrubber have different geometry and mutation adapters, but
 * neither owns precedence. This module narrows Stage-only tools to Select and
 * resolves the shared navigation ladder once for both cursor and pointer-down.
 * A Hand or Space cursor therefore cannot advertise a pan while the host
 * starts a resize, retime, selection, or visibility mutation instead.
 */

import {
	navigationOverride,
	type ResolvedGesture,
	resolveGesture,
	type SurfaceGestureCtx,
} from "../../interactions/gesture-resolver.ts";
import type { CursorContext } from "../../interactions/cursor.ts";
import type { Hit } from "../../interactions/surface-hit.ts";
import { navigationToolOf } from "../../interactions/builder-tool.ts";

/** The context every Timeline surface presents to the shared cursor ladder. */
export function timelineCursorContext(
	ctx: SurfaceGestureCtx,
): CursorContext {
	return {
		...ctx,
		activeTool: navigationToolOf(ctx.activeTool),
		toolState: null,
	};
}

/**
 * Resolve what a Timeline pointer-down means. Navigation applies even when a
 * gutter pad has no hit. Ordinary verbs require a concrete hit and otherwise
 * return null.
 */
export function resolveTimelineGesture(
	hit: Hit | null,
	ctx: SurfaceGestureCtx,
): ResolvedGesture | null {
	const cursorCtx = timelineCursorContext(ctx);
	const navigation = navigationOverride(cursorCtx);
	if (navigation !== null) return navigation;
	if (hit === null) return null;
	return resolveGesture({ ...cursorCtx, hit });
}
