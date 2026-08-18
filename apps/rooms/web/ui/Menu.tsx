// A menu that opens off a control, and the two rules a reader expects of one.
//
// The behaviour is the same wherever a menu appears — it closes when you press
// somewhere else or press Escape, it is walked with the arrows, and the first
// row has the keyboard when it opens — and it is the part that is easy to get
// subtly wrong twice. What differs between menus is where they sit and what is
// in them, so that stays with each of them.
//
// The roles are a promise about all of that: software that announces a menu
// tells its reader it is one, and a reader who is told so reaches for the
// arrows. Tab still leaves, which is what a reader who was not told will try.

import { type ReactNode, useEffect, useRef, useState } from "react";
import { Icon, type IconName } from "./icons.tsx";

/** Open state and the wiring that closes it, for one menu.
 *
 * `holder` goes on the element that contains both the control and the menu, so
 * a press inside it — including on the control itself — is not "somewhere
 * else". `trigger` goes on the control, so Escape hands the keyboard back to
 * what a reader opened it with rather than dropping it at the top of the page. */
export function useMenu(): {
	open: boolean;
	setOpen: (open: boolean | ((was: boolean) => boolean)) => void;
	holder: { current: HTMLDivElement | null };
	trigger: { current: HTMLButtonElement | null };
} {
	const [open, setOpen] = useState(false);
	const holder = useRef<HTMLDivElement>(null);
	const trigger = useRef<HTMLButtonElement>(null);
	useEffect(() => {
		if (!open) return;
		const outside = (event: MouseEvent) => {
			if (!holder.current?.contains(event.target as Node)) setOpen(false);
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
	return { open, setOpen, holder, trigger };
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
 * somewhere to start; exactly one row in a menu should ask for it.
 *
 * As the menu opens, and never again. A ref callback runs on every render, and
 * a menu holding a field re-renders on every keystroke — so focusing from one
 * took the keyboard back off the reader mid-word, once per character. */
export function MenuRow(
	{ icon, className, first, marked, onPick, children }: {
		icon?: IconName;
		className: string;
		first?: boolean;
		/** Whether this row is the answer in force, for a menu that is choosing
		 * between states rather than performing actions. */
		marked?: boolean;
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
