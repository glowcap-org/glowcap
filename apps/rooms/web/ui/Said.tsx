// A reply that still belongs to the control it answers: a refusal, a warning
// that stands, or the word that an act went through.
//
// Toasts leave. These stay with the field, the bell, the meter, or the button
// they describe, on a line of their own. Over a form control, because the
// reader has to act on it before the answer will be taken. Under a bell, a
// meter, or an act, which have no answer to correct. A refusal arriving over a
// field moves the field down as it lands. That is the price of keeping it out
// from behind a phone's keyboard. Refusal is danger ink, a standing
// condition is warning ink, and success is teal with a check, the three inks
// the page's notices already use, so a reader who has seen one knows this.
//
// Render one only when there is something to say. An empty one shows nothing,
// but it is still a child of whatever holds it: it takes its share of a flex
// parent's gap, and it takes real height from any rule that reserves it a line.
// A reply nobody made is worth neither.
//
// The composer's availability line is the one exception, and it pays for itself
// by hand: it stays mounted while empty so the row beneath the field always has
// it to compare against and to measure, and `composer.css` drops every child of
// that row that has nothing in it, so an empty one costs no width and no gap.
// An exception that did not do that would sit in the row as a blank holding its
// place, which is the thing this paragraph is about.
//
// A short one is the whole of it. A long one is held to two lines here and
// the rest opens on a card, but only when the two lines cut it. The
// clamp is measured rather than guessed from length: a locator that happens
// to fit is shown whole, and a Show that opened a card saying nothing more
// than the line already did was a control with nothing behind it.

import { type ElementType, type ReactNode, useCallback, useLayoutEffect, useRef, useState } from "react";
import { useOpenModal } from "./modal.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { errorDetailTitle } from "./error_text.ts";
import { Icon } from "./icons.tsx";
import { toastShow } from "../../lib/text/controls.ts";

/** Failure stays with a field that would not take the value. Warning stays with
 * a control whose standing condition the reader can still act on. Success says
 * an act went through, where its button is. */
export type SaidKind = "failure" | "warning" | "success";

/** Whether the clamped text is being cut, measured on the element itself and
 * again whenever its content or box width changes. A node with no layout, the card it
 * sits on is closed under another layer, says nothing, so the answer it gave
 * while visible stands: flipping to "not cut" there would swap the Show
 * button for plain text and lose the focus a closing layer returns to it. */
function useClamped(content: ReactNode): { ref: (node: HTMLElement | null) => void; clamped: boolean } {
	const [clamped, setClamped] = useState(false);
	const watched = useRef<ResizeObserver | null>(null);
	const element = useRef<HTMLElement | null>(null);
	const measure = useCallback(() => {
		const current = element.current;
		if (current === null || current.clientHeight === 0) return;
		setClamped(
			current.scrollHeight > current.clientHeight + 1 || current.scrollWidth > current.clientWidth + 1,
		);
	}, []);
	const ref = useCallback((node: HTMLElement | null) => {
		watched.current?.disconnect();
		watched.current = null;
		element.current = node;
		if (node === null) return;
		// The rendered element can change from text to the Show control. Keep the
		// exact current clamp owner so a later content update remeasures it even
		// when its box size did not move.
		measure();
		if (typeof ResizeObserver !== "undefined") {
			watched.current = new ResizeObserver(measure);
			watched.current.observe(node);
		}
	}, [measure]);
	useLayoutEffect(measure, [content, measure]);
	useLayoutEffect(() => () => {
		watched.current?.disconnect();
		element.current = null;
	}, []);
	return { ref, clamped };
}

export function Said(
	{ kind, id, as: Tag = "p", className, children }: {
		kind: SaidKind;
		id?: string;
		as?: ElementType;
		className?: string;
		children?: ReactNode;
	},
) {
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	const { ref, clamped } = useClamped(children);
	const text = typeof children === "string" ? children : null;
	const empty = children == null || children === "";
	const said = ["said", className].filter(Boolean).join(" ");
	const role = empty ? undefined : kind === "success" ? "status" : "alert";
	if (text !== null && !empty && kind !== "success") {
		// Measured as a clamp first; only a cut one becomes the way to the card.
		if (clamped) {
			return (
				<button
					type="button"
					id={id}
					className={said + " said-more"}
					data-kind={kind}
					aria-haspopup="dialog"
					onClick={(event) =>
						openModalFrom(
							event.currentTarget,
							() => browser.showError({ title: errorDetailTitle(kind), text }),
						)}
				>
					<span ref={ref} className="said-clamp" role={role}>{text}</span>
					<span className="said-show">{toastShow}</span>
				</button>
			);
		}
		return (
			<Tag id={id} className={said} data-kind={kind} role={role}>
				<span ref={ref} className="said-clamp">{text}</span>
			</Tag>
		);
	}
	return (
		<Tag id={id} className={said} data-kind={kind} role={role}>
			{!empty && kind === "success" && <Icon name="check" size={14} />}
			{empty ? "" : children}
		</Tag>
	);
}
