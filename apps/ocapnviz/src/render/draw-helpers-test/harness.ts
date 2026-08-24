/**
 * Shared assertions and the dashed-rect canvas stand-in.
 *
 * Outline and loose-end tests both paint through `RectCanvas`; the
 * claim body extends that recorder rather than inventing a second one.
 */

import { assert } from "@std/assert";
import type { RectCanvas } from "../draw-helpers.ts";

export function at<T>(xs: T[], i: number, what: string): T {
	const x = xs[i];
	assert(
		x !== undefined,
		`expected a ${what} at index ${i}, saw ${xs.length}`,
	);
	return x;
}

type RectCall =
	| { op: "moveTo"; x: number; y: number }
	| { op: "lineTo"; x: number; y: number }
	| { op: "arcTo"; x1: number; y1: number; x2: number; y2: number; r: number }
	| { op: "stroke"; width: number };

export class RectRecorder implements RectCanvas {
	readonly calls: RectCall[] = [];
	moveTo(x: number, y: number) {
		this.calls.push({ op: "moveTo", x, y });
	}
	lineTo(x: number, y: number) {
		this.calls.push({ op: "lineTo", x, y });
	}
	arcTo(x1: number, y1: number, x2: number, y2: number, r: number) {
		this.calls.push({ op: "arcTo", x1, y1, x2, y2, r });
	}
	stroke(style: { width: number }) {
		this.calls.push({ op: "stroke", width: style.width });
	}
	strokeWidthOf(): number {
		const s = this.calls.find((c) => c.op === "stroke");
		assert(s, "expected a stroke");
		return s.width;
	}
	/** The dashes, as (start, end) pairs — every `lineTo` and the `moveTo`
	 *  that opened it. */
	dashes(): { x0: number; y0: number; x1: number; y1: number }[] {
		const out: { x0: number; y0: number; x1: number; y1: number }[] = [];
		for (let i = 1; i < this.calls.length; i++) {
			const c = at(this.calls, i, "call");
			const prev = at(this.calls, i - 1, "call");
			if (c.op !== "lineTo") continue;
			assert(prev.op === "moveTo", `dash at ${i} continues an open path`);
			out.push({ x0: prev.x, y0: prev.y, x1: c.x, y1: c.y });
		}
		return out;
	}
}
