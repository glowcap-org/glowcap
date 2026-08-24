/**
 * Tracks the bounding rects of "scene regions" — DOM marker divs
 * that tell each PixiJS scene where on the unified canvas to draw.
 *
 * Polling (not ResizeObserver) because a sibling-panel resize moves
 * a region's POSITION (which ResizeObserver doesn't fire on) as
 * well as its size. `getBoundingClientRect` captures both; polling
 * once per Pixi frame is O(regions) and we only have a few.
 *
 * Subscribers fire once on registration (so a mid-frame attach
 * doesn't wait a frame for layout) and then only when the rect
 * actually changes.
 */

export type Rect = {
	x: number;
	y: number;
	width: number;
	height: number;
};

export class RegionRegistry {
	#elements = new Map<string, HTMLElement>();
	#lastRects = new Map<string, Rect>();
	#subs = new Map<string, Set<(rect: Rect) => void>>();

	/** Tie a name to a DOM element. The element's viewport-relative
	 * `getBoundingClientRect` becomes the scene's position + size.
	 * Returns a disposer. */
	register(name: string, el: HTMLElement): () => void {
		this.#elements.set(name, el);
		// Eager read so the first subscriber fire has data.
		const r = el.getBoundingClientRect();
		this.#lastRects.set(name, {
			x: r.left,
			y: r.top,
			width: r.width,
			height: r.height,
		});
		return () => {
			// Only what this registration put here. A remount can register the
			// replacement element before tearing the old one down, and a disposer
			// that removed the name outright would take the live element's row with
			// it: the region would stop being polled while it is still on screen,
			// and its scene would sit at whatever rect it last saw.
			if (this.#elements.get(name) !== el) return;
			this.#elements.delete(name);
			this.#lastRects.delete(name);
		};
	}

	/** Fires immediately with the current rect (if known) and on
	 * each subsequent change. Returns a disposer. */
	subscribe(name: string, fn: (rect: Rect) => void): () => void {
		let set = this.#subs.get(name);
		if (!set) {
			set = new Set();
			this.#subs.set(name, set);
		}
		set.add(fn);
		const rect = this.#lastRects.get(name);
		if (rect) fn(rect);
		return () => {
			set?.delete(fn);
			if (set?.size === 0) this.#subs.delete(name);
		};
	}

	/** Re-read every registered element. Call once per animation
	 * frame. Subscribers fire only on actual change.
	 *
	 * The measurements are compared before a `Rect` is built, so a layout that has
	 * not moved costs nothing: this runs on every frame of every scene, and the
	 * usual answer is that nothing changed. Building one to compare it allocated a
	 * rect per region per frame and threw all of them away. */
	poll(): void {
		for (const [name, el] of this.#elements) {
			const r = el.getBoundingClientRect();
			const prev = this.#lastRects.get(name);
			if (
				prev && prev.x === r.left && prev.y === r.top &&
				prev.width === r.width && prev.height === r.height
			) {
				continue;
			}
			const rect: Rect = {
				x: r.left,
				y: r.top,
				width: r.width,
				height: r.height,
			};
			this.#lastRects.set(name, rect);
			const set = this.#subs.get(name);
			set?.forEach((fn) => fn(rect));
		}
	}

	/** Latest known rect for a region, or `null` if unregistered. */
	get(name: string): Rect | null {
		return this.#lastRects.get(name) ?? null;
	}
}
