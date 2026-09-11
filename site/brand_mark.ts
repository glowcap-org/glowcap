// The site's one shader mark: the home page's hero.
//
// The mark is drawn three ways across this project, and which one a place gets
// is decided by what the mark is doing there. As an object, saying whose page
// this is, it is the still artwork: the tab icon, the header and footer
// lockups. As a glyph among other glyphs, it is the line drawing. As a
// performance it is the shader, and the shader runs only where it is large
// enough to be worth a device and where arriving is the point. On this site
// that is one place.
//
// The hero arrives: the whole cycle once as the page opens, and then a lockup
// that answers the pointer. The still artwork in the template is what every
// browser gets first, and what a browser with no WebGPU keeps.
//
// `zig build site` bundles this file to site/assets/mark.js, which the
// template links as a module. Generated, never committed.

/// <reference lib="dom" />

import { type MarkPlay, start } from "../apps/rooms/web/ui/mark_gpu_live.ts";

for (const home of document.querySelectorAll<HTMLElement>(".hero-mark")) {
	const host = home.querySelector<HTMLElement>(".mark-live");
	if (host === null) continue;
	// The template names the play, so a second home can ask for a different
	// one without this file learning about it.
	const play = (home.dataset.markPlay as MarkPlay | undefined) ?? "arrive";
	void start(host, play).then((mark) => {
		if (mark !== null) home.classList.add("mark-shaded");
	});
}
