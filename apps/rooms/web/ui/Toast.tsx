// Transient notices above every layer of the page, including a modal dialog.
//
// A refused invite, a rail that would not take a name, a copy the browser
// blocked. Anything that answers for a moment and then should get out of the way
// lands here rather than on a row in the rail, where a directory's own standing
// is said and stays until that directory says otherwise. Several may be up at
// once. A new one pushes the others down, and dismissing one lets them close the
// gap.
//
// A native modal makes the rest of the document inert, and the dialog itself
// covers the viewport, so a stack that lived beside it could paint above and
// still not take a press. While a modal is open the stack is a child of it,
// already in the top layer and in the tree that still accepts input.

import * as store from "./store.ts";
import { memo, useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Icon, type IconName } from "./icons.tsx";
import { IconButton } from "./IconButton.tsx";
import type { ToastKind, ToastNotice } from "./types.ts";
import { useRoomsBrowser } from "./controller/browser.ts";
import { useRoomsProjection } from "./hooks.ts";
import { useOpenModal, useTopModalLayer } from "./modal.ts";
import { errorDetailTitle, needsErrorDetail } from "./error_text.ts";

/** How long a notice stands before it leaves on its own. Long enough to read
 * after the eye has left the control, short enough that a run of them does not
 * become furniture. Hover or focus holds the remaining time. */
const TOAST_MS = 4000;

const kindIcon: Record<ToastKind, IconName> = {
	success: "check",
	failure: "fail",
	warning: "warn",
};

/** The notice itself, without the stack or the timer. The catalog draws this
 * in place; the live stack wraps it with a slot that can leave. */
export function ToastCard(
	{ kind, text, onDismiss, onExpand }: {
		kind: ToastKind;
		text: string;
		onDismiss?: () => void;
		/** Take this notice off before the error card opens, so the stack is not
		 * portaled into the card that just took its words. */
		onExpand?: () => void;
	},
) {
	const browser = useRoomsBrowser();
	const openModalFrom = useOpenModal();
	const expandable = needsErrorDetail(text);
	return (
		<div className="toast" data-kind={kind} role={kind === "failure" ? "alert" : "status"}>
			<span className="toast-mark" aria-hidden="true">
				<Icon name={kindIcon[kind]} size={16} />
			</span>
			{expandable
				? (
					<button
						type="button"
						className="toast-text toast-more"
						aria-haspopup="dialog"
						onClick={(event) =>
							openModalFrom(event.currentTarget, () => {
								onExpand?.();
								browser.showError({ title: errorDetailTitle(kind), text });
							})}
					>
						<span className="said-clamp">{text}</span>
						<span className="said-show">Show</span>
					</button>
				)
				: <p className="toast-text">{text}</p>}
			{onDismiss !== undefined && (
				<IconButton
					className="toast-dismiss"
					icon="close"
					label="Dismiss"
					size="small"
					variant="ghost"
					onClick={onDismiss}
				/>
			)}
		</div>
	);
}

export const Toasts = memo(function Toasts({ toasts }: { toasts: readonly ToastNotice[] }) {
	const projection = useRoomsProjection();
	const modal = useTopModalLayer();
	const [leaving, setLeaving] = useState<ReadonlySet<number>>(() => new Set());

	useEffect(() => {
		setLeaving((was) => {
			const live = new Set(toasts.map((notice) => notice.id));
			let changed = false;
			const next = new Set<number>();
			for (const id of was) {
				if (live.has(id)) next.add(id);
				else changed = true;
			}
			return changed ? next : was;
		});
	}, [toasts]);

	const dismiss = useCallback((id: number) => {
		setLeaving((was) => {
			if (was.has(id)) return was;
			const next = new Set(was);
			next.add(id);
			return next;
		});
	}, []);

	const gone = useCallback((id: number) => {
		store.dismissToast(projection, id);
		setLeaving((was) => {
			if (!was.has(id)) return was;
			const next = new Set(was);
			next.delete(id);
			return next;
		});
	}, [projection]);

	const stack = (
		<div id="toasts" className="toasts" role="region" aria-label="Notices">
			{toasts.map((notice) => (
				<ToastSlot
					key={notice.id}
					notice={notice}
					leaving={leaving.has(notice.id)}
					onDismiss={dismiss}
					onGone={gone}
				/>
			))}
		</div>
	);

	return modal != null ? createPortal(stack, modal) : stack;
});

function ToastSlot(
	{ notice, leaving, onDismiss, onGone }: {
		notice: ToastNotice;
		leaving: boolean;
		onDismiss: (id: number) => void;
		onGone: (id: number) => void;
	},
) {
	const projection = useRoomsProjection();
	const slot = useRef<HTMLDivElement>(null);
	const remaining = useRef(TOAST_MS);
	const deadline = useRef(0);
	const armed = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
	const holds = useRef(new Set<string>());
	const [entered, setEntered] = useState(false);

	useLayoutEffect(() => {
		const frame = requestAnimationFrame(() => setEntered(true));
		return () => cancelAnimationFrame(frame);
	}, []);

	useEffect(() => {
		if (leaving) {
			clearTimeout(armed.current);
			return;
		}
		const arm = () => {
			clearTimeout(armed.current);
			deadline.current = Date.now() + remaining.current;
			armed.current = setTimeout(() => onDismiss(notice.id), remaining.current);
		};
		arm();
		const hold = (reason: string) => {
			if (holds.current.has(reason)) return;
			holds.current.add(reason);
			if (holds.current.size === 1) {
				clearTimeout(armed.current);
				remaining.current = Math.max(0, deadline.current - Date.now());
			}
		};
		const resume = (reason: string) => {
			if (!holds.current.delete(reason)) return;
			if (holds.current.size === 0) arm();
		};
		const node = slot.current;
		const pointerIn = () => hold("pointer");
		const pointerOut = () => resume("pointer");
		const focusIn = () => hold("focus");
		const focusOut = (event: FocusEvent) => {
			if (node?.contains(event.relatedTarget as Node | null)) return;
			resume("focus");
		};
		node?.addEventListener("pointerenter", pointerIn);
		node?.addEventListener("pointerleave", pointerOut);
		node?.addEventListener("focusin", focusIn);
		node?.addEventListener("focusout", focusOut);
		return () => {
			clearTimeout(armed.current);
			node?.removeEventListener("pointerenter", pointerIn);
			node?.removeEventListener("pointerleave", pointerOut);
			node?.removeEventListener("focusin", focusIn);
			node?.removeEventListener("focusout", focusOut);
		};
	}, [leaving, notice.id, onDismiss]);

	useEffect(() => {
		if (!leaving) return;
		const fallback = setTimeout(() => onGone(notice.id), 200);
		return () => clearTimeout(fallback);
	}, [leaving, notice.id, onGone]);

	return (
		<div
			ref={slot}
			className={leaving ? "toast-slot is-leaving" : entered ? "toast-slot" : "toast-slot is-entering"}
			onTransitionEnd={(event) => {
				if (event.target !== slot.current) return;
				if (event.propertyName !== "grid-template-rows") return;
				if (leaving) onGone(notice.id);
			}}
		>
			<div className="toast-clip">
				<ToastCard
					kind={notice.kind}
					text={notice.text}
					onDismiss={() => onDismiss(notice.id)}
					onExpand={() => store.dismissToast(projection, notice.id)}
				/>
			</div>
		</div>
	);
}
