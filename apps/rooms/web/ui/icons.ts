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

const paths: Record<string, string> = {
	moon: '<path d="M20 14.2A8.2 8.2 0 0 1 9.8 4a8.4 8.4 0 1 0 10.2 10.2z"/>',
	sun: '<circle cx="12" cy="12" r="4.2"/><path d="M12 2.6v2.1M12 19.3v2.1M4.3 4.3l1.5 1.5M18.2 18.2l1.5 1.5M2.6 12h2.1M19.3 12h2.1M4.3 19.7l1.5-1.5M18.2 5.8l1.5-1.5"/>',
	bell:
		'<path d="M18 8.8a6 6 0 1 0-12 0c0 5.4-2 7-2 7h16s-2-1.6-2-7"/><path d="M13.7 19.4a2 2 0 0 1-3.4 0"/>',
	// The muted bell keeps the same silhouette and takes a slash, so the two
	// states read as one control rather than two different pictures.
	bellOff:
		'<path d="M18 8.8a6 6 0 0 0-9.2-5.1M5.2 6.6A6 6 0 0 0 6 8.8c0 5.4-2 7-2 7h13"/><path d="M13.7 19.4a2 2 0 0 1-3.4 0"/><path d="M3.4 3.4l17.2 17.2"/>',
	smile:
		'<circle cx="12" cy="12" r="8.6"/><path d="M8.6 14.2a4.2 4.2 0 0 0 6.8 0"/><path d="M9.4 9.6h.01M14.6 9.6h.01"/>',
	lock:
		'<rect x="4.6" y="10.4" width="14.8" height="10" rx="2.3"/><path d="M8.2 10.4V7.6a3.8 3.8 0 0 1 7.6 0v2.8"/>',
	arrowDown: '<path d="M12 4.6v14.8M6 13.4l6 6 6-6"/>',
	close: '<path d="M5.9 5.9l12.2 12.2M18.1 5.9L5.9 18.1"/>',
	// The room's members: one figure in front, one behind. Two are enough to read
	// as a group at this size, and a third only muddies the silhouette.
	group:
		'<circle cx="9.4" cy="8.6" r="3.3"/><path d="M3.6 19.4a5.8 5.8 0 0 1 11.6 0"/><path d="M16.4 5.9a3.3 3.3 0 0 1 0 5.4"/><path d="M17.6 13.7a5.6 5.6 0 0 1 2.9 4.6"/>',
	// A direct line: two endpoints joined with nothing in between. It marks a
	// conversation that was introduced by a room and now runs peer to peer.
	direct:
		'<circle cx="5.6" cy="12" r="2.4"/><circle cx="18.4" cy="12" r="2.4"/><path d="M8 12h8"/>',
};

/** Build one icon element. Decorative by default: the control around it carries
 * the accessible name, so the icon itself is hidden from assistive software. */
export function icon(name: keyof typeof paths | string, size = 18): SVGSVGElement {
	const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
	svg.setAttribute("viewBox", "0 0 24 24");
	svg.setAttribute("width", String(size));
	svg.setAttribute("height", String(size));
	svg.setAttribute("fill", "none");
	svg.setAttribute("stroke", "currentColor");
	svg.setAttribute("stroke-width", "1.9");
	svg.setAttribute("stroke-linecap", "round");
	svg.setAttribute("stroke-linejoin", "round");
	svg.setAttribute("aria-hidden", "true");
	svg.classList.add("icon-svg");
	svg.innerHTML = paths[name] ?? "";
	return svg;
}

/** Replace an element's contents with one icon. */
export function setIcon(host: Element, name: string, size = 18) {
	host.replaceChildren(icon(name, size));
}
