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

import {
	createContext,
	createElement,
	type ReactNode,
	type RefObject,
	useCallback,
	useContext,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
	useSyncExternalStore,
} from "react";

interface ModalCoordinator {
	readonly nextOpener: RefObject<HTMLElement | null>;
	readonly deferredFocus: RefObject<HTMLElement | null>;
	openFrom(opener: HTMLElement, open: () => void): void;
	push(layer: HTMLDialogElement): void;
	drop(layer: HTMLDialogElement): void;
	top(): HTMLDialogElement | null;
	subscribe(changed: () => void): () => void;
}

const ModalContext = createContext<ModalCoordinator | null>(null);

function useModalCoordinator(): ModalCoordinator {
	const coordinator = useContext(ModalContext);
	if (coordinator === null) throw new Error("a Rooms modal was rendered outside its provider");
	return coordinator;
}

/** One modal/focus owner per rendered Rooms application. Native dialogs are a
 * stack by show order, which is runtime state rather than DOM order. */
export function ModalProvider({ children }: { children: ReactNode }) {
	const nextOpener = useRef<HTMLElement | null>(null);
	const deferredFocus = useRef<HTMLElement | null>(null);
	const stack = useRef<HTMLDialogElement[]>([]);
	const listeners = useRef(new Set<() => void>());
	const changed = useCallback(() => listeners.current.forEach((listener) => listener()), []);
	const top = useCallback(() => {
		while (stack.current.length > 0) {
			const layer = stack.current[stack.current.length - 1];
			if (layer?.isConnected && layer.open && !layer.inert) return layer;
			stack.current.pop();
		}
		return null;
	}, []);
	const coordinator = useMemo<ModalCoordinator>(() => ({
		nextOpener,
		deferredFocus,
		openFrom: (opener, open) => {
			nextOpener.current = opener;
			try {
				open();
			} catch (error) {
				nextOpener.current = null;
				throw error;
			}
		},
		push: (layer) => {
			const prior = stack.current.indexOf(layer);
			if (prior >= 0) stack.current.splice(prior, 1);
			stack.current.push(layer);
			changed();
		},
		drop: (layer) => {
			const prior = stack.current.indexOf(layer);
			if (prior >= 0) stack.current.splice(prior, 1);
			changed();
		},
		top,
		subscribe: (listener) => {
			listeners.current.add(listener);
			return () => listeners.current.delete(listener);
		},
	}), [changed, top]);
	useEffect(() => () => {
		nextOpener.current = null;
		deferredFocus.current = null;
		stack.current.length = 0;
		listeners.current.clear();
	}, []);
	return createElement(ModalContext.Provider, { value: coordinator }, children);
}

/** Open a nested modal with the exact control focus must return to. */
export function useOpenModal(): ModalCoordinator["openFrom"] {
	return useModalCoordinator().openFrom;
}

export function useTopModalLayer(): HTMLDialogElement | null {
	const coordinator = useModalCoordinator();
	return useSyncExternalStore(coordinator.subscribe, coordinator.top, () => null);
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
	const coordinator = useModalCoordinator();
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
				const requested = coordinator.nextOpener.current;
				if (requested?.isConnected) {
					openerRef.current = requested;
					coordinator.nextOpener.current = null;
				} else {
					coordinator.nextOpener.current = null;
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
			coordinator.push(layer);
			const deferred = coordinator.deferredFocus.current;
			if (deferred !== null && !deferred.isConnected) coordinator.deferredFocus.current = null;
			if (deferred !== null && deferred.isConnected && layer.contains(deferred)) {
				deferred.focus();
				if (document.activeElement === deferred) coordinator.deferredFocus.current = null;
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
			if (document.activeElement !== opener) coordinator.deferredFocus.current = opener;
		};
		if (retain) {
			layer.inert = true;
			if (layer.open) layer.close();
			coordinator.drop(layer);
			return;
		}
		if (!layer.open) {
			layer.inert = true;
			coordinator.drop(layer);
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
			coordinator.drop(layer);
			restore();
			openerRef.current = null;
			exitedRef.current();
		};
		layer.addEventListener("transitionend", finish);
		layer.inert = true;
		layer.close();
		coordinator.drop(layer);
		const failsafe = setTimeout(() => finish(), 280);
		return () => {
			clearTimeout(failsafe);
			layer.removeEventListener("transitionend", finish);
			if (!finished) {
				if (layer.open) layer.close();
				coordinator.drop(layer);
				restore();
				openerRef.current = null;
				exitedRef.current();
			}
		};
	}, [coordinator, dialog, initialFocus, open, retain]);
}
