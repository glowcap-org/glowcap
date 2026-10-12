/**
 * Glyphs. The small monochrome icons in toolbars, segmented controls,
 * and inline buttons. Each is a self-contained component marked
 * `aria-hidden`, so the surrounding button's `aria-label` or `title`
 * carries the name. Every glyph paints `currentColor`, which is how a
 * picture is lit exactly like the label it stands in for.
 *
 * The `*Glyph` suffix is so import sites read `<UndoGlyph />` rather
 * than the more ambiguous `<Undo />`.
 *
 * ## Drawn at the size it renders
 *
 * A glyph's viewBox equals its width and height, so one unit is one
 * pixel and every coordinate is a real position on the screen. Detail
 * this small has no room to survive a rescale: a 14-unit drawing run
 * out at 13 pixels puts every stroke a fourteenth of a pixel off its
 * grid, and the sun's two-pixel rays smudge into a ring.
 *
 * Two rules follow, one decision for the whole set:
 *
 * - Icon buttons draw at `ICON`, the square `.ocv-btn.is-icon` gives
 *   them. Tool-palette glyphs are smaller and carry their own size.
 * - One stroke weight across the set. A row of icons at mixed weights
 *   reads as uneven attention before it reads as icons.
 *
 * Keep detail to what survives at the size: parts closer together than
 * a stroke width merge, and a stroke shorter than it is wide is a dot.
 */

/** The stroke every icon-button glyph is drawn at. Heavy enough to
 *  hold together at 14 pixels, light enough that a folder does not
 *  fill in. The `<select>` chevron in styles.css matches it. */
const STROKE = 1.4;

/** The square an icon-button glyph is drawn in, in pixels, and its
 *  viewBox. Three pixels inside the button's own square on each side,
 *  which is the air left once `--ocv-control-h` came down to twenty. It
 *  does not follow that number: a redraw at 13 would put every stroke
 *  off the pixel grid, which costs more than the pixel of air gains. */
const ICON = 14;

/** Floppy disk, "save". The notch at the top doubles as the
 * write-protect tab. */
export function SaveGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M2 2 H10 L12 4 V12 H2 Z" />
			<path d="M4 2 V5 H9 V2" />
			<rect x="4" y="8" width="6" height="4" />
		</svg>
	);
}

/** Folder, open-from-file. */
/** New. A page with a plus, beside `FolderGlyph`'s page-in-a-tray. Same 14px
 *  box and 1.5 stroke as the rest of the cluster, so the three file actions read
 *  as one set. */
/**
 * Back to 100% and centered, a crosshair.
 *
 * A target rather than a frame, because `FitGlyph` below is the frame: four
 * corners mean "make everything fit", and this means "put the view back on the
 * middle at its true size". Two icons made of corners would be one icon wearing
 * two meanings.
 *
 * Not a circular arrow either. That says undo, and this does not undo anything,
 * the camera's position is not on the undo stack (`render/stage-view.ts`).
 */
export function RecenterGlyph() {
	return (
		<svg
			width="14"
			height="14"
			viewBox="0 0 14 14"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
			strokeLinejoin="round"
			aria-hidden="true"
		>
			<circle cx="7" cy="7" r="3.25" />
			<path d="M7 1.5v2M7 10.5v2M1.5 7h2M10.5 7h2" />
		</svg>
	);
}

/**
 * Fit, four corners with nothing between them.
 *
 * One glyph, two surfaces: the timeline fits the time window to its content, the
 * stage fits the camera to the picture. Same act on two axes, so the same mark,
 * and it lives here rather than in either panel because a second drawing of it is
 * how the two would come to disagree.
 *
 * Its own proportions rather than this file's usual 14: it was drawn for the
 * timeline's toolbar at 11 and reads as corners at that weight.
 */
export function FitGlyph() {
	return (
		<svg
			width="11"
			height="11"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.6"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<polyline points="2 4 2 2 4 2" />
			<polyline points="8 2 10 2 10 4" />
			<polyline points="10 8 10 10 8 10" />
			<polyline points="4 10 2 10 2 8" />
		</svg>
	);
}

