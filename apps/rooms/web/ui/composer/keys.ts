// The keys that format a selection, and what they wrap it in.
//
// The chords are the ones every chat client and editor has settled on: the
// command key with B, I, and E, and with Shift and X for striking out. Code is
// on E rather than the Shift-C some clients use, because Shift-C with the
// command key opens the browser's inspector in Chrome and a shortcut that
// sometimes does that is not a shortcut.
//
// Wrapping is a pure function of the text and the selection, held here so it
// can be tested without a textarea and read without one.

import { commandKeyApple, commandKeyControl } from "../../../lib/text/controls.ts";

/** The Markdown a chord wraps the selection in. */
export type Marker = "**" | "*" | "`" | "~~";

/** Whether the command key is ⌘: Apple hardware, including phones and tablets
 * with a keyboard attached. Everywhere else the command key is Ctrl. Read from
 * the platform rather than guessed from the modifier that arrived, so the
 * label the hint shows and the key the chord expects cannot disagree. */
export function isApple(): boolean {
	const platform = (navigator as { userAgentData?: { platform?: string } }).userAgentData?.platform ??
		navigator.platform ?? "";
	return /mac|iphone|ipad|ipod/i.test(platform);
}

/** How the hint spells the command key. */
export function modifierLabel(apple = isApple()): string {
	return apple ? commandKeyApple : commandKeyControl;
}

/** A key label with `mod` spelled for this machine. `mod+B` reads ⌘B on Apple
 * hardware, where the symbol carries the chord on its own, and Ctrl+B
 * elsewhere, where the plus is what says two keys are held together. A bare
 * `mod`, as the Help key list shows it, is the symbol or the word. */
export function keyLabel(key: string, apple = isApple()): string {
	const label = modifierLabel(apple);
	return key.replace("mod+", apple ? label : `${label}+`).replace(/^mod$/, label);
}

/** The marker a key press asks for, or null when it is not a formatting chord. */
export function markerFor(
	press: { key: string; metaKey: boolean; ctrlKey: boolean; shiftKey: boolean; altKey: boolean },
	apple = isApple(),
): Marker | null {
	const command = apple ? press.metaKey && !press.ctrlKey : press.ctrlKey && !press.metaKey;
	if (!command || press.altKey) return null;
	const key = press.key.toLowerCase();
	if (!press.shiftKey && key === "b") return "**";
	if (!press.shiftKey && key === "i") return "*";
	if (!press.shiftKey && key === "e") return "`";
	if (press.shiftKey && key === "x") return "~~";
	return null;
}

/** The text with the selection wrapped in `marker`, and where the selection
 * lands afterwards. Pressing the same chord on a selection already wrapped
 * takes the wrapping off, whether the markers sit just outside the selection
 * or inside it, so the chord toggles the way a bold button does. An empty
 * selection gets the pair with the caret between them, ready to type into. */
export function wrapSelection(
	text: string,
	start: number,
	end: number,
	marker: Marker,
): { text: string; start: number; end: number } {
	const size = marker.length;
	const before = text.slice(0, start);
	const inside = text.slice(start, end);
	const after = text.slice(end);
	if (before.endsWith(marker) && after.startsWith(marker)) {
		return { text: before.slice(0, -size) + inside + after.slice(size), start: start - size, end: end - size };
	}
	if (inside.length >= 2 * size && inside.startsWith(marker) && inside.endsWith(marker)) {
		return { text: before + inside.slice(size, -size) + after, start, end: end - 2 * size };
	}
	return { text: before + marker + inside + marker + after, start: start + size, end: end + size };
}
