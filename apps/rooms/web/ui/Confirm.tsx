// The second step of an act that cannot be undone, inside the thing it acts
// on.
//
// A control whose press takes something away ends its label with an ellipsis
// and opens this instead of acting: one sentence saying what will be lost, in
// the reader's terms, then the way out and the commitment. The commitment
// wears the danger colour, so it cannot be mistaken for the ordinary
// commitment beside it however similar the words, and it comes last, where
// every commitment on the plane comes. An act that only changes course rather
// than losing anything (continuing as a local copy, marking an operation
// completed) asks the same way with the ordinary commitment, `tone`
// "primary".
//
// Inline rather than a dialog for two reasons. The question belongs to the
// row that raised it, and a reader should see the row while deciding. And
// most of these rows already sit inside a dialog, and a dialog over a dialog
// is a shape neither the browser nor a screen reader handles well.
//
// The keyboard is handled the way a dialog would handle it, because to a
// keyboard reader this is one: opening moves focus onto the way out, so the
// next Enter keeps rather than commits; Escape is the way out too, and stays
// here rather than closing the card the question sits in, and keeping hands
// focus back to the act that asked, which is where the reader was.

import { type ReactNode, useEffect, useRef, useState } from "react";
import { Button } from "./Button.tsx";

export function Confirm(
	{ id, label, say, keep, commit, tone = "danger", busy = false, keepId, commitId, onKeep, onCommit }: {
		id?: string;
		/** What this question is about, for a reader who cannot see the row. */
		label: string;
		/** What happens if the reader goes ahead. */
		say: ReactNode;
		/** The way out, worded as what staying keeps. */
		keep: string;
		/** The commitment, worded as what it does. */
		commit: string;
		tone?: "danger" | "primary";
		busy?: boolean;
		keepId?: string;
		commitId?: string;
		onKeep: () => void;
		onCommit: () => void;
	},
) {
	const keepButton = useRef<HTMLButtonElement>(null);
	// The act that opened this, remembered by element and by id: the element
	// itself when the site keeps it mounted, its id when the site swaps it for
	// this question and draws it again after. Read while this first renders,
	// because a site that swaps removes the act in the same commit that puts
	// this in, and by the time an effect runs the focus it held is gone.
	const [opener] = useState(() => {
		const active = document.activeElement;
		return { element: active, id: active instanceof HTMLElement ? active.id : "" };
	});
	useEffect(() => {
		keepButton.current?.focus();
	}, []);
	const back = () => {
		onKeep();
		const { element, id } = opener;
		requestAnimationFrame(() => {
			const target = element?.isConnected ? element : id === "" ? null : document.getElementById(id);
			if (target instanceof HTMLElement && !(target as HTMLButtonElement).disabled) target.focus();
		});
	};
	return (
		<div
			id={id}
			className="confirm"
			data-tone={tone}
			role="group"
			aria-label={label}
			onKeyDown={(event) => {
				if (event.key !== "Escape" || busy) return;
				event.stopPropagation();
				event.preventDefault();
				back();
			}}
		>
			<p>{say}</p>
			<div className="actions">
				<Button ref={keepButton} id={keepId} variant="quiet" disabled={busy} onClick={back}>{keep}</Button>
				<Button id={commitId} variant={tone} busy={busy} onClick={onCommit}>{commit}</Button>
			</div>
		</div>
	);
}