export function NewDocGlyph() {
	return (
		<svg
			width="14"
			height="14"
			viewBox="0 0 14 14"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
			strokeLinejoin="round"
			aria-hidden="true"
		>
			<path d="M8 1.5H3.5v11H8" />
			<path d="M8 1.5 10.5 4v3" />
			<path d="M10.5 8.5v4M8.5 10.5h4" />
		</svg>
	);
}

export function FolderGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M1.5 4 H5.5 L7 5.5 H12.5 V11.5 H1.5 Z" />
		</svg>
	);
}

/** Curved arrow doubling back, undo. */
export function UndoGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M3 6 H9 a3 3 0 0 1 0 6 H6" />
			<polyline points="5 4 3 6 5 8" />
		</svg>
	);
}

/** Mirror of UndoGlyph, redo. */
export function RedoGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M11 6 H5 a3 3 0 0 0 0 6 H8" />
			<polyline points="9 4 11 6 9 8" />
		</svg>
	);
}

/**
 * Trash can, "delete". Lid, handle, tapered can, two slots.
 *
 * The slots run straight down: a lean of a fifth of a pixel reads as no
 * lean at all and greys both edges. The handle stands nearly three
 * pixels above the lid, because two leaves less daylight than the
 * stroke is wide and the tab fills in solid.
 */
export function TrashGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M1.8 4.2 H12.2" />
			<path d="M5.2 4.2 V1.5 H8.8 V4.2" />
			<path d="M2.9 4.2 L3.6 12.6 H10.4 L11.1 4.2" />
			<path d="M5.7 6.6 V10.6 M8.3 6.6 V10.6" />
		</svg>
	);
}

/**
 * Question mark, the reference.
 *
 * No ring around it. A circle this small leaves the mark inside it about
 * seven pixels tall, and at one-and-a-half pixels of stroke the hook closes
 * up into a blob. Drawn on its own the mark keeps its counter, and a question
 * mark alone still reads as help.
 */
export function HelpGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M4.3 4.6 a2.7 2.7 0 1 1 2.7 3.3 V9.3" />
			<circle
				cx="7"
				cy="11.7"
				r="0.75"
				fill="currentColor"
				stroke="none"
			/>
		</svg>
	);
}

/**
 * Cross, "clear this", the other half of the pin wherever a value can be a
 * reader's own: unpin a peer's position, clear an authored time, put the stage
 * back where the document opens.
 *
 * A drawing rather than the `×` character it replaces, for the reason at the top of
 * this file: a glyph set holds together at one stroke weight, and a multiplication
 * sign set in the UI face beside a filled pin is two weights in one row. It also
 * meant the mark had two forms, `×` in the code, `✕` in whatever was typed next,
 * and the two are different characters.
 */
export function ClearGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
		>
			<path d="M4.2 4.2 9.8 9.8M9.8 4.2 4.2 9.8" />
		</svg>
	);
}

/**
 * Pushpin, "pin this here", the authoring verb wherever a value can be a
 * reader's own rather than the app's: a peer's position in the Inspector, the view
 * a document opens at in the document panel. The ✕ beside it is the other half in
 * both places.
 *
 * The one filled glyph in the set, and the one drawn smaller than `ICON`. A pin is
 * a silhouette rather than an outline, drawn in strokes at this size the head and
 * the shaft merge, and a filled shape carries more ink than a stroked one at
 * equal size, so it is run out at eleven to weigh the same as its neighbours.
 * Its viewBox is twelve rather than eleven for the same reason the rest match
 * theirs: the shape was drawn on a twelve-unit grid, and redrawing it to match
 * would move every edge off a whole pixel.
 */
export function PinGlyph() {
	return (
		<svg
			width="11"
			height="11"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="currentColor"
		>
			<path d="M4 1h4v1.2l-.7.6v2.1l2.2 1.5V8H6.7v2.5L6 12l-.7-1.5V8H2.5V6.4l2.2-1.5V2.8L4 2.2z" />
		</svg>
	);
}

