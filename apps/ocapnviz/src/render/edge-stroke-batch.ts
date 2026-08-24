/**
 * One Pixi `Graphics` for every session wire.
 *
 * Dirty wires mark the batch; `flush` clear+restrokes once so a moving
 * peer pays one upload instead of one per incident edge. How a curve is
 * inked (`strokeCurve` / `strokeDashedCurve` in `edge-stroke.ts`) and
 * per-session hit proxies, halos, and chips stay outside this class —
 * only GPU buffer ownership for the wire ink lives here.
 */

import { Graphics } from "pixi.js";
import type { SessionCurve } from "../engine/session-geometry.ts";
import type { CodecLineStyle } from "./palette.ts";
import { DASH_PATTERN, DOT_PATTERN } from "./palette.ts";
import { strokeCurve, strokeDashedCurve } from "./edge-stroke.ts";

export type EdgeStrokeSpec = {
	curve: SessionCurve;
	color: number;
	width: number;
	lineStyle: CodecLineStyle;
};

/** Shared stroke surface for every drawn session wire. */
export class EdgeStrokeBatch {
	readonly gfx: Graphics;
	readonly #entries = new Map<string, EdgeStrokeSpec>();
	/** Paint order — later ids draw on top (high session z last). */
	#order: string[] = [];
	#dirty = true;

	constructor() {
		this.gfx = new Graphics();
		this.gfx.eventMode = "none";
		// Under every per-edge hitArea/halo (those use 0..n). Wires share
		// one layer; selection glows stay readable on top at crossings.
		// Hit-testing still reaches the proxies because they sit above
		// and this node is non-interactive.
		this.gfx.zIndex = -1;
	}

	/** Replace the stroke for `id`, or insert it. Marks the batch dirty
	 *  only when the drawn picture would change. */
	upsert(id: string, spec: EdgeStrokeSpec): void {
		const prev = this.#entries.get(id);
		const c = spec.curve;
		if (
			prev &&
			prev.color === spec.color &&
			prev.width === spec.width &&
			prev.lineStyle === spec.lineStyle &&
			prev.curve.ax === c.ax &&
			prev.curve.ay === c.ay &&
			prev.curve.bx === c.bx &&
			prev.curve.by === c.by &&
			prev.curve.cx === c.cx &&
			prev.curve.cy === c.cy
		) {
			return;
		}
		// Copy the curve: the engine rebuilds `sessionCurves` each stage
		// pass; flush reads what upsert stored, not the live map.
		this.#entries.set(id, {
			color: spec.color,
			width: spec.width,
			lineStyle: spec.lineStyle,
			curve: {
				ax: c.ax,
				ay: c.ay,
				bx: c.bx,
				by: c.by,
				cx: c.cx,
				cy: c.cy,
			},
		});
		this.#dirty = true;
	}

	/** Drop a wire (session gone, or body-hidden). */
	remove(id: string): void {
		if (!this.#entries.delete(id)) return;
		this.#dirty = true;
	}

	/** Authoritative paint order for this frame. Entries not listed are
	 *  dropped — the order is the set of body-visible wires. */
	setOrder(ids: readonly string[]): void {
		const keep = new Set(ids);
		for (const id of this.#entries.keys()) {
			if (keep.has(id)) continue;
			this.#entries.delete(id);
			this.#dirty = true;
		}
		if (sameOrder(this.#order, ids)) return;
		this.#order = ids.slice();
		this.#dirty = true;
	}

	/** Tessellate every retained stroke into the one Graphics when dirty. */
	flush(): void {
		if (!this.#dirty) return;
		this.#dirty = false;
		this.gfx.clear();
		for (const id of this.#order) {
			const spec = this.#entries.get(id);
			if (!spec) continue;
			paintStroke(this.gfx, spec);
		}
	}

	/** Drop retained stroke bookkeeping. The Graphics itself is a child
	 *  of `edgeLayer` and dies with the scene graph. */
	destroy(): void {
		this.#entries.clear();
		this.#order = [];
		this.#dirty = true;
	}
}

function paintStroke(g: Graphics, spec: EdgeStrokeSpec): void {
	const style = { color: spec.color, width: spec.width, alpha: 1 };
	switch (spec.lineStyle) {
		case "dashed":
			strokeDashedCurve(g, spec.curve, DASH_PATTERN, style);
			break;
		case "dotted":
			strokeDashedCurve(g, spec.curve, DOT_PATTERN, style);
			break;
		case "solid":
			strokeCurve(g, spec.curve, style);
			break;
		default: {
			const _exhaustive: never = spec.lineStyle;
			return _exhaustive;
		}
	}
}

function sameOrder(a: readonly string[], b: readonly string[]): boolean {
	if (a.length !== b.length) return false;
	for (let i = 0; i < a.length; i++) {
		if (a[i] !== b[i]) return false;
	}
	return true;
}
