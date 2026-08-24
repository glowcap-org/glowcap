/**
 * Design tokens.
 *
 * Colors live in styles.css as custom properties under `:root` (light)
 * and `[data-theme="dark"]` (dark). The `c` map below exposes them as
 * `var(--…)` strings, so an element styled inline rethemes with
 * everything else when `<html data-theme>` flips.
 *
 * Spacing, radius, type, and weights are theme-agnostic.
 */

export type Theme = "light" | "dark";

/** Read the theme from `<html data-theme>` per frame, so scenes react
 *  to a theme switch without prop-chaining. Returns `"light"` where
 *  there is no document. */
export function currentTheme(): Theme {
	if (typeof globalThis.document === "undefined") return "light";
	return globalThis.document.documentElement.dataset.theme === "dark" ? "dark" : "light";
}

/**
 * Colors, as references to the custom properties styles.css declares.
 * `c.text` evaluates to `--ocv-text` when the element renders.
 */
export const c = {
	surface: "var(--ocv-surface)",
	/** A group of fields inside a pane. A step above `surfaceMuted`, so
	 *  the chips that ride at `surfaceMuted` still read against it. */
	surfaceSubtle: "var(--ocv-surface-subtle)",
	surfaceMuted: "var(--ocv-surface-muted)",
	border: "var(--ocv-border)",
	borderStrong: "var(--ocv-border-strong)",
	divider: "var(--ocv-divider)",
	text: "var(--ocv-text)",
	textMuted: "var(--ocv-text-muted)",
	textSubtle: "var(--ocv-text-subtle)",
	accent: "var(--ocv-accent)",
	positive: "var(--ocv-positive)",
	positiveSoft: "var(--ocv-positive-soft)",
	warning: "var(--ocv-warning)",
	warningSoft: "var(--ocv-warning-soft)",
	danger: "var(--ocv-danger)",
	dangerSoft: "var(--ocv-danger-soft)",
} as const;

/**
 * The height every control stands at. `--ocv-control-h` in styles.css
 * is the value, and every class-styled control reads it from there;
 * this is for the few places that have to state it inline. They stand
 * in the same box instead of spelling a number of their own, which is
 * how the app came to have six control heights.
 */
export const CONTROL = {
	height: "var(--ocv-control-h)",
} as const;

/**
 * The class list a segmented cell wears: a button, joined into a row with its
 * neighbours, optionally the chosen one.
 *
 * Five surfaces wear the joined row: the mode switch, the timeline's lane
 * toggles, the payload viewer's view modes, the Reference's section picker, and
 * the stage's zoom controls. All five come through here, which is what lets one
 * rule about how a chosen cell is drawn hold for every one of them.
 * `segment-edges.test.ts` reads this function for that reason.
 *
 * The stage's is the one with nothing to choose — four actions, so it asks for
 * `false` every time. It comes through anyway rather than spelling the classes
 * itself, because what it wants is the row: the shared seams, the rounded outer
 * ends, and a focus mark that matches every other control. Hand-rolling those is
 * how it first arrived, and the hand-rolled container clipped its own focus
 * ring.
 */
export function segmentCellClass(active: boolean): string {
	return `ocv-btn ${SEGMENT_CELL}${active ? " is-active" : ""}`;
}

/**
 * What makes a control a cell of a segmented row: the shared seam, the rounded
 * outer ends, and the row's focus mark. `controls.css` names it on both control
 * families for that reason.
 *
 * Reachable on its own because it is a modifier rather than a family. A button
 * gets it through `segmentCellClass` above, which spells the family too. A control
 * that already brings its own family class adds only this: the stage's zoom is a
 * `ScrubInput`, so it is already `ocv-input is-numeric`, and being a cell of a row
 * is a second, independent thing about it.
 *
 * What it never carries is a chosen state. `segmentCellClass` takes a boolean
 * because one of a set of buttons is the answer; a value typed into a field is not
 * one of a set.
 */
export const SEGMENT_CELL = "is-segment";