/** Crescent moon, switch to dark. Two arcs meeting at their tips,
 *  which reads as a moon where a bitten circle does not. */
export function MoonGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M12.25 7.46 A5.25 5.25 0 1 1 6.54 1.75 A4.08 4.08 0 0 0 12.25 7.46 z" />
		</svg>
	);
}

/**
 * Sun, switch to light. A filled disc with eight rays around it. The
 * disc is filled rather than stroked because a ring this small closes
 * up into a blob, and a blob with eight marks around it is not a sun.
 */
export function SunGlyph() {
	return (
		<svg
			width={ICON}
			height={ICON}
			viewBox="0 0 14 14"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth={STROKE}
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<circle cx="7" cy="7" r="2.3" fill="currentColor" stroke="none" />
			<path d="M7 3 V1 M7 11 V13 M3 7 H1 M11 7 H13" />
			<path d="M9.83 4.17 L11.24 2.76 M4.17 9.83 L2.76 11.24 M9.83 9.83 L11.24 11.24 M4.17 4.17 L2.76 2.76" />
		</svg>
	);
}

/** Open hand. The pan tool. Palm with four finger notches,
 * simplified to read at 12 px. */
export function HandGlyph() {
	return (
		<svg
			width="12"
			height="12"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.3"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<path d="M3.2 6.6 V2.8 a0.9 0.9 0 0 1 1.8 0 V5.4 M5 5.2 V1.9 a0.9 0.9 0 0 1 1.8 0 V5.2 M6.8 5.2 V2.4 a0.9 0.9 0 0 1 1.8 0 V6 M8.6 6 V4.2 a0.85 0.85 0 0 1 1.7 0 V7.4 a3.8 3.8 0 0 1 -3.8 3.8 H6 a3.4 3.4 0 0 1 -2.8 -1.6 L1.7 7.2 a0.9 0.9 0 0 1 1.5 -0.9 Z" />
		</svg>
	);
}

/** Tilted-arrow pointer. The "select" cursor. */
export function SelectGlyph() {
	return (
		<svg width="11" height="12" viewBox="0 0 11 12" aria-hidden="true">
			<path
				d="M1 1 L1 9.5 L3.4 7.4 L5.2 11 L6.7 10.4 L4.9 6.8 L8 6.8 Z"
				fill="currentColor"
				stroke="currentColor"
				strokeWidth="0.5"
				strokeLinejoin="round"
			/>
		</svg>
	);
}

/** Rounded square (echoing the peer body shape) with a "+", reads
 * as "place a new peer here." */
export function AddPeerGlyph() {
	return (
		<svg
			width="12"
			height="12"
			viewBox="0 0 12 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<rect x="1.5" y="1.5" width="9" height="9" rx="2" />
			<line x1="6" y1="4" x2="6" y2="8" />
			<line x1="4" y1="6" x2="8" y2="6" />
		</svg>
	);
}

/** Two dots connected by a line, "session edge between two peers." */
export function OpenSessionGlyph() {
	return (
		<svg
			width="14"
			height="12"
			viewBox="0 0 14 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
		>
			<line x1="3" y1="6" x2="11" y2="6" />
			<circle cx="3" cy="6" r="2" fill="currentColor" stroke="none" />
			<circle cx="11" cy="6" r="2" fill="currentColor" stroke="none" />
		</svg>
	);
}

/** Arrow-headed line, "message traveling from sender to receiver." */
export function SendMessageGlyph() {
	return (
		<svg
			width="14"
			height="12"
			viewBox="0 0 14 12"
			aria-hidden="true"
			fill="none"
			stroke="currentColor"
			strokeWidth="1.5"
			strokeLinecap="round"
			strokeLinejoin="round"
		>
			<line x1="2" y1="6" x2="11" y2="6" />
			<polyline points="8,3 11,6 8,9" />
		</svg>
	);
}
