// A refusal or warning that still belongs to the control it answers.
//
// Toasts leave. These stay with the field, the bell, or the meter they describe,
// in the same danger and warning ink the page notices use, so a reader who has
// seen one of those colours already knows what this is.
//
// A short one is the whole of it. A long one still occupies that slot — two
// lines, then Show — and the rest opens on a card, so the control it answered
// is not shoved off the page.

import type { ElementType, ReactNode } from "react";
import { openModalFrom } from "./modal.ts";
import { usePeer } from "./peer.ts";
import { errorDetailTitle, needsErrorDetail } from "./error_text.ts";

/** Failure stays with a field that would not take the value. Warning stays with
 * a control whose standing condition the reader can still act on. */
export type SaidKind = "failure" | "warning";

export function Said(
	{ kind, id, as: Tag = "p", className, children }: {
		kind: SaidKind;
		id?: string;
		as?: ElementType;
		className?: string;
		children?: ReactNode;
	},
) {
	const peer = usePeer();
	const text = typeof children === "string" ? children : null;
	const empty = children == null || children === "";
	const said = ["said", className].filter(Boolean).join(" ");
	if (text !== null && !empty && needsErrorDetail(text)) {
		return (
			<button
				type="button"
				id={id}
				className={said + " said-more"}
				data-kind={kind}
				aria-haspopup="dialog"
				onClick={(event) =>
					openModalFrom(event.currentTarget, () => peer.showError({ title: errorDetailTitle(kind), text }))}
			>
				<span className="said-clamp" role="alert">{text}</span>
				<span className="said-show">Show</span>
			</button>
		);
	}
	return (
		<Tag id={id} className={said} data-kind={kind} role={empty ? undefined : "alert"}>
			{empty ? "" : children}
		</Tag>
	);
}