/**
 * Spacing, by what the gap is doing rather than by how big it is:
 *
 *   xs  inside one thing — a glyph and its label, a swatch and its word
 *   sm  between siblings in a group
 *   md  a group's own inset — a section's padding, a panel's gutter
 *   lg  between groups
 *
 * The steps are geometric so a reader can tell them apart: every one is
 * at least half again the step below it. Arithmetic steps of four gave
 * a group's inset and the space between groups a ratio of 1.33, and at
 * that distance grouping stops reading as grouping.
 *
 * The three small steps are the tight ones, because those are the gaps
 * that repeat and accumulate. `lg` deliberately does not move: taking
 * the slack out of the small end while the large end holds is what
 * makes the interface denser AND its grouping stronger, where shrinking
 * everything together would only make the same layout harder to read.
 */
export const SPACE = {
	xs: 3,
	sm: 6,
	md: 10,
	lg: 16,
} as const;

export const RADIUS = {
	/** Small inset elements: swatches, chips, badges. */
	sm: 3,
	/** Anything that has to match a control's corner. `--ocv-control-r`
	 *  in styles.css is the value. */
	md: "var(--ocv-control-r)",
	pill: 999,
} as const;

/**
 * A panel: content sitting one step off the surface it is on.
 *
 * The one place that decision is made. Four surfaces had spelled it separately —
 * the Inspector's field groups, the Legend's groups, the Reference's row blocks,
 * and the selection notes — and two of the four were character-for-character the
 * same. A fifth would have been the document panel.
 *
 * `surfaceSubtle`, not `surfaceMuted`: the neutral chips a panel holds (a closed
 * session's badge, an idle activity dot) are themselves at `surfaceMuted`, so a
 * panel painted there makes them vanish into their own container.
 *
 * The inset is one step below the gap between panels, which is the whole argument
 * of the spacing scale: a group reads as a group when what is inside it sits
 * closer together than what is beside it.
 *
 * Composed, not copied. A panel that needs a different inset or a border says so
 * on top of this — `{ ...PANEL, border: … }` — so what every panel shares stays
 * one fact and each variant reads as the one thing it changes.
 */
export const PANEL = {
	background: c.surfaceSubtle,
	borderRadius: RADIUS.md,
	padding: SPACE.sm,
} as const;

export const FONT = {
	sans: "'Inter', 'Inter var', ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
	// Departure Mono is a bitmap-inspired pixel-grid monospace,
	// self-hosted; see the @font-face in styles.css. It ships Regular
	// only, so nothing may ask this family for bold. The face is hinted
	// for 11px increments, and a size off that grid renders softer.
	mono:
		"'Departure Mono', ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, 'Cascadia Mono', 'DejaVu Sans Mono', 'Liberation Mono', monospace",
} as const;

/**
 * Type sizes, one notch below a webpage's scale so the chrome reads as
 * a tool. Four sizes, and each has one job:
 *
 *   xs    9   the tracked uppercase eyebrow — section titles, field
 *             keys, legend labels. Never body text; the treatment is
 *             what makes it a level, not the size.
 *   sm   10   data — a field's value, a chip, a list row.
 *   base 11   chrome — control labels, buttons, fields. `.ocv-btn` in
 *             controls.css states the same 11 for class-styled controls.
 *   lg   13   a heading — the pane's entity title, the wordmark.
 *
 * There is no 12. Between 11 and 13 it is a step no reader can name,
 * and a scale whose neighbours are indistinguishable has levels only on
 * paper. What separates 9 from 10 is not the pixel either: it is that
 * one is uppercase and tracked and the other is not.
 *
 * `xs` is pinned at 9 by the timeline, which measures mono advances
 * against it (`ui/Timeline/gutter-paint.ts` and its siblings).
 */
export const SIZE = {
	xs: 9,
	sm: 10,
	base: 11,
	lg: 13,
} as const;

export const WEIGHT = {
	regular: 400,
	medium: 500,
	semibold: 600,
} as const;
