// What a reader can actually read, measured rather than declared.
//
// Shared because both rails are drawn from one set of tokens and each browser
// proof can only reach half of them: the page proof is the only place two
// directories put a caption under every room, and a direct-message row exists
// nowhere but the two-tab proof. Measuring one list and trusting the other is
// how a rule proven on the amber went unchecked on the teal.

import type { Page } from "playwright";

/** Contrast of an element's own text against what a reader actually sees behind
 * it, or null when there is nothing on screen to measure.
 *
 * This page states almost no colour anybody sees. Grounds are `color-mix` over
 * tokens, the rails' fill is a gradient rather than a colour at all, rows dim
 * whole subtrees with `opacity`, and the browser hands the results back as
 * `rgb(…)`, `color(srgb …)` or `oklab(…)` depending on how each was written. So
 * this reads no colours: it paints the whole stack into a one-pixel canvas and
 * looks at the result, which is the browser's own colour maths and understands
 * every syntax the browser does. A gradient ground is measured at each of its
 * stops and the worst answer is the one returned, because a reader meets all of
 * them.
 *
 * It returns null rather than a number whenever it could not do that, nothing
 * on screen, no opaque ground beneath, or a colour the canvas would not take,
 * because "no answer" and "passes" must never look alike. Three separate
 * versions of this measured nothing at all while reporting it exactly the way a
 * pass reports. */
export function inkContrast(page: Page, selector: string): Promise<{ ratio: number; saw: string } | null> {
	return page.evaluate((selector) => {
		const el = document.querySelector(selector);
		if (!(el instanceof HTMLElement) || el.getBoundingClientRect().width === 0) return null;

		const ctx = document.createElement("canvas").getContext("2d", { willReadFrequently: true });
		if (ctx === null) return null;
		// A canvas keeps its previous fill when handed something it cannot parse,
		// which would quietly measure the wrong colour. Offering the same value
		// against two different starting fills catches that: a value it took reads
		// back the same both times.
		// A colour the canvas will not parse, rewritten into one it will. A
		// `color-mix()` computes to `color(srgb …)`, which this Chromium's canvas
		// does not take, and the check below is right to refuse what it cannot
		// read, so without this every stack with a mixed wash anywhere above it
		// measures as "no answer". Which is most of the page's own surfaces.
		const canvasColour = (css: string): string => {
			const parts = /^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)(?:\s*\/\s*([\d.]+))?\)$/
				.exec(css.trim());
			if (parts === null) return css;
			const channel = (n: string) => Math.round(Math.min(1, Math.max(0, Number(n))) * 255);
			const alpha = parts[4] === undefined ? 1 : Number(parts[4]);
			return `rgba(${channel(parts[1])}, ${channel(parts[2])}, ${channel(parts[3])}, ${alpha})`;
		};
		const takes = (raw: string): boolean => {
			const css = canvasColour(raw);
			ctx.fillStyle = "#000000";
			ctx.fillStyle = css;
			const first = ctx.fillStyle;
			ctx.fillStyle = "#ffffff";
			ctx.fillStyle = css;
			return first === ctx.fillStyle;
		};
		const pixel = (): [number, number, number, number] => {
			const d = ctx.getImageData(0, 0, 1, 1).data;
			return [d[0], d[1], d[2], d[3]];
		};
		const lay = (raw: string, alpha = 1) => {
			ctx.globalAlpha = alpha;
			ctx.fillStyle = canvasColour(raw);
			ctx.fillRect(0, 0, 1, 1);
			ctx.globalAlpha = 1;
		};
		const opaque = (css: string): boolean => {
			ctx.clearRect(0, 0, 1, 1);
			lay(css);
			return pixel()[3] === 255;
		};
		const luminance = ([r, g, b]: [number, number, number, number]): number => {
			const channel = (n: number) => {
				const s = n / 255;
				return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
			};
			return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
		};

		// Each layer from the element outwards, as the colours it might contribute:
		// one for an ordinary ground, one per stop for a gradient. Collected until
		// something opaque is reached, because that is the bottom of what a reader
		// sees. The opacity every ancestor applies rides along, since it dims the
		// text inside it rather than the ground behind it.
		const layers: string[][] = [];
		let dimming = 1;
		let floor = false;
		for (let at: HTMLElement | null = el; at !== null && !floor; at = at.parentElement) {
			const style = getComputedStyle(at);
			dimming *= Number(style.opacity);
			const image = style.backgroundImage;
			const stops = image === "none"
				? []
				: [...image.matchAll(/(rgba?\([^)]*\)|color\([^)]*\)|okla[bch]\([^)]*\)|#[0-9a-fA-F]{3,8})/g)]
					.map((m) => m[1]);
			const ground = style.backgroundColor;
			for (const css of [...stops, ground]) if (!takes(css)) return null;
			const contributing = [...stops, ground].filter((css) => {
				ctx.clearRect(0, 0, 1, 1);
				lay(css);
				return pixel()[3] > 0;
			});
			if (contributing.length === 0) continue;
			layers.push(contributing);
			if (contributing.some(opaque)) floor = true;
		}
		if (!floor) return null;

		const ink = getComputedStyle(el).color;
		if (!takes(ink)) return null;

		// Every way the stack can be painted, worst answer wins. Only a gradient
		// offers more than one colour, so in practice this is two or three.
		let worst = Infinity;
		let saw = "";
		const walk = (depth: number, chosen: string[]) => {
			if (depth < 0) {
				ctx.clearRect(0, 0, 1, 1);
				for (const css of chosen) lay(css);
				const ground = pixel();
				lay(ink, dimming);
				const text = pixel();
				const [bright, dark] = [luminance(text), luminance(ground)].sort((a, b) => b - a);
				const ratio = (bright + 0.05) / (dark + 0.05);
				if (ratio < worst) {
					worst = ratio;
					// Kept so a failure says which two colours it is about. A contrast
					// number on its own cannot be checked by anyone reading the report,
					// and the two that produced it usually name the cause outright.
					saw = `ink ${text.slice(0, 3).join(",")} on ${ground.slice(0, 3).join(",")}`;
				}
				return;
			}
			for (const css of layers[depth]) walk(depth - 1, [...chosen, css]);
		};
		walk(layers.length - 1, []);
		return worst === Infinity ? null : { ratio: worst, saw };
	}, selector);
}
