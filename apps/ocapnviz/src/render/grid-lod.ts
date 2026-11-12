/**
 * World-space dot-grid background. Three LOD tiers (coarse / mid /
 * fine), each a `Container` of N×N tile `Graphics` so the culler
 * can skip tiles outside the viewport before vertex submission.
 *
 * `WORLD_SIZE` is the canvas world's logical bounds, also drives
 * the pixi-viewport `worldWidth`/`worldHeight`, so it's exported
 * for Stage's viewport setup to consume from the same source.
 */

import { type Container, Graphics, Rectangle } from "pixi.js";

export const WORLD_SIZE = 4000;

/**
 * How far apart a tier's dots have to be on screen before that tier is drawn,
 * in CSS pixels.
 *
 * The tiers are a lattice in world units, so what a reader sees depends on the
 * camera: one tier's dots are a readable grid at one zoom, a grey haze at
 * another. Asking the question in screen space is what makes the answer hold at
 * any zoom, including the ones nobody has tried yet. Asking it in zoom numbers
 * would tie the windows to the range the camera is clamped to, and widening
 * the range would leave the coarsest tier drawing a sub-pixel mesh with
 * nothing to read in it.
 *
 * Sixteen is a little over the point where a dot lattice stops reading as
 * structure and starts reading as texture.
 */
export const GRID_MIN_DOT_SPACING_PX = 16;

/**
 * The width of the fade, in screen pixels of spacing, above the threshold.
 *
 * A tier appears over a band rather than at an instant so a slow zoom does not
 * pop a whole lattice into place in one frame.
 */
export const GRID_FADE_SPACING_PX = 10;

/**
 * How visible a tier whose dots sit `spacingPx` apart on screen should be.
 *
 * Zero below the legibility threshold, one once it is comfortably past it. The
 * caller multiplies by whatever alpha the tier is styled at, so this answers
 * only the question of whether there is a readable grid there.
 */
export function gridTierOpacity(spacingPx: number): number {
	const over = (spacingPx - GRID_MIN_DOT_SPACING_PX) / GRID_FADE_SPACING_PX;
	return over <= 0 ? 0 : over >= 1 ? 1 : over;
}

/**
 * The three lattices, coarse last so it reads as the major intersection
 * against the field of finer ones at default zoom. One row per tier so
 * paint and the level-of-detail decision share the same `step`.
 */
export const GRID_TIER_SPECS = [
	{ step: 50, radius: 1.0, alpha: 0.22 },
	{ step: 250, radius: 2.5, alpha: 0.32 },
	{ step: 1000, radius: 5.0, alpha: 0.42 },
] as const;

export type StageGridLayers = readonly [Container, Container, Container];

/** Stamp every tier's tiles in the given color. */
export function paintGridTiers(
	[fine, medium, coarse]: StageGridLayers,
	color: number,
): void {
	const [a, b, c] = GRID_TIER_SPECS;
	populateGridLOD(fine, a.step, a.radius, color, a.alpha);
	populateGridLOD(medium, b.step, b.radius, color, b.alpha);
	populateGridLOD(coarse, c.step, c.radius, color, c.alpha);
}

/**
 * Each tier appears when its own dots are far enough apart on screen to
 * read as a grid. Every tier answers to the same rule, coarse included:
 * pinned always-on, it would be a sub-pixel haze once the camera reaches
 * one percent.
 */
export function applyGridLod(
	[fine, medium, coarse]: StageGridLayers,
	zoom: number,
): void {
	const [a, b, c] = GRID_TIER_SPECS;
	const apply = (
		layer: Container,
		spec: (typeof GRID_TIER_SPECS)[number],
	) => {
		const opacity = gridTierOpacity(spec.step * zoom);
		layer.alpha = opacity;
		layer.visible = opacity > 0;
	};
	apply(fine, a);
	apply(medium, b);
	apply(coarse, c);
}

/** Per-LOD grid is split into N×N tiles so the culler can skip
 * tiles outside the marker rect before vertex submission. 4 keeps
 * each tile roughly one viewport wide at default zoom. */
const GRID_TILES_PER_AXIS = 4;
const GRID_TILE_SIZE = WORLD_SIZE / GRID_TILES_PER_AXIS;

/** (Re)build the tile-grid children of one LOD container. Reuses
 * existing tile `Graphics` so a theme repaint doesn't churn GPU
 * buffers. Only the dot geometry is redrawn. Tile identity and
 * `boundsArea` are stable. */
export function populateGridLOD(
	parent: Container,
	step: number,
	radius: number,
	color: number,
	alpha: number,
): void {
	const needed = GRID_TILES_PER_AXIS * GRID_TILES_PER_AXIS;
	while (parent.children.length < needed) {
		const tile = new Graphics();
		tile.cullable = true;
		parent.addChild(tile);
	}
	while (parent.children.length > needed) {
		const extra = parent.removeChildAt(parent.children.length - 1);
		if ("destroy" in extra) extra.destroy();
	}
	const half = WORLD_SIZE / 2;
	let i = 0;
	for (let tx = 0; tx < GRID_TILES_PER_AXIS; tx++) {
		for (let ty = 0; ty < GRID_TILES_PER_AXIS; ty++) {
			const tile = parent.children[i++] as Graphics;
			const x0 = -half + tx * GRID_TILE_SIZE;
			const y0 = -half + ty * GRID_TILE_SIZE;
			// `boundsArea` short-circuits the cull check's bounds walk.
			tile.boundsArea = new Rectangle(
				x0,
				y0,
				GRID_TILE_SIZE,
				GRID_TILE_SIZE,
			);
			drawGridTile(tile, x0, y0, step, radius, color, alpha);
		}
	}
}

/** Stamp one tile's share of the global dot lattice. Dots are in
 * world coords snapped to the lattice. `[x0, x0+size)` is half-open
 * so adjacent tiles don't double-stamp boundary dots. */
function drawGridTile(
	tile: Graphics,
	x0: number,
	y0: number,
	step: number,
	radius: number,
	color: number,
	alpha: number,
): void {
	tile.clear();
	const sx0 = Math.ceil(x0 / step) * step;
	const sy0 = Math.ceil(y0 / step) * step;
	const x1 = x0 + GRID_TILE_SIZE;
	const y1 = y0 + GRID_TILE_SIZE;
	for (let x = sx0; x < x1; x += step) {
		for (let y = sy0; y < y1; y += step) {
			tile.circle(x, y, radius);
		}
	}
	tile.fill({ color, alpha });
}
