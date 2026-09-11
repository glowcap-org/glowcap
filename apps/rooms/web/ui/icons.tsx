// ── Interface icons ────────────────────────────────────────────────────────
// The toolbar used to draw its controls with emoji. Emoji are pictures the
// platform owns, not glyphs this app can style: they arrive full-colour against
// a palette tuned to amber and teal, they sit on a different baseline in every
// font, and on a system with no emoji font they are empty boxes. These are
// plain strokes instead, so a control inherits the colour of the text around it
// and looks the same everywhere.
//
// Each path is drawn on a 24-unit grid and stroked, never filled, so one
// definition serves both themes and any size.

import { Mark } from "./Mark.tsx";

const paths = {
	moon: <path d="M20 14.2A8.2 8.2 0 0 1 9.8 4a8.4 8.4 0 1 0 10.2 10.2z" />,
	sun: (
		<>
			<circle cx="12" cy="12" r="4.2" />
			<path d="M12 2.6v2.1M12 19.3v2.1M4.3 4.3l1.5 1.5M18.2 18.2l1.5 1.5M2.6 12h2.1M19.3 12h2.1M4.3 19.7l1.5-1.5M18.2 5.8l1.5-1.5" />
		</>
	),
	bell: (
		<>
			<path d="M18 8.8a6 6 0 1 0-12 0c0 5.4-2 7-2 7h16s-2-1.6-2-7" />
			<path d="M13.7 19.4a2 2 0 0 1-3.4 0" />
		</>
	),
	// The muted bell keeps the same silhouette and takes a slash, so the two
	// states read as one control rather than two different pictures.
	bellOff: (
		<>
			<path d="M18 8.8a6 6 0 0 0-9.2-5.1M5.2 6.6A6 6 0 0 0 6 8.8c0 5.4-2 7-2 7h13" />
			<path d="M13.7 19.4a2 2 0 0 1-3.4 0" />
			<path d="M3.4 3.4l17.2 17.2" />
		</>
	),
	// A paperclip, drawn as the one open curve it is, so it reads at the same
	// weight as the emoji control beside it.
	clip: (
		<path d="M17.5 9.3l-7.1 7.1a3 3 0 0 1-4.2-4.2l8-8a4.6 4.6 0 0 1 6.5 6.5l-8.1 8.1a6.2 6.2 0 0 1-8.8-8.8l6.9-6.9" />
	),
	// A sheet with its corner turned, and a framed picture. These stand where
	// a file's name is shown, for the same reason every other control here is
	// a stroke rather than an emoji: an emoji is a picture the platform owns,
	// arriving full-colour against this palette or as an empty box.
	file: (
		<>
			<path d="M13.4 3.2H7a2 2 0 0 0-2 2v13.6a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8.8z" />
			<path d="M13.4 3.2v5.6H19" />
		</>
	),
	image: (
		<>
			<rect x="3.6" y="5" width="16.8" height="14" rx="2.2" />
			<circle cx="9" cy="10.2" r="1.5" />
			<path d="M4.4 16.6l4.3-4a1.8 1.8 0 0 1 2.4 0l4.8 4.4M14.2 14l1.8-1.6a1.8 1.8 0 0 1 2.4 0l1.2 1.1" />
		</>
	),
	// Downward into a tray: the one control that saves a file.
	download: (
		<>
			<path d="M12 3.6v10.8" />
			<path d="M7.8 10.6L12 14.8l4.2-4.2" />
			<path d="M4.6 17.2v1.6a1.6 1.6 0 0 0 1.6 1.6h11.6a1.6 1.6 0 0 0 1.6-1.6v-1.6" />
		</>
	),
	copy: (
		<>
			<rect x="8.2" y="8.2" width="11.2" height="11.2" rx="2" />
			<path d="M15.8 8.2V6.6a2 2 0 0 0-2-2H6.6a2 2 0 0 0-2 2v7.2a2 2 0 0 0 2 2h1.6" />
		</>
	),
	// What `copy` becomes for a moment once the clipboard has taken it. A tick at
	// the same stroke weight, on the same grid, so the control reads as the one
	// button answering rather than as a second button appearing.
	check: <path d="M5 12.6l4.6 4.6L19 7.4" />,
	// A circle with a cross: a notice that something did not happen. The same
	// grid and stroke as `check`, so success and failure sit as a pair.
	fail: (
		<>
			<circle cx="12" cy="12" r="8.6" />
			<path d="M8.4 8.4l7.2 7.2M15.6 8.4l-7.2 7.2" />
		</>
	),
	// A triangle with a mark: something that landed, and needs looking at,
	// without being a failure.
	warn: (
		<>
			<path d="M12 3.8L21.2 20.2H2.8z" />
			<path d="M12 9.4v5" />
			<path d="M12 16.8h.01" />
		</>
	),
	play: <path d="M8.2 5.2l10 6.8-10 6.8z" />,
	retry: (
		<>
			<path d="M19.2 8.2V3.8l-3 3" />
			<path d="M18.4 7.1A8 8 0 1 0 20 14.2" />
		</>
	),
	plus: <path d="M12 5v14M5 12h14" />,
	mention: (
		<>
			<circle cx="11.2" cy="12" r="3.4" />
			<path d="M14.6 12v1.4a2.5 2.5 0 0 0 5 0V12a8.2 8.2 0 1 0-2.8 6.2" />
		</>
	),

	smile: (
		<>
			<circle cx="12" cy="12" r="8.6" />
			<path d="M8.6 14.2a4.2 4.2 0 0 0 6.8 0" />
			<path d="M9.4 9.6h.01M14.6 9.6h.01" />
		</>
	),
	lock: (
		<>
			<rect x="4.6" y="10.4" width="14.8" height="10" rx="2.3" />
			<path d="M8.2 10.4V7.6a3.8 3.8 0 0 1 7.6 0v2.8" />
		</>
	),
	observer: (
		<>
			<path d="M2.8 12s3.4-6 9.2-6 9.2 6 9.2 6-3.4 6-9.2 6-9.2-6-9.2-6z" />
			<circle cx="12" cy="12" r="2.7" />
		</>
	),
	arrowDown: <path d="M12 4.6v14.8M6 13.4l6 6 6-6" />,
	send: (
		<>
			<path d="M12 19.4V5" />
			<path d="M6.4 10.6L12 5l5.6 5.6" />
		</>
	),
	close: <path d="M5.9 5.9l12.2 12.2M18.1 5.9L5.9 18.1" />,
	// Three dots in a row: everything else this thing can do, without naming any
	// one of them in the glyph. Filled rather than stroked, because a stroked
	// circle this small reads as a ring rather than a dot.
	more: (
		<>
			<circle cx="5.5" cy="12" r="1.6" fill="currentColor" stroke="none" />
			<circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none" />
			<circle cx="18.5" cy="12" r="1.6" fill="currentColor" stroke="none" />
		</>
	),
	// One closed pencil silhouette: changing what was written, with no baseline
	// or detached cap stroke that can read as a stray line at small sizes.
	pencil: <path d="M4.5 19.5l1.1-4.1L15.9 5.1a2.1 2.1 0 0 1 3 3L8.6 18.4z" />,
	// Four corners pulling outward: take this to full size.
	expand: (
		<>
			<path d="M9.4 3.8H3.8v5.6M14.6 3.8h5.6v5.6" />
			<path d="M9.4 20.2H3.8v-5.6M14.6 20.2h5.6v-5.6" />
		</>
	),
	// The pair of expand: four corners pulling inward, so a picture already at
	// its own size has a glyph that says "fit" rather than another expand.
	collapse: (
		<>
			<path d="M3.8 9.4H9.4V3.8M20.2 9.4H14.6V3.8" />
			<path d="M3.8 14.6H9.4V20.2M20.2 14.6H14.6V20.2" />
		</>
	),
	// The room's members: one figure in front, one behind. Two are enough to read
	// as a group at this size, and a third only muddies the silhouette.
	group: (
		<>
			<circle cx="9.4" cy="8.6" r="3.3" />
			<path d="M3.6 19.4a5.8 5.8 0 0 1 11.6 0" />
			<path d="M16.4 5.9a3.3 3.3 0 0 1 0 5.4" />
			<path d="M17.6 13.7a5.6 5.6 0 0 1 2.9 4.6" />
		</>
	),
	// A direct line: two endpoints joined with nothing in between. It marks a
	// conversation that was introduced by a room and now runs peer to peer.
	direct: (
		<>
			<circle cx="5.6" cy="12" r="2.4" />
			<circle cx="18.4" cy="12" r="2.4" />
			<path d="M8 12h8" />
		</>
	),
	// Settings: three sliders. A cog at this size reads as a blob; this stays
	// a control glyph next to the sun and the bell.
	// A directory, drawn as the two stacked bars of a rack. At the size the rail
	// uses it — under a room's sigil, a third of the height of the name beside it
	// — anything with an interior detail closes up, so this has none: two bars and
	// the space between them is the whole glyph, and it survives being small.
	directory: (
		<>
			<rect x="3.5" y="4.5" width="17" height="6" rx="2" />
			<rect x="3.5" y="13.5" width="17" height="6" rx="2" />
		</>
	),
	// A durable application session: one workspace surface with a command line,
	// distinct from the stacked server bars that identify a room directory.
	session: (
		<>
			<rect x="3.5" y="4.5" width="17" height="15" rx="2.2" />
			<path d="M3.5 8.5h17M7 12l2 2-2 2M12 16h4" />
		</>
	),
	// A funnel, for the rail's filter: a wide mouth narrowing to a spout, which
	// is the one glyph that says "less of this" rather than "find one of these".
	// A magnifier would promise a search across everything, and the rail's
	// filter only ever narrows the rows already in front of the reader.
	filter: <path d="M3.8 5.2h16.4l-6.4 7.4v5.6l-3.6 2.6v-8.2z" />,
	// A magnifier, for the operator's search. The funnel above says why this
	// glyph was refused there: it promises a search across everything, and the
	// rail's filter only narrows rows already in front of the reader. The
	// operator's search does ask the directory about everything it holds,
	// including the hundred thousand rows this page has not read, so here the
	// promise is the truth.
	search: (
		<>
			<circle cx="10.5" cy="10.5" r="5.8" />
			<path d="M14.8 14.8 20 20" />
		</>
	),
	gear: (
		<>
			<path d="M4 7h16M4 12h16M4 17h16" />
			<circle cx="8.2" cy="7" r="1.9" />
			<circle cx="15.8" cy="12" r="1.9" />
			<circle cx="10.4" cy="17" r="1.9" />
		</>
	),
	// A wrench, for the Operations page: the operator's hand on the server,
	// distinct from the gear that already means this page's own Settings.
	wrench: (
		<path d="M14.1 6.5a4 4 0 0 1 4.7-4l-2.5 2.5 2.7 2.7 2.5-2.5a4 4 0 0 1-5.1 4.6l-8.6 8.6a1.9 1.9 0 1 1-2.7-2.7l8.6-8.6z" />
	),
	// A mark of a question, in a circle: the same weight as sun and bell, so
	// Help sits with them in Settings rather than as a fourth tab of its own.
	help: (
		<>
			<circle cx="12" cy="12" r="8.6" />
			<path d="M9.6 9.4a2.5 2.5 0 1 1 3.3 2.3c-.9.4-1.3.9-1.3 1.8" />
			<path d="M12 16.7h.01" />
		</>
	),
} as const;

