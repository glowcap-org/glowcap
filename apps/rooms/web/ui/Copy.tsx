// Putting something on the clipboard, and saying so.
//
// A copy has no visible result, because the clipboard is somewhere the page
// cannot show, so a control that only depresses leaves a reader to find out by
// pasting. Everything that copies therefore answers in the same two ways at
// once. The mark becomes a tick, and a short "Copied" stands over the control
// for a moment; then both go back to offering. That chip is also the accessible
// reply, because it is a live region rather than a swapped label, and an
// `aria-label` that changes under a pointer press is announced by some screen
// readers and not others.
//
// A write the browser refused has nothing on the control left to say, and that
// is a toast — above the page, including above a modal, which is where a
// locator is copied from.
//
// The write itself lives in `clipboard.ts`. `navigator.clipboard` is absent
// outside a secure context, and a page may be denied it outright; both arrive
// here rather than at each caller, so no site can half-handle them and leave a
// press unanswered.

import { useEffect, useRef, useState } from "react";
import { Icon } from "./icons.tsx";
import { IconButton, type IconButtonProps } from "./IconButton.tsx";
import { writeClipboard } from "./clipboard.ts";
import { usePeer } from "./peer.ts";

/** How long the reply stands. Long enough to read after the eye comes back to
 * the control, short enough that the control is offering again by the time a
 * reader wants a second copy. */
const replyMs = 1600;

/** The act itself: write, answer, and go back to offering.
 *
 * The timer can outlive the control that set it, because closing the settings
 * dialog or repainting the log unmounts one mid-reply. `from` is the control
 * that was pressed, so the write can take a selection inside a modal rather
 * than on the inert document underneath it. */
export function useCopy(text: string | null) {
	const peer = usePeer();
	const [copied, setCopied] = useState(false);
	const back = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
	useEffect(() => () => clearTimeout(back.current), []);

	// Structural rather than `Event`, because a React handler passes its own
	// synthetic event, which carries `currentTarget` without being a DOM Event.
	const copy = async (from?: { currentTarget?: unknown } | Element | null) => {
		if (text === null) return;
		const root = from instanceof Element
			? from
			: from != null && from.currentTarget instanceof Element
			? from.currentTarget
			: document.body;
		try {
			await writeClipboard(text, root);
		} catch {
			peer.toast("failure", "Your browser would not let the page copy that.");
			return;
		}
		clearTimeout(back.current);
		setCopied(true);
		back.current = setTimeout(() => setCopied(false), replyMs);
	};

	return { copied, copy };
}

/** The reply, rendered whether or not it says anything, so that saying it is a
 * change inside a region assistive software is already watching. */
function Said({ copied }: { copied: boolean }) {
	return <span className="copy-said" role="status">{copied ? "Copied" : ""}</span>;
}

export type CopyButtonProps =
	& Omit<IconButtonProps, "icon" | "label" | "onClick">
	& {
		/** What lands on the clipboard, or null while it is not known yet. */
		text: string | null;
		/** What this copies, named for a reader who cannot see the icon. */
		label: string;
	};

/** A control beside the thing it copies. */
export function CopyButton({ text, label, disabled, ...button }: CopyButtonProps) {
	const { copied, copy } = useCopy(text);
	return (
		<span className="copy">
			<IconButton
				{...button}
				icon={copied ? "check" : "copy"}
				label={label}
				tone={copied ? "teal" : button.tone}
				disabled={disabled || text === null}
				onClick={copy}
			/>
			<Said copied={copied} />
		</span>
	);
}

export type CopyFieldProps = {
	/** What the field shows and what lands on the clipboard, or null while it is
	 * not known yet. A locator this window has not settled on has nothing to
	 * copy, and the field says so by being unpressable rather than by copying
	 * the placeholder. */
	text: string | null;
	/** What this copies, named for a reader who cannot see the mark. */
	label: string;
	/** Names the text itself, for anything that reads what the field shows. */
	id?: string;
};

/** Text the page shows so a reader can take it away.
 *
 * The whole field is the control. It looks like a field because that is what
 * the text is, but nothing in it can be typed into, so the only thing a press
 * could mean is the one thing a reader wants; a small target in the corner
 * would be asking them to aim at it for no reason. The mark stays in that
 * corner anyway, because it is what says a press does anything at all.
 *
 * Being one button rather than a field with a button in it is also what lets
 * the text run to any length. The corner is held open by the field's own
 * padding, so a value that wraps to three lines stops short of the mark on
 * every one of them, and a value that fits on one sits beside it. */
export function CopyField({ text, label, id }: CopyFieldProps) {
	const { copied, copy } = useCopy(text);
	return (
		<button
			type="button"
			className="copy-field"
			aria-label={label}
			title={label}
			data-copied={copied ? "" : undefined}
			disabled={text === null}
			onClick={copy}
		>
			<span id={id} className="copy-field-text" translate="no">{text ?? "…"}</span>
			<span className="copy-field-mark" aria-hidden="true">
				<Icon name={copied ? "check" : "copy"} size={15} />
			</span>
			<Said copied={copied} />
		</button>
	);
}
