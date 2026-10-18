// Color tokens read for a shader, which takes numbers rather than CSS.

/// <reference lib="dom" />

/** A color as straight channels from 0 to 1. */
export type Rgba = readonly [number, number, number, number];

let swatch: CanvasRenderingContext2D | null | undefined;

/** Read each of `tokens` as the page resolves it under `host`. A token can
 * hold `color-mix()`, `light-dark()`, or any color space, and its computed
 * `color` can take any form, so a 1×1 canvas paints it and the channels are
 * read back from that. `scheme` reads the tokens as that color scheme
 * resolves them, whatever the page's is. Null when the browser has no 2D
 * canvas to paint with. */
export function readColors<K extends string>(
	host: HTMLElement,
	tokens: Readonly<Record<K, string>>,
	scheme?: "dark",
): Record<K, Rgba> | null {
	swatch ??= document.createElement("canvas").getContext("2d", { willReadFrequently: true });
	if (swatch === null) return null;
	const paint = swatch;
	const probe = document.createElement("span");
	probe.style.position = "absolute";
	probe.style.opacity = "0";
	probe.style.pointerEvents = "none";
	if (scheme !== undefined) probe.style.colorScheme = scheme;
	host.appendChild(probe);
	const read = (token: string): Rgba => {
		probe.style.color = `var(${token})`;
		paint.clearRect(0, 0, 1, 1);
		paint.fillStyle = getComputedStyle(probe).color;
		paint.fillRect(0, 0, 1, 1);
		const [r, g, b, a] = paint.getImageData(0, 0, 1, 1).data;
		return [r / 255, g / 255, b / 255, a / 255];
	};
	const colors = Object.fromEntries(Object.entries<string>(tokens).map(([k, token]) => [k, read(token)]));
	probe.remove();
	return colors as Record<K, Rgba>;
}
