// A menu that opens off a control, and the two rules a reader expects of one.
//
// The behaviour is the same wherever a menu appears (it closes when you press
// somewhere else or press Escape, it is walked with the arrows, and the first
// row has the keyboard when it opens) and it is the part that is easy to get
// subtly wrong twice. What differs between menus is where they sit and what is
// in them, so that stays with each of them.
//
// The roles are a promise about all of that: software that announces a menu
// tells its reader it is one, and a reader who is told so reaches for the
// arrows. Tab still leaves, as a reader who was not told will try.

import { type ReactNode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useTopModalLayer } from "./modal.ts";
import { Icon, type IconName } from "./icons.tsx";

/** Open state and the wiring that closes it, for one menu.
 *
 * `holder` goes on the element that contains both the control and the menu, so
 * a press inside it, including on the control itself, is not "somewhere
 * else". `trigger` goes on the control, so Escape hands the keyboard back to
 * what a reader opened it with rather than dropping it at the top of the page.
 * `layer` goes to `MenuLayer`, which is where the menu itself ends up: it is
 * drawn somewhere else in the document, so "inside" is two places rather than
 * one and a press on a row would otherwise read as a press elsewhere and take
 * the row away before it could be pressed. */
export function useMenu(): {
	open: boolean;
	setOpen: (open: boolean | ((was: boolean) => boolean)) => void;
	holder: { current: HTMLDivElement | null };
	trigger: { current: HTMLButtonElement | null };
	layer: { current: HTMLDivElement | null };
} {
	const [open, setOpen] = useState(false);
	const holder = useRef<HTMLDivElement>(null);
	const trigger = useRef<HTMLButtonElement>(null);
	const layer = useRef<HTMLDivElement>(null);
	useEffect(() => {
		if (!open) return;
		const outside = (event: MouseEvent) => {
			const at = event.target as Node;
			if (holder.current?.contains(at) === true || layer.current?.contains(at) === true) return;
			setOpen(false);
		};
		const key = (event: KeyboardEvent) => {
			if (event.key !== "Escape") return;
			// Stopped here: the same key closes a dialog and leaves a conversation,
			// and a reader closing a menu means the menu.
			event.stopPropagation();
			setOpen(false);
			trigger.current?.focus();
		};
		document.addEventListener("mousedown", outside);
		document.addEventListener("keydown", key);
		return () => {
			document.removeEventListener("mousedown", outside);
			document.removeEventListener("keydown", key);
		};
	}, [open]);
	return { open, setOpen, holder, trigger, layer };
}

/** The layer a menu opens into, so nothing above it can cut it off.
 *
 * A menu hangs below the control that opened it and is routinely taller than
 * the card holding that control. Drawn in place, every such card would have
 * to promise never to clip. That is backwards: it makes a card's overflow depend
 * on what somebody put inside it. `popover` promotes an element to the browser's
 * top layer, above every ancestor's clipping and above an open dialog, and it
 * does so without moving the element in the document. So a press inside the
 * menu is still a press inside the holder, and closing on a press elsewhere
 * needs no second answer about where the menu went.
 *
 * What it costs is a containing block. The top layer is laid out against the
 * viewport, so a menu written as `top: calc(100% + 6px); right: 0` would resolve
 * those against the screen rather than against the control. This box is that
 * missing block: it stands exactly where the holder stands, so every menu keeps
 * saying where it sits in its own stylesheet and none of them had to be
 * rewritten in coordinates. It is kept over the holder while it is open,
 * because a page that scrolls under a menu would otherwise leave it behind.
 *
 * It passes presses through. The box covers the control that opened it, and a
 * layer that swallowed the second press would make a menu impossible to close
 * by pressing the same button again.
 *
 * `popover` rather than `position: fixed` alone, measured rather than assumed.
 * A fixed box already escapes an ancestor's `overflow: hidden`, so on a plain
 * card the two are indistinguishable: the first harness written for this
 * reported success for both and was therefore reporting nothing. What separates
 * them is an ancestor that creates a containing block: give one a `transform`
 * and the fixed box is clipped by it and lands at the wrong coordinates, while
 * the popover is unmoved. That is not a hypothetical here, because a card's
 * entrance animation is a transform, and a menu opened while one runs would be
 * the case nobody could reproduce afterwards. */
