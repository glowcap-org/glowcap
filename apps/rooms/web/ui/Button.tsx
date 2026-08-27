// The rooms control whose meaning is carried by words, and the other half of
// the pair `IconButton` opens: that component says text-bearing buttons are a
// different family, and this is the family.
//
// A rooms form asks for three things. There is the commitment, which joins a
// room or saves; there is the commitment that takes something away, which
// leaves, deletes, or revokes; and there is the quiet way out beside either,
// which closes, stays, or goes off to browse instead. So the one axis here is
// which of those a button is, and the colour follows from that rather than
// being a separate choice: commitment is amber, taking away is the refusal
// red, the way out is teal. A tone axis like the icon family's would be a knob
// with exactly one value per variant.
//
// The fourth is a step sideways rather than out of a form: a word inside
// running text that opens something further. It is a role and not a knob, the
// same as the other three — what makes it its own variant is that it takes no
// box at all, so it can sit in a line of prose without the line growing around
// it. It still wears teal at rest, the same ink as the quiet way out, because a
// word that only colours under a pointer is indistinguishable from the
// sentence around it.
//
// The fifth is that word grown into a line of its own: the quiet second line
// under a name, saying where the thing above it lives and opening what is known
// about that. It reads as a caption rather than as a control, and a reader aims
// at the whole line rather than at the words on it — so unlike the fourth it is
// smaller than its surroundings, carries a rectangle at rest to be approached
// by, and sits what it holds in the middle of the line as one piece, a glyph
// and its words together. It began as the fourth wearing a class that overrode
// the font, which is how a family tells you it is missing a case.
//
// Size is the one other axis, and it is geometry rather than emphasis: a boxed
// button is `normal` at the in-row height the entries and confirms stand at,
// or `large` at the field height, for the button beside a field and for the
// commitment at a card's foot. A caller places the button — in an actions
// row, beside a field, across the card's width with `block` — and never
// restates its padding, radius, or weight, because a padding named per card is
// a copy, and copies of a look drift until two of the same control no longer
// look the same.

import type { ComponentPropsWithRef } from "react";

/** Commitment, the commitment that takes away, the quiet way out, a step
 * sideways, or the line under a name. */
export type ButtonVariant = "primary" | "danger" | "quiet" | "link" | "caption";

/** The in-row height, or the field height. Only the boxed variants have one. */
export type ButtonSize = "normal" | "large";

export type ButtonProps = ComponentPropsWithRef<"button"> & {
	variant?: ButtonVariant;
	size?: ButtonSize;
	/** Span the whole line: a card's own commitment, or the act under a field
	 * on a phone. Placement, so the caller says it. */
	block?: boolean;
	/** The action is in flight rather than refused. Both are unpressable, and
	 * they read differently: a waiting cursor rather than a barred one. What
	 * says so to a reader who cannot see a cursor is the button's own label, so
	 * this stays a styling fact and does not touch ARIA. The one attribute that
	 * sounds right, `aria-busy`, means something else: a subtree being rewritten,
	 * whose updates are not worth announcing yet. */
	busy?: boolean;
};

export function Button({
	variant = "primary",
	size = "normal",
	block = false,
	busy = false,
	className,
	type = "button",
	disabled,
	...button
}: ButtonProps) {
	return (
		<button
			{...button}
			type={type}
			className={["button", className].filter(Boolean).join(" ")}
			data-variant={variant}
			data-size={size}
			data-block={block || undefined}
			data-busy={busy || undefined}
			disabled={disabled || busy}
		/>
	);
}
