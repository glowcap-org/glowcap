// The rooms control whose meaning is carried by words, and the other half of
// the pair `IconButton` opens: that component says text-bearing buttons are a
// different family, and this is the family.
//
// A rooms form asks for two things. There is the commitment at its foot, which
// joins a room or saves and reloads, and there is the quiet way out beside it,
// which closes or goes off to browse instead. So the one axis here is which of
// those two a button is, and the colour follows from that rather than being a
// separate choice: commitment is amber, the way out is teal. A tone axis like
// the icon family's would be a knob with exactly one value per variant.
//
// The third is a step sideways rather than out of a form: a word inside running
// text that opens something further. It is a role and not a knob, the same as
// the other two — what makes it its own variant is that it takes no box at all,
// so it can sit in a line of prose without the line growing around it.
//
// The fourth is that word grown into a line of its own: the quiet second line
// under a name, saying where the thing above it lives and opening what is known
// about that. It reads as a caption rather than as a control, and a reader aims
// at the whole line rather than at the words on it — so unlike the third it is
// smaller than its surroundings, carries a rectangle at rest to be approached
// by, and sits what it holds in the middle of the line as one piece, a glyph
// and its words together. It began as the third wearing a class that overrode
// the font, which is how a family tells you it is missing a case.
//
// Geometry belongs to the variant too, down to how the button sits in the card
// holding it. A caller places the card, not the button, because a padding or a
// weight named per card is a copy, and copies of a look drift until two of the
// same control no longer look the same. A layout may still say *where* one
// goes: the rail gives its caption the row's own columns, which is placement
// and not a look.

import type { ComponentPropsWithRef } from "react";

/** Commitment, the quiet way out, a step sideways, or the line under a name. */
export type ButtonVariant = "primary" | "quiet" | "link" | "caption";

export type ButtonProps = ComponentPropsWithRef<"button"> & {
	variant?: ButtonVariant;
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
			data-busy={busy || undefined}
			disabled={disabled || busy}
		/>
	);
}
