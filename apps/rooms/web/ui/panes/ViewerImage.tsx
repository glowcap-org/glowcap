// A picture on the stage: fitted, or at actual size with native scrolling.
//
// Two sizes are enough. Fitted shows the whole picture, as large as the stage
// allows and never larger than the file; actual size is one file pixel per
// CSS pixel, scrolled natively when it runs past the stage. Clicking the
// picture toggles between the two around the point clicked, the bar's zoom
// button does the same without a pointer, and clicking the stage around the
// picture leaves. Free zoom and drag panning are not offered: they are a mode
// a reader has to manage, and scrolling is the gesture they already have.

import { useCallback, useLayoutEffect, useRef } from "react";

export function ViewerImage(
	{ src, alt, actual, oversized, onMeasure, onGutter, onToggle, onBackdrop }: {
		src: string;
		alt: string;
		/** Actual size (scrolling) rather than fitted. Owned by the viewer, so
		 * the bar's zoom button and this stage cannot disagree. */
		actual: boolean;
		/** Whether the file has more pixels than the fitted stage shows — the
		 * one condition under which actual size is a different picture. */
		oversized: boolean;
		/** Report `oversized`, measured here because the stage is here; the
		 * viewer keeps the answer beside the button that depends on it. */
		onMeasure: (oversized: boolean) => void;
		/** How much width this stage's own scrollbar takes, measured for the
		 * same reason. Nought where scrollbars float over the content. */
		onGutter: (px: number) => void;
		onToggle: () => void;
		onBackdrop: () => void;
	},
) {
	const stage = useRef<HTMLDivElement>(null);
	const img = useRef<HTMLImageElement>(null);
	/** Where in the picture the toggle was aimed, as fractions of its size, so
	 * the point under the pointer is the point actual size centers on. */
	const aim = useRef<{ x: number; y: number } | null>(null);

	/** What the scrollbar takes out of this stage's width. A classic scrollbar
	 * is laid out inside the border box and answers here with its width; one
	 * that floats over the content takes none and answers nought. The bar
	 * across the top is fixed over this column and stops short by whatever
	 * this says. */
	// Both are held across renders so the effects below can name them among the
	// things they depend on. Each moves only when the answer it reports to moves,
	// and the stage's own refs are stable, so a picture is measured when the
	// picture or the size changes rather than on every repaint of the viewer
	// around it.
	const reportGutter = useCallback(() => {
		const box = stage.current;
		if (box != null) onGutter(box.offsetWidth - box.clientWidth);
	}, [onGutter]);

	const measure = useCallback(() => {
		const box = stage.current;
		const pic = img.current;
		if (box == null || pic == null || pic.naturalWidth === 0) return;
		const style = getComputedStyle(box);
		const width = box.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
		const height = box.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom);
		onMeasure(pic.naturalWidth > width + 1 || pic.naturalHeight > height + 1);
	}, [onMeasure]);

	useLayoutEffect(() => {
		measure();
		reportGutter();
		const box = stage.current;
		if (box == null) return;
		const watch = new ResizeObserver(() => {
			measure();
			reportGutter();
		});
		watch.observe(box);
		return () => watch.disconnect();
	}, [src, measure, reportGutter]);

	// Entering actual size, put the aimed point (or the middle) in the middle
	// of the stage. Native scroll owns the position from then on.
	useLayoutEffect(() => {
		// Whether this stage scrolls at all is what actual size decides, so the
		// gutter is answered again here rather than waiting for a resize.
		reportGutter();
		const box = stage.current;
		const pic = img.current;
		if (!actual || box == null || pic == null) return;
		const at = aim.current ?? { x: 0.5, y: 0.5 };
		aim.current = null;
		box.scrollTo({
			left: pic.offsetLeft + at.x * pic.clientWidth - box.clientWidth / 2,
			top: pic.offsetTop + at.y * pic.clientHeight - box.clientHeight / 2,
		});
	}, [actual, reportGutter]);

	return (
		<div
			ref={stage}
			className={"viewer-stage viewer-image" + (actual ? " is-actual" : "") + (oversized ? " is-oversized" : "")}
			onClick={(event) => {
				const pic = img.current;
				if (event.target !== pic) {
					// A press on this stage's own scrollbar arrives as a click on
					// the stage, so leaving on every click that missed the picture
					// would dismiss the viewer the moment somebody reached for the
					// thumb. A scrollbar with layout width is drawn past the client
					// box, so a point beyond it is on one and belongs to the
					// browser. Where scrollbars float over the content there is no
					// such point and this never fires.
					const box = stage.current;
					if (
						box != null && event.target === box &&
						(event.nativeEvent.offsetX > box.clientWidth ||
							event.nativeEvent.offsetY > box.clientHeight)
					) return;
					onBackdrop();
					return;
				}
				// A picture already at its own size has no other size to show.
				if (!oversized && !actual) return;
				if (pic != null && !actual) {
					const rect = pic.getBoundingClientRect();
					aim.current = {
						x: (event.clientX - rect.left) / rect.width,
						y: (event.clientY - rect.top) / rect.height,
					};
				}
				onToggle();
			}}
		>
			<img ref={img} src={src} alt={alt} draggable={false} onLoad={measure} />
		</div>
	);
}
