// Whether a pointer is over open ground, where the mycelium may answer it,
// or over something on the page. live.ts asks on every pointer event, so the
// answer for the element under a resting pointer is kept briefly.

/// <reference lib="dom" />

/** What a reader can act on, even where it paints nothing. */
const INTERACTIVE = [
	"a, button, input, textarea, select, label, summary, [contenteditable]",
	"[role=button], [role=link], [role=tab], [role=menuitem], [role=option]",
	"[role=checkbox], [role=switch], [role=slider], [role=textbox], [tabindex]",
	// Pictures and media paint without a background.
	"img, svg, video, canvas, iframe, audio, object, embed",
].join(", ");

/** How long an answer about one element holds. The page can change under a
 * resting pointer, so an answer goes stale. */
const KEEP_MS = 150;

// The last element asked about, when, and its answer. A pointer moves over
// one element for many events in a row, so this saves the walk for most of
// them. The reference is weak, so a removed element is not held.
let last: { el: WeakRef<Element>; at: number; open: boolean } | null = null;

/** Whether a pointer over `target` is over open ground. Anything a reader
 * can act on, any text, and any surface that paints a background is the
 * page's. A layout box that paints nothing and holds no text of its own is
 * ground. */
export function onOpenGround(target: EventTarget | null): boolean {
	if (!(target instanceof Element)) return true;
	const now = performance.now();
	if (last !== null && last.el.deref() === target && now - last.at < KEEP_MS) return last.open;
	last = { el: new WeakRef(target), at: now, open: isOpen(target) };
	return last.open;
}

function isOpen(target: Element): boolean {
	if (target.closest(INTERACTIVE) !== null) return false;
	for (const node of target.childNodes) {
		if (node.nodeType === Node.TEXT_NODE && node.textContent?.trim()) return false;
	}
	const page: readonly Element[] = [document.body, document.documentElement];
	for (let el: Element | null = target; el !== null && !page.includes(el); el = el.parentElement) {
		const style = getComputedStyle(el);
		if (style.cursor === "pointer" || style.backgroundImage !== "none") return false;
		if (alphaOf(style.backgroundColor) > 0) return false;
	}
	return true;
}

/** The alpha of a computed color. Browsers write a color with no alpha as
 * `rgb(r, g, b)`, and one with alpha as `rgba(…)` or `color(… / a)`, where
 * `a` may be a percent. */
function alphaOf(color: string): number {
	if (color.startsWith("rgb(")) return 1;
	const match = color.match(/[,/]\s*([\d.]+)(%?)\)$/);
	if (match === null) return 1;
	return Number(match[1]) / (match[2] === "%" ? 100 : 1);
}
