// How tall the message field is, and what the band's own box tells the page.
//
// One subject rather than two: the band's width is what re-wraps the field, and
// fitting the field is what changes the band's height. Both live here so the
// fitting has one owner.

import { type RefObject, useCallback, useLayoutEffect, useRef } from "react";

export function useComposerMeasure(
	{ field, band, draft, enabled, placeholder, onMeasured }: {
		/** The message box being fitted. */
		field: RefObject<HTMLTextAreaElement | null>;
		/** The band it sits in, whose measured height the page reads. */
		band: RefObject<HTMLDivElement | null>;
		/** What the box is showing: the draft when there is one, the placeholder
		 * when there is not, and whether it can be used at all. Each is a
		 * separate reason for the box to need a different height. */
		draft: string;
		enabled: boolean;
		placeholder: string;
		/** Run whenever the band has been measured, so whatever depends on its
		 * height can answer. */
		onMeasured: () => void;
	},
): void {
	// The cap is the stylesheet's `max-height`, read rather than repeated: two
	// copies of one number drift the moment either moves. It is read once and
	// remembered, because asking for it is a style recalculation and asking on
	// every character is one per keystroke.
	const cap = useRef(Infinity);
	/** Re-read the cap. One authority for the number, so the two places that
	 * could have seen it move cannot read it differently. */
	const remeasureCap = useCallback(() => {
		const box = field.current;
		if (box) cap.current = parseFloat(getComputedStyle(box).maxHeight) || Infinity;
	}, [field]);
	const fit = useCallback(() => {
		const box = field.current;
		if (!box) return;
		box.style.height = "auto";
		box.style.height = Math.min(box.scrollHeight, cap.current) + "px";
	}, [field]);

	// The placeholder is content too. A field that cannot be used carries the
	// reason as its placeholder, and those sentences are longer than any
	// addressee: left out of this list it is measured once, at whatever the
	// reason was when the field went quiet, and a later or longer one is cut off
	// inside a box still sized for the first.
	useLayoutEffect(() => {
		remeasureCap();
		fit();
	}, [draft, enabled, placeholder, fit, remeasureCap]);

	// The composer floats over the bottom of the message column, so the log has
	// to leave that much of itself clear, the fade has to be that tall, and the
	// jump-to-latest button has to sit above it. All three read one number, set
	// on the root so anything in the page can reach it. The band holds one height
	// at rest, because every row in it reserves its space, but a long
	// draft grows the field and the window can be resized under it, so the number
	// is measured rather than guessed.
	const fitted = useRef(0);
	useLayoutEffect(() => {
		const box = band.current;
		if (box === null) return;
		const observer = new ResizeObserver(() => {
			const bounds = box.getBoundingClientRect();
			// A narrower column re-wraps what the field already holds, and the
			// height measured at the old width no longer covers it: the last line a
			// reader needs is the one cut in half. Width alone is the trigger,
			// because fitting changes the band's height and answering that would
			// call this again. The cap is re-read here for the same reason it is
			// remembered rather than asked for on every keystroke: this is the
			// moment a media query could have moved it.
			if (bounds.width !== fitted.current) {
				fitted.current = bounds.width;
				remeasureCap();
				fit();
			}
			document.documentElement.style.setProperty("--composer-h", `${Math.round(bounds.height)}px`);
			onMeasured();
		});
		observer.observe(box);
		return () => observer.disconnect();
	}, [band, fit, remeasureCap, onMeasured]);
}