export function MenuLayer(
	{ holder, anchor, layer: box, owner, className, children }: {
		holder: { current: HTMLElement | null };
		/** The box the layer stands over, when that is not the holder. A menu
		 * usually hangs off the control that opened it, so the holder is both
		 * the "inside" for a press and the rectangle to measure from. The rail's
		 * filter is the exception: its control is a heading a few words wide,
		 * and its panel spans the section that heading labels, so the section's
		 * head is what the panel is measured against while the heading stays
		 * what a press has to land inside. Without this the panel's own
		 * `left: 0; right: 0` resolved against the words, and every question
		 * in it was cut to the width of "Your rooms". */
		anchor?: { current: HTMLElement | null };
		layer: { current: HTMLDivElement | null };
		/** What this menu is, for the rules that place it. Drawn in the top
		 * layer, a menu sits inside none of the things that opened it (a message
		 * from somebody else, the rail's foot), so what it is has to travel with it rather than be read off its
		 * surroundings. */
		className?: string;
		/** The id of the panel this menu belongs to, for a surface that decides
		 * what to dismiss by asking which elements a press passed through. Drawn
		 * in the top layer, this menu is off that path, so it says whose it is
		 * and the panel can name it. Named rather than blanket, because two
		 * things can be open at once and a press in one menu is not a press
		 * inside every panel. */
		owner?: string;
		children: ReactNode;
	},
) {
	// Where it lands: the dialog on top when there is one, so an open modal's
	// inertness does not reach it, and the end of the document otherwise.
	const host = useTopModalLayer();
	useLayoutEffect(() => {
		const layer = box.current;
		const host = anchor?.current ?? holder.current;
		if (layer === null || host === null) return;
		const place = () => {
			const at = host.getBoundingClientRect();
			// A box of no size is not a position. An element that has been hidden
			// or taken out of the document measures 0,0,0,0, and the observer below
			// reports exactly that as a resize, so believing it would send the menu
			// to the corner of the page. Keep the last place the host had instead.
			if (at.width === 0 && at.height === 0) return;
			layer.style.top = `${at.top}px`;
			layer.style.left = `${at.left}px`;
			layer.style.width = `${at.width}px`;
			layer.style.height = `${at.height}px`;
		};
		place();
		layer.showPopover();
		// Capture, because the scroll that moves the control is a scroll inside
		// some box on the way up rather than the document's own.
		globalThis.addEventListener("scroll", place, true);
		globalThis.addEventListener("resize", place);
		const watching = new ResizeObserver(place);
		watching.observe(host);
		return () => {
			globalThis.removeEventListener("scroll", place, true);
			globalThis.removeEventListener("resize", place);
			watching.disconnect();
		};
	}, [holder, anchor, box, host]);
	// Rendered outside where it was written. The top layer settles what is drawn
	// over what, but not what a scroll reaches: a menu left inside the log is
	// still a row of that log to anything asking the page to bring it into view,
	// so scrolling to a menu row scrolled the conversation, which moved the
	// control, which moved the menu out from under the press that asked for it.
	//
	// Out of the scroller, but not out of an open dialog. A modal dialog makes
	// the whole document outside itself inert, and inert is not a paint rule: a
	// menu sent to the end of the document from inside a modal is drawn exactly
	// where it belongs, on top, and takes no press at all. `Toast` learned this
	// first and answers it the same way. */
	return createPortal(
		<div
			className={className === undefined ? "menu-layer" : `menu-layer ${className}`}
			popover="manual"
			ref={box}
			data-menu-in={owner}
		>
			{children}
		</div>,
		host ?? document.body,
	);
}

/** The menu itself: the rows, walked with the arrows. */
export function MenuList({ className, children }: { className: string; children: ReactNode }) {
	return (
		<div
			className={className}
			role="menu"
			onKeyDown={(event) => {
				if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
				event.preventDefault();
				// Both row roles: a menu that performs actions and a menu that
				// chooses between states are walked the same way, and asking for
				// only the first left the arrows dead in the second.
				const rows = [
					...event.currentTarget.querySelectorAll<HTMLButtonElement>(
						"[role=menuitem], [role=menuitemradio]",
					),
				];
				const at = rows.indexOf(document.activeElement as HTMLButtonElement);
				const step = event.key === "ArrowDown" ? 1 : rows.length - 1;
				rows[(Math.max(at, 0) + step) % rows.length]?.focus();
			}}
		>
			{children}
		</div>
	);
}

/** One row. `first` takes the keyboard as the menu opens, so the arrows have
 * somewhere to start. Exactly one row in a menu should ask for it.
 *
 * As the menu opens, and never again. A ref callback runs on every render, and
 * a menu holding a field re-renders on every keystroke. So focusing from one
 * took the keyboard back off the reader mid-word, once per character. */
export function MenuRow(
	{ icon, className, first, marked, disabled, onPick, children }: {
		icon?: IconName;
		className: string;
		first?: boolean;
		/** Whether this row is the answer in force, for a menu that is choosing
		 * between states rather than performing actions. */
		marked?: boolean;
		/** The row's act is already running. */
		disabled?: boolean;
		onPick: () => void;
		children: ReactNode;
	},
) {
	const row = useRef<HTMLButtonElement>(null);
	useEffect(() => {
		if (first === true) row.current?.focus();
	}, [first]);
	return (
		<button
			type="button"
			role={marked === undefined ? "menuitem" : "menuitemradio"}
			aria-checked={marked}
			className={className}
			ref={row}
			disabled={disabled}
			onClick={onPick}
		>
			{icon !== undefined && <Icon name={icon} size={15} />}
			{
				/* A row that is choosing between states shows which one is in force,
			    and shows it in the same column whether or not this is the one: the
			    tick appearing and disappearing under the reader's eye would move
			    every word beside it. */
			}
			{marked !== undefined && (
				<span className="menu-mark" aria-hidden="true">
					{marked ? <Icon name="check" size={14} /> : null}
				</span>
			)}
			<span>{children}</span>
		</button>
	);
}
