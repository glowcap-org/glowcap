/**
 * A canvas for a renderer test to measure text against.
 *
 * PixiJS lays a label out by asking a 2D canvas how wide the string is, and
 * `deno test` has no `document` to get one from. Pixi already has the seam for
 * this: `DOMAdapter` is what every DOM call in the library goes through, and
 * it takes a replacement. So a test installs this one and gets text sizes from
 * arithmetic instead of from a browser.
 *
 * What it returns is a plausible size, not a real measurement, so nothing here
 * can settle a question about how wide a label draws. A test that cares about
 * pixels belongs in a browser. What this makes testable is everything ABOVE
 * the measurement, such as which sprites a frame leaves on the stage.
 */

import { DOMAdapter } from "pixi.js";

/** Roughly the aspect of the faces the stage uses, so a long string measures
 *  wider than a short one and nothing lands on zero. */
const WIDTH_PER_CHAR = 0.55;
const ASCENT = 0.8;
const DESCENT = 0.2;

function sizeOf(font: string): number {
	const px = /(\d+(?:\.\d+)?)px/.exec(font);
	return px === null ? 12 : Number(px[1]);
}

function context2d(): unknown {
	let font = "12px sans-serif";
	return {
		get font(): string {
			return font;
		},
		set font(next: string) {
			font = next;
		},
		measureText(text: string) {
			const size = sizeOf(font);
			const width = text.length * size * WIDTH_PER_CHAR;
			return {
				width,
				actualBoundingBoxLeft: 0,
				actualBoundingBoxRight: width,
				actualBoundingBoxAscent: size * ASCENT,
				actualBoundingBoxDescent: size * DESCENT,
				fontBoundingBoxAscent: size * ASCENT,
				fontBoundingBoxDescent: size * DESCENT,
			};
		},
		fillText(): void {},
		clearRect(): void {},
		scale(): void {},
		translate(): void {},
		save(): void {},
		restore(): void {},
	};
}

function canvas(width = 1, height = 1): unknown {
	const ctx = context2d();
	return {
		width,
		height,
		getContext: (kind: string) => (kind === "2d" ? ctx : null),
		addEventListener(): void {},
		removeEventListener(): void {},
	};
}

let installed = false;

/**
 * Point Pixi's DOM calls at the canvas above. Idempotent, so every test that
 * paints may call it without the tests having to agree on an order.
 *
 * Every member of the adapter is answered here rather than layered over the
 * browser one, because the browser one reaches for globals (`document`,
 * `CanvasRenderingContext2D`) that only exist in a browser, and a member left
 * to fall through fails the moment Pixi happens to call it.
 */
export function installHeadlessCanvas(): void {
	if (installed) return;
	installed = true;
	DOMAdapter.set(
		{
			createCanvas: (width?: number, height?: number) => canvas(width, height),
			createImage: () => ({}),
			// Pixi asks the prototype whether letter spacing is supported. Nothing
			// here spaces letters, so the answer is no.
			getCanvasRenderingContext2D: () => ({ prototype: {} }),
			getWebGLRenderingContext: () => ({}),
			getNavigator: () => ({ userAgent: "deno", gpu: null }),
			getBaseUrl: () => "http://localhost/",
			getFontFaceSet: () => null,
			fetch: (url: RequestInfo, options?: RequestInit) => fetch(url, options),
			parseXML: () => {
				throw new Error(
					"headless canvas: nothing under test parses XML",
				);
			},
			// The adapter's members are typed against DOM interfaces this stands in
			// for, so the shape is asserted once here rather than at each member.
		} as unknown as Parameters<typeof DOMAdapter.set>[0],
	);
}
