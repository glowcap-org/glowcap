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
	arrowDown: <path d="M12 4.6v14.8M6 13.4l6 6 6-6" />,
	send: (
		<>
			<path d="M12 19.4V5" />
			<path d="M6.4 10.6L12 5l5.6 5.6" />
		</>
	),
	close: <path d="M5.9 5.9l12.2 12.2M18.1 5.9L5.9 18.1" />,
	// A nib over a line: changing what was written, rather than a page or a note,
	// which would read as composing something new.
	pencil: (
		<>
			<path d="M4 20h4.5L19.3 9.2a2.1 2.1 0 0 0-3-3L5.5 17z" />
			<path d="M14.8 4.7l4.5 4.5" />
		</>
	),
	// Four corners pulling outward: take this to full size.
	expand: (
		<>
			<path d="M9.4 3.8H3.8v5.6M14.6 3.8h5.6v5.6" />
			<path d="M9.4 20.2H3.8v-5.6M14.6 20.2h5.6v-5.6" />
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
	gear: (
		<>
			<path d="M4 7h16M4 12h16M4 17h16" />
			<circle cx="8.2" cy="7" r="1.9" />
			<circle cx="15.8" cy="12" r="1.9" />
			<circle cx="10.4" cy="17" r="1.9" />
		</>
	),
} as const;

export type IconName = keyof typeof paths | "mark";

/** One icon. Decorative by default: the control around it carries the accessible
 * name, so the icon itself is hidden from assistive software. */
export function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
	// The pancake silhouette is shared with the boot screen and the project site
	// through one mask token. Rendering that token here keeps the mark's geometry
	// authoritative without teaching IconButton about one exceptional glyph.
	if (name === "mark") {
		return (
			<span
				className="icon-svg icon-mark"
				style={{ width: size, height: size }}
				aria-hidden="true"
			/>
		);
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
