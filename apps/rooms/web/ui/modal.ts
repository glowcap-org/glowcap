// The lifecycle shared by every native modal in rooms.
//
// Presentation stays with the caller: Settings is a paper form and the media
// viewer is an edge-to-edge stage. Modality does not vary with presentation,
// so the browser owns it once here: `showModal` makes the covered application
// inert and contains focus, Escape and a press on the dim around the panel
// become the caller's close verb, and focus returns to the control that opened
// the layer. A form focuses its first field or tab. A layer that is only
// something to read or dismiss focuses Close.
//
// Closing used to drop `[open]` in the same frame as the press, which is why
// the sheets could only animate in. The element stays mounted until the exit
// transition finishes (`useHeldModal`), and `close()` plus `allow-discrete`
// display/overlay is what the CSS reverse rides. `retain` keeps Settings in
// the tree while Help has the top layer, so the opener that opened Settings
// is still the one Escape returns to.

import { type RefObject, useCallback, useLayoutEffect, useRef, useState } from "react";

// A nested modal can close back onto a retained-but-closed parent. Focusing its
// opener while that parent is inert cannot land, so keep the exact element and
// let the parent consume it after it becomes modal again. One slot is enough:
// native modal layers are a stack, and only its top can be closing.
let deferredModalFocus: HTMLElement | null = null;
let nextModalOpener: HTMLElement | null = null;

/** Open a nested modal with an exact focus-return target. Capturing the active
 * element later in a layout effect is too late: its parent dialog may already
 * have closed and returned focus somewhere else. */
export function openModalFrom(opener: HTMLElement, open: () => void): void {
	nextModalOpener = opener;
	try {
		open();
	} catch (error) {
		nextModalOpener = null;
		throw error;
	}
}

/** Keep a modal's tree mounted through its close transition. `retain` keeps it
 * mounted while another dialog has the top layer (Help over Settings). */
export function useHeldModal(open: boolean, retain = false): {
	held: boolean;
	onExited: () => void;
} {
	const [held, setHeld] = useState(open);
	useLayoutEffect(() => {
		if (open || retain) setHeld(true);
	}, [open, retain]);
	const onExited = useCallback(() => setHeld(false), []);
	return { held: open || retain || held, onExited };
}

export function useModalDialog(
	dialog: RefObject<HTMLDialogElement | null>,
	dismiss: () => void,
	initialFocus: RefObject<HTMLElement | null> | undefined,
	open: boolean,
	onExited: () => void,
	retain = false,
): void {
	const dismissRef = useRef(dismiss);
	dismissRef.current = dismiss;
	const exitedRef = useRef(onExited);
	exitedRef.current = onExited;
	const openerRef = useRef<HTMLElement | null>(null);

	useLayoutEffect(() => {
		const layer = dialog.current;
		if (layer === null) return;
		if (open) {
			if (openerRef.current == null || !openerRef.current.isConnected) {
				const requested = nextModalOpener;
				if (requested?.isConnected) {
					openerRef.current = requested;
					nextModalOpener = null;
				} else {
					nextModalOpener = null;
					openerRef.current = document.activeElement instanceof HTMLElement ? document.activeElement : null;
				}
			}
			const cancel = (event: Event) => {
				event.preventDefault();
				dismissRef.current();
			};
			const backdrop = (event: MouseEvent) => {
				if (event.target === layer) dismissRef.current();
			};
			layer.addEventListener("cancel", cancel);
			layer.addEventListener("click", backdrop);
			layer.inert = false;
			if (!layer.open) layer.showModal();
			const deferred = deferredModalFocus;
			if (deferred !== null && !deferred.isConnected) deferredModalFocus = null;
			if (deferred !== null && deferred.isConnected && layer.contains(deferred)) {
				deferred.focus();
				if (document.activeElement === deferred) deferredModalFocus = null;
			} else {
				initialFocus?.current?.focus();
			}
			return () => {
				layer.removeEventListener("cancel", cancel);
				layer.removeEventListener("click", backdrop);
			};
		}
		const restore = () => {
			const opener = openerRef.current;
			if (!opener?.isConnected) return;
			opener.focus();
			if (document.activeElement !== opener) deferredModalFocus = opener;
		};
		if (retain) {
			layer.inert = true;
			if (layer.open) layer.close();
			return;
		}
		if (!layer.open) {
			layer.inert = true;
			restore();
			openerRef.current = null;
			exitedRef.current();
			return;
		}
		let finished = false;
		const finish = (event?: Event) => {
			if (finished) return;
			if (event != null && event.target !== layer) return;
			if (
				event instanceof TransitionEvent &&
				event.propertyName !== "opacity" &&
				event.propertyName !== "overlay"
			) return;
			finished = true;
			clearTimeout(failsafe);
			layer.removeEventListener("transitionend", finish);
			if (layer.open) layer.close();
			restore();
			openerRef.current = null;
			exitedRef.current();
		};
		layer.addEventListener("transitionend", finish);
		layer.inert = true;
		layer.close();
		const failsafe = setTimeout(() => finish(), 280);
		return () => {
			clearTimeout(failsafe);
			layer.removeEventListener("transitionend", finish);
			if (!finished) {
				if (layer.open) layer.close();
				restore();
				openerRef.current = null;
				exitedRef.current();
			}
		};
	}, [dialog, initialFocus, open, retain]);
}