/** Every icon, plus the glowcap mark in its two readings here: `mark` is the
 * shader mushroom, which grows once and then stands, for the lockup on a
 * screen a person lands on; `mark-line` is the still line drawing, for a
 * control, where the mark is one glyph among others and should read as one. */
export type IconName = keyof typeof paths | "mark" | "mark-line";

/** Every glyph, in definition order, including both readings of the mark. */
export const iconNames: readonly IconName[] = [
	...(Object.keys(paths) as (keyof typeof paths)[]),
	"mark",
	"mark-line",
];

/** The logotype lockup — "glowcap" beside its small-caps rooms — as one
 * component so every home shares one structure; every metric lives on the
 * `.wordmark` class in ui/mark.css, where the lockup's pixel contract is owned.
 * (The boot screen in page.html carries the same two-element markup
 * statically, because it paints before this bundle arrives. The documentation
 * site header takes the same class without the product suffix.) */
export function Wordmark() {
	return (
		<span className="wordmark">
			<span>glowcap</span>
			<small>rooms</small>
		</span>
	);
}

/** One icon. Decorative by default: the control around it carries the accessible
 * name, so the icon itself is hidden from assistive software. */
export function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
	// A lockup's mark is not a glyph: it is the shader mushroom with its light
	// around it, drawn in a box of this size. It arrives rather than standing,
	// because the one screen that carries it is a screen a person lands on and
	// then reads, and the opening splash it follows is usually gone before the
	// mark there has drawn a frame. A control's mark is a glyph, and is drawn
	// as one, because a lit object standing among flat line icons reads as a
	// different kind of thing rather than as a richer one.
	if (name === "mark") return <Mark size={size} play="arrive" />;
	if (name === "mark-line") {
		return <span className="icon-svg mark-glyph" style={{ width: size, height: size }} aria-hidden="true" />;
	}
	return (
		<svg
			className="icon-svg"
			viewBox="0 0 24 24"
			width={size}
			height={size}
			fill="none"
			stroke="currentColor"
			strokeWidth="1.9"
			strokeLinecap="round"
			strokeLinejoin="round"
			aria-hidden="true"
		>
			{paths[name]}
		</svg>
	);
}
