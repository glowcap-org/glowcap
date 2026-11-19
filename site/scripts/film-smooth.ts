/// <reference lib="dom" />
/**
 * Smooth layout for a filmed page. A Rooms page moves rows, cards, and lines
 * to their new places in one frame, which reads as a jump on video. Once a
 * film calls `smoothLayout`, an element that moves glides from where it was,
 * and an element that appears fades in. Only the film's page changes: the
 * app itself still moves at once.
 *
 * A tracked element inside another tracked element glides only by its own
 * move, because its parent's glide already carries it. A move longer than
 * half the window is a change of view and stays a cut.
 */
import type { Page } from "playwright";

/** How long a moved element takes to reach its new place. */
const GLIDE_MS = 280;

/** What a Rooms film tracks: the sidebar's sections and rows, the open
 * conversation's lines and composer, the member list, and the join card with
 * its fields. */
export const ROOMS_LAYOUT = [
	".sidebar .section",
	".sidebar .section li",
	"#log > *",
	".composer",
	"#members > li",
	"#joinForm",
	"#joinForm .join-fields > *",
];

export async function smoothLayout(page: Page, selectors: readonly string[]): Promise<void> {
	await page.evaluate(({ selector, ms }) => {
		type Point = { x: number; y: number };
		const still: Point = { x: 0, y: 0 };
		const placed = new WeakMap<Element, Point>();
		const glides = new WeakMap<Element, Animation>();
		let first = true;
		// Where an element's own glide shows it now, relative to its layout.
		const offset = (el: Element): Point => {
			if (glides.get(el)?.playState !== "running") return still;
			const [x, y] = getComputedStyle(el).translate.split(" ");
			return { x: parseFloat(x) || 0, y: parseFloat(y ?? "0") || 0 };
		};
		const tick = () => {
			const tracked = [...document.querySelectorAll(selector)];
			const set = new Set<Element>(tracked);
			// Every box is read before any glide starts, because a glide
			// started on a parent moves its children's boxes in the same frame.
			const read = tracked.map((el) => {
				let up = el.parentElement;
				while (up != null && !set.has(up)) up = up.parentElement;
				return { el, up, own: offset(el), box: el.getBoundingClientRect() };
			});
			// Each element's glide plus its tracked ancestors', and its layout
			// move since the last frame.
			const shown = new Map<Element, Point>();
			const moved = new Map<Element, Point>();
			for (const { el, up, own, box } of read) {
				const above = (up == null ? undefined : shown.get(up)) ?? still;
				shown.set(el, { x: above.x + own.x, y: above.y + own.y });
				if (box.width === 0 && box.height === 0) {
					placed.delete(el);
					continue;
				}
				const at = { x: box.left - above.x - own.x, y: box.top - above.y - own.y };
				const was = placed.get(el);
				placed.set(el, at);
				if (was == null) {
					if (!first) el.animate({ opacity: [0, 1] }, { duration: ms, easing: "ease-out" });
					continue;
				}
				const move = { x: at.x - was.x, y: at.y - was.y };
				moved.set(el, move);
				const carried = (up == null ? undefined : moved.get(up)) ?? still;
				const x = move.x - carried.x;
				const y = move.y - carried.y;
				if (Math.abs(x) < 0.5 && Math.abs(y) < 0.5) continue;
				if (Math.hypot(x, y) > innerHeight / 2) continue;
				glides.get(el)?.cancel();
				glides.set(
					el,
					el.animate(
						{ translate: [`${own.x - x}px ${own.y - y}px`, "0px 0px"] },
						{ duration: ms, easing: "cubic-bezier(0.2, 0.7, 0.2, 1)" },
					),
				);
			}
			first = false;
			requestAnimationFrame(tick);
		};
		requestAnimationFrame(tick);
	}, { selector: selectors.join(", "), ms: GLIDE_MS });
}

/** Wait until the element `selector` names has finished gliding or fading in,
 * so a mark taken next frames it where it rests. The smoothing starts on the
 * frame after a layout change, so this waits a frame for it first. */
export async function settled(page: Page, selector: string): Promise<void> {
	await page.locator(selector).evaluate(async (el) => {
		await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
		// A glide that a newer move replaces is canceled, and its promise
		// rejects. The loop then waits on the one that replaced it. An
		// endless animation, such as a spinner, never finishes, so only
		// animations that end are waited on.
		const ending = () =>
			el.getAnimations({ subtree: true }).filter((a) => a.effect?.getComputedTiming().endTime !== Infinity);
		for (let running = ending(); running.length > 0; running = ending()) {
			await Promise.allSettled(running.map((a) => a.finished));
		}
	});
}
