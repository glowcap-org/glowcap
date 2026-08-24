/**
 * Selection-mark answers the tick asks of every sprite kind: which
 * halo tier this entity wears, and whether that mark is worth
 * repainting.
 *
 * A mark exists only while its entity is selected or under the pointer, and the
 * repaint gate reads the camera — so on a stage with nothing picked, every one of
 * these sprites cleared an empty `Graphics` on every frame of every zoom, to draw
 * nothing into it. Clearing is not free: it dirties the geometry and the renderer
 * rebuilds it. Asking whether there is a mark, or was one a frame ago, is what
 * makes an unmarked stage cost nothing to zoom.
 *
 * Both halves of `marked` are needed. Without the second, the frame that clears a
 * mark away would be skipped and the mark would stay on screen.
 */

import type { EntityRefKey } from "../../interactions/types.ts";
import type { HaloTier } from "../types.ts";

/** Resolve an entity's halo tier from the selection set + anchor
 *  in one shot. Anchor wins over selected (it implies selected
 *  by invariant), so the call site doesn't repeat the subset
 *  check. */
export function haloTierFor(
	selection: ReadonlySet<EntityRefKey>,
	anchor: EntityRefKey | null,
	key: EntityRefKey,
): HaloTier {
	if (anchor === key) return "anchor";
	if (selection.has(key)) return "selected";
	return "none";
}

export function marked(
	tier: HaloTier,
	hovered: boolean,
	wasTier: HaloTier,
	wasHovered: boolean,
): boolean {
	return tier !== "none" || hovered || wasTier !== "none" || wasHovered;
}
