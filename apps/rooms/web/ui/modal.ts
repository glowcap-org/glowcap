// The lifecycle shared by every native modal in rooms.
//
// Presentation stays with the caller: Settings is a paper form and the media
// viewer is an edge-to-edge stage. Modality does not vary with presentation,
// so the browser owns it once here: `showModal` makes the covered application
// inert and contains focus, Escape becomes the caller's close verb, and focus
// returns to the control that opened the layer.

import { type RefObject, useLayoutEffect, useRef } from "react";

export function useModalDialog(
	dialog: RefObject<HTMLDialogElement | null>,
	dismiss: () => void,
	initialFocus?: RefObject<HTMLElement | null>,
): void {
	const dismissRef = useRef(dismiss);
	dismissRef.current = dismiss;

	useLayoutEffect(() => {
		const layer = dialog.current;
		if (layer === null) return;
		const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
		const cancel = (event: Event) => {
			event.preventDefault();
			dismissRef.current();
		};

		layer.addEventListener("cancel", cancel);
		layer.showModal();
		initialFocus?.current?.focus();

		return () => {
			layer.removeEventListener("cancel", cancel);
			if (layer.open) layer.close();
			queueMicrotask(() => {
				if (opener?.isConnected) opener.focus();
			});
		};
	}, [dialog, initialFocus]);
}
